# AmphoraKit

A small, strict Core Data stack for Swift 6: one `Database` per model, serial background queues
by label, a coalescing `FetchController`, a `clear()` you can call while work is in flight, and
typed queries that never spell a storage key at the call site.

- **Schema-typed.** `Database<Schema>` and `DatabaseContext<Schema>`: passing a context of one
  model to the entities of another is a compile error.
- **Swift 6 strict concurrency.** `Sendable` for real, state under `Mutex`, no `@unchecked` on
  anything holding managed objects.
- **Typed queries and values.** `Note.fetch(matching: [.isPinned(true), .score(.greaterThan(2))], in: context)`,
  `Note.isPinned == true && Note.score > 2`, `Note.update(matching: .kind(.marker), set: [.order(0)], in: context)`.
- **One line per column.** `@Attribute("a_sortOrder", storeAs: Int32.self) var order: Int` declares
  the storage and its typed accessor.
- **Zero dependencies** for the core. The macros come in a separate product built on swift-syntax.

## Requirements

| Platform | Minimum |
|---|---|
| iOS | 18 |
| macOS | 15 |
| tvOS | 18 |
| watchOS | 11 |
| visionOS | 2 |

Swift 6.3 / Xcode 27. Xcode asks to trust the macros plugin once; command-line builds pass
`-skipMacroValidation`. A file importing SwiftData too qualifies `@AmphoraKit.Attribute`.

## Installation

Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/thomasalbert1993/AmphoraKit", from: "1.0.0")
]
```

| Product | Add it to | Contents |
|---|---|---|
| `AmphoraKit` | the app | Database, contexts, tasks, fetching, batch requests, queries, and the macros: `@Entity`, `@Attribute`, `@Relationship`, `@Stored`, `@StorageOnly` |
| `AmphoraKitMacros` | — | kept for `import AmphoraKitMacros`, re-exports `AmphoraKit` |
| `AmphoraKitTestSupport` | test targets | ephemeral databases, `awaitCondition`, a test model |

## Core concepts

| Type | Role |
|---|---|
| `DatabaseSchema` | A marker type carrying the `NSManagedObjectModel`. |
| `Database<Schema>` | The container, its view context, its background queues, `clear()`. |
| `DatabaseContext<Schema>` | A context of that model only. `nsContext` is the escape hatch. |
| `DatabaseObject` | An entity: its `Schema`, `Query` and `Sort`. No identifier required. |
| `IdentifiableDatabaseObject` | An entity with an `id` stored under `idKey`: adds `fetch(id:)`, `create(id:)`, `.id(_:)`, `delete(ids:)`, `reference`… |
| `SoftDeletable` | An entity whose objects are marked deleted: typed fetches leave them out. |
| `Match<Value>` | A condition on one value: `.equal`, `.greaterThan`, `.in`, `.contains`, `.isNil`… |
| `FetchController<T>` | Observes a request on the main context, coalesces changes. |

## Setting up

```swift
import AmphoraKit

enum AppSchema: DatabaseSchema {
    static let model = NSManagedObjectModel(contentsOf: Bundle.main.url(forResource: "App", withExtension: "momd")!)!
}

let database: Database<AppSchema> = {
    var configuration = DatabaseConfiguration(name: "App")      // App.sqlite in the default directory
    configuration.logger = MyLogger()                             // any DatabaseLogging, nil = silent
    configuration.didClear = { purgeCachedFiles() }               // runs on the main actor inside clear()
    return Database(configuration: configuration)
}()

// Early, on the main actor:
let outcome = try database.setup()                               // idempotent
if outcome == .recreatedAfterLoadFailure { resetSyncState() }
```

`storage: .ephemeral` gives a SQLite store on `/dev/null`: batch requests work, nothing persists.
`loadFailurePolicy: .propagate` throws instead of destroying an unreadable store.

### Store options and seed

```swift
let configuration = DatabaseConfiguration(
    name: "Catalog",
    storage: .persistent(url: groupContainer.appendingPathComponent("Catalog.sqlite")),
    storeOptions: .init(persistentHistoryTracking: true, fileProtection: .completeUntilFirstUserAuthentication),
    seedStoreURL: Bundle.main.url(forResource: "Catalog", withExtension: "sqlite")
)
```

- `storeOptions` — history tracking, remote change notifications, file protection, SQLite pragmas —
  apply every time the store is opened, recreations by `clear()` and after a load failure included.
- `seedStoreURL` is copied in place, with its `-wal` and `-shm`, when the store file doesn't exist,
  and again after every recreation. A failed copy is logged and the store opens empty. Produce
  the seed with `exportStore(to:)`.
- `storeDescription` is the description the store opens with, for what needs it:

```swift
var spotlight: NSCoreDataCoreSpotlightDelegate?
configuration.willClear = { spotlight?.stopSpotlightIndexing() }
configuration.didClear = { spotlight?.startSpotlightIndexing() }
// after setup():
spotlight = CatalogSpotlightDelegate(forStoreWith: database.storeDescription,
                                     coordinator: database.persistentContainer.persistentStoreCoordinator)
spotlight?.startSpotlightIndexing()
```

## Entities

With the macros, each column is one line: `@Entity` writes the `@NSManaged` storage, the property
becomes its accessor.

```swift
import AmphoraKit

@objc(Note)
@Entity(attributePrefix: "a_", relationshipPrefix: "r_")
final class Note: NSManagedObject, IdentifiableDatabaseObject {
    typealias Schema = AppSchema
    static var idKey: String { "a_id" }

    @Attribute var id: String                                                  // a_id: String

    /// The note text.
    @Attribute(access: .readWrite) var text: String                            // a_text: String

    /// The position in the list.
    @Attribute("a_sortOrder", storeAs: Int32.self) var order: Int               // renamed, another width

    /// What the note is.
    @Attribute(default: Kind.text) var kind: Kind                               // RawRepresentable, a_kind: String

    /// Where it starts, in bars and beats.
    @Attribute var start: BarBeatPosition?                                      // StorageConvertible, a_start: String?

    @Relationship var cue: Cue?                                                 // r_cue, nil when it is a zombie
    @Relationship var tags: [Tag]                                               // r_tags: Set<Tag>, zombies removed
}
```

- A to-many relationship reads in no particular order, like the set Core Data keeps;
  `@Relationship(.sorted)` sorts it by the target's `Comparable` conformance (a compile error
  without one).
- The storage name is the property name behind the entity's prefix, unless given. It stays
  `internal` (or `public`/`package` like the property): `#keyPath` and the key-value APIs reach it.
- Without `storeAs:`, a type Core Data stores as is keeps its type, and any other names
  `Type.StoredColumn`, which the compiler resolves: the raw value of a `RawRepresentable`, the
  storage of a `StorageConvertible`, or the type's own `typealias StoredColumn = Int32` to pick
  another width. `storeAs:` stays for a column whose optionality differs from the property's
  (`storeAs: String?.self, default: Kind.text` over an optional column), an `Int` stored in
  another width and coders. A collection takes its element's column: `[Tag]` is stored as
  `[Tag.StoredColumn]`, `Set<Kind>?` as `Set<Kind.StoredColumn>?`. A non-optional collection gets an
  optional column without `storeAs`: `@Attribute var labels: Set<String>` is stored as
  `Set<String>?` and reads empty for `nil` — arrays, sets and dictionaries alike, raw values
  included (`[Tag]` as `[String]?`). A row inserted without it can't trap.
- A payload over an optional column, exposed non-optional, is an `EmptyStorageConvertible`: an
  `init()` for the empty value and `typealias StoredColumn = Data?` on the type, then `@Attribute
  var annotations: Annotations`. `nil` or an unreadable storage reads empty, no `default:`.
- An optional property over a non-optional column whose absence is a value (an integer code, `0`
  for none) is a `NilStorageConvertible`: `static var nilStorage: Int32 { 0 }` and
  `typealias OptionalStoredColumn = Int32` on the type, then `@Attribute var signature:
  Signature?`. Writing `nil` stores `0`, and `isNil` / `isNotNil` compare with `0` instead of
  `nil`.
- `storeAs:` is for lossless, order-preserving encodings — integer widths (saturating on write),
  raw values, `StorageConvertible`, arrays and sets of raw values (`[String]` as `[Tag]`) — so
  that queries on the exposed type stay right. A type both `RawRepresentable` and
  `StorageConvertible` goes by its storage. A unit conversion (milliseconds exposed as seconds)
  stays a hand-written accessor.
- The default names its type (`Kind.text`): macro arguments are checked before the property is.
- A column stored in another form also gets a stored-form assignment, `.kind(stored: "drone")`,
  written as is: a sync recopying the server's value keeps what this version wouldn't decode.
- A column whose encoding belongs to neither type takes a coder, a `StorageCoder` with `decode`
  and `encode`: `@Attribute(coder: TagChainCoder.self) var tags: [Tag]`, the column typed by the coder's
  `Stored`.
  Its accessor, queries and assignments go through the coder — an empty chain can be stored as
  `nil` — and it gets no sort and no static field, which would order or compare its encoding.

`@Entity` then generates, from these declarations:

- `Note.Query`: `.text(_:)` taking a value or a `Match<String>`, `.order(_:)` typed `Int`, `.kind(_:)`
  typed `Kind`, `.cue(_:)` taking a `Match<Cue?>` or a `Cue.Query`, `.tags(_:)` taking a
  `CollectionMatch<Tag>`;
- `Note.Sort`: `.text`, `.order`, `.kind`;
- `Note.AttributeAssignment`: `.text("x")`, `.order(3)`, `.kind(.marker)`, each encoded to its
  stored form, for the batch requests;
- `Note.Assignment`: every attribute assignment, plus the relationships — `.cue(cue)`,
  `.tags(tags)` — for one object;
- `Note.Columns`: one `Column` per attribute and relationship, its storage key and stored type
  (`Note.Columns.order: Column<Note, Int32>`, `Note.Columns.cue: Column<Note, Cue?>`); generic
  APIs take key paths into it, their root inferred: `\.order`;
- static fields for the expression form and the column names: `Note.order > 2`, `Note.order.key`
  (`"a_sortOrder"`).
- `note.stored`: the same columns read on one object in their stored form — `note.stored.kind`
  is the raw `String` (a value this version doesn't decode included), `note.stored.cue` the
  relationship as Core Data holds it, zombie or not. The read side of `.kind(stored:)`, for the
  code that copies or compares stored values as is:
  `copy.update(with: [.kind(stored: note.stored.kind)])`.

`@Entity(…, storageAccess: .private)` makes the generated `@NSManaged` storage private to the
class body: the compiler then rejects `note.a_kind` anywhere else, reads going through the
accessors and `stored`, writes through `update(with:)`.

An existing model can keep its `@NSManaged` lines and expose them with `@Stored(\Note.a_kind,
default: Kind.text) var kind: Kind` instead; `@StorageOnly` leaves a column out, and
`generatesAccessors: false` stops `@Entity` writing accessors for storage nothing exposes, when
the accessors live in extensions it can't see.

Without the macros, write `Query` and `Sort` by hand: a struct conforming to `EntityQuery` or
`EntitySort` with one static per attribute. `AmphoraKitTestSupport/TestModel.swift` shows both.

## Entity hierarchies

```swift
@Entity(attributePrefix: "a_")
class Asset: NSManagedObject, IdentifiableDatabaseObject {   // non-final: an open root
    typealias Schema = CatalogSchema
    static var idKey: String { "a_id" }
    @NSManaged var a_id: String
    @NSManaged var a_name: String
}

@Entity(attributePrefix: "a_")
class DynamicAsset: Asset {                                  // parent read from the superclass
    @NSManaged var a_provider: String
}

@Entity(attributePrefix: "a_")
final class Lens: DynamicAsset {
    @NSManaged var a_mount: String
}

try Asset.fetch(matching: .name("Planar"), in: context)                          // every kind of asset
try Lens.fetch(matching: [.mount("PL"), .provider("rental"), .name("Planar")], in: context)
let controller = FetchController(Lens.request(matching: [.mount("PL")]), in: database)
```

- The conformance belongs to the root (`RootEntity`), its sub-entities inherit it.
- On a non-final entity, `@Entity` generates classes; on a sub-entity, classes inheriting its
  parent's. `Lens.Query` has `mount` and every ancestor's member, `Lens.Sort`, the assignments
  and `stored` too.
- A sub-entity gets its own `fetch`, `fetchFirst`, `count`, `exists`, logged variants, `request`,
  batch `deleteAll`, `insert`, `update(matching:set:)` and `update(with:)`, taking its own types.
- The superclass, first in the inheritance clause, is the parent entity. `@Entity(root: true)`
  says it is a plain base class instead.
- Limits: the expression form (`Lens.mount == "PL"`) and generic code over `DatabaseObject`
  work with the root's types; build a sub-entity's `FetchController` from `Lens.request(…)`.

## Writing values

```swift
try Note.insert([[.id("n1"), .text("Intro"), .order(1)], [.id("n2"), .text("Outro"), .order(2)]], in: context)
try Note.update(matching: .kind(.marker), set: [.order(0)], in: context)
note.update(with: [.text("Edited"), .kind(.marker)])
let values = Note.AttributeAssignment.values([.order(3)])                // ["a_sortOrder": Int32(3)], for key-value APIs
```

The compiler checks the column and the value type. Batch requests can't set relationships:
they take `AttributeAssignment`s. On one object, `update(with:)` takes `Assignment`s, relationships
included. The related objects are passed as fetched: the caller decides what a missing one means.

```swift
note.update(with: [.text("Edited"), .cue(try Cue.fetch(id: "c1", in: context)), .tags(tags)])
```

## Queries

```swift
// List form: every query must match.
let notes = try Note.fetch(matching: [.isPinned(true), .score(.greaterThan(2))], sortedBy: [.score.descending], limit: 20, in: context)

// Expression form: fields are qualified by the entity, members inside stay implicit.
let urgent = try Note.fetch(matching: Note.kind == .warning && (Note.score > 2 || !.isPinned(true)), in: context)

// Relationships.
let inScene = try Note.count(matching: .cue(.track(.scene(.id(sceneId)))), in: context)   // r_cue.r_track.r_scene.a_id
let tagged  = try Note.fetch(matching: .tags(.any(.name(.hasPrefix("cam", .caseInsensitive)))), in: context)

// Escape hatch.
let custom = try Note.fetch(matching: Note.Query(unsafeFormat: "a_text MATCHES %@", pattern), in: context)
```

A `Request` bundles a query, a sort and a limit — the typed `NSFetchRequest`, for the request
factories of an entity and for `FetchController`:

```swift
extension Note {
    static func request(projectId: String) -> Request<Note> {
        Request(matching: .projectId(projectId), sortedBy: [.createdAt])
    }
}

let notes = try Note.fetch(request: Note.request(projectId: id).limited(to: 20), in: context)
let controller = FetchController(Note.request(projectId: id), in: database)
```

| Returns | Throws | Logs, returns empty |
|---|---|---|
| `[Self]` | `fetch(matching:sortedBy:limit:in:)` | `fetchOrEmpty(matching:…)` |
| `Self?` | `fetchFirst(matching:sortedBy:in:)` | `fetchFirstOrNil(matching:…)` |
| `Self?` by id | `fetchFirst(id:in:)` | `fetchFirstOrNil(id:in:)` |
| `Self` by id, `notFound` otherwise | `fetch(id:in:)` | — |
| `[Self]` by ids | `fetch(ids:in:)` | `fetchOrEmpty(ids:in:)` |
| `Int` / `Bool` | `count(matching:in:)`, `exists(matching:in:)` | — |

`all(of:)` ANDs a list of queries, `any(of:)` ORs one.

### Creating

```swift
let note = try Note.create(id: "n1", in: context)          // alreadyExists when taken, didCreate() once the id is set
let tag = try Tag.fetchOrCreate(id: "t1", in: context)      // didCreate() only when it inserts
```

`create` refuses an abstract entity (`DatabaseError.abstractEntity`). In a hierarchy, the
identifier belongs to the root: an object of another sub-entity holding it counts as taken.

### Soft delete

```swift
extension Entry: SoftDeletable {
    static var softDeletedKey: String { "a_deleted" }
}

try Entry.fetch(matching: .projectId(id), in: context)                         // live entries only
try Entry.fetch(matching: Entry.Query.projectId(id).withDeleted(), in: context) // all of them
try Entry.fetch(matching: .deleted(true), in: context)                         // the deleted ones
try Entry.fetch(id: entryId, in: context)                                      // deleted or not
```

Every fetch built from a typed query leaves the objects marked deleted out — `fetch`,
`fetchFirst`, `count`, `exists`, `Request`, `FetchController`, batch `deleteAll` and `update` — a
missing flag counting as live. A query on the identifier finds them too. Raw `NSFetchRequest`s and
`NSPredicate`s are left as written. `isSoftDeleted`, `nilIfSoftDeleted` and
`removingSoftDeleted()` read the flag.

### References and contexts

```swift
let reference = note.reference                              // Sendable, by identifier
try await database.enqueueBackgroundTaskAndSave { context in
    guard let note = try reference.resolve(in: context) else { return }
    …
}
let notes = try references.resolve(in: context)             // one fetch, in order
let mine = note.in(otherContext)                            // nil when not there, or never saved
note.databaseContext; note.isInViewContext
```

`Match` factories depend on the value: ordering only for `Comparable`, text operators only for
`String`, `.isNil` only for optionals. A stored enum or `StorageConvertible` is compared on its
storage, so `.kind(.in([.text, .warning]))` renders `a_kind IN {"text", "warning"}`.

## Background work

```swift
let count = try await database.enqueueBackgroundTaskAndSave(label: "import") { context in
    try Note.insert(rows, in: context)                       // NSBatchInsertRequest, merged into the view context
    return try Note.count(in: context)
}
```

- Tasks of one label run serially, labels run concurrently, each task gets a fresh context.
- `priority:` reorders waiting tasks, never a running one.
- `enqueueBackgroundTask` does not save. `perform` / `performAndSave` run synchronously.
- `performInBackground` runs now, outside the queues, concurrently with everything: for reads.
  `clear()` waits for it rather than abandoning it.
- Batch `insert`, `update(matching:)`, `deleteAll(matching:)` merge their changes into the calling
  context and the view context.

Databases given the same `DatabaseQueues` share their labels, the default one included: their
writes to related stores never interleave. `clear()` abandons the queued tasks of its own database
only.

```swift
let queues = DatabaseQueues()
let main = Database<MainSchema>(configuration: .init(name: "Main", queues: queues))
let assets = Database<AssetsSchema>(configuration: .init(name: "Assets", queues: queues))
```

## Observing

```swift
@MainActor
final class NotesInteractor {
    private let controller = FetchController<Note>(matching: .isPinned(true), sortedBy: [.score], in: database)

    func start() {
        controller.onChange { notes in render(notes) }       // leading call, then one trailing call per burst
    }
}
```

`notifyChangesOnly: true` skips the initial emission. `refetch()` emits now and cancels a pending one.

## Clearing

`clear(timeout:)` runs on the main actor and:

1. calls `willClear`;
2. abandons the queued tasks, whose callers get `DatabaseError.storeCleared`;
3. waits for the running tasks, up to `timeout`, then throws `.clearTimedOut` with the store intact;
4. resets the view context, destroys and recreates the store — with its `storeOptions`, from its
   `seedStoreURL` when there is one;
5. calls `didClear` and posts `Database.didClearNotification` synchronously, so every
   `FetchController` has already emitted `[]` when `clear()` returns.

Work enqueued after the call runs on the new store. Late batch merges from the old store are dropped.

## Exporting

```swift
try database.exportStore(to: exportURL)
```

Writes what is saved — write-ahead log included — to a single SQLite file, without touching the
open store: the file to bundle as a `seedStoreURL`. Unsaved changes are not exported.

## Testing

```swift
import Testing
import AmphoraKitTestSupport

@MainActor
struct NoteTests {
    let database = Database<AppSchema>.ephemeral()

    @Test func pinning() async throws {
        try database.resetForNextTest()                      // setup on first use, clear afterwards
        try await database.enqueueBackgroundTaskAndSave { context in /* … */ }
        try await awaitCondition { (try? Note.count(matching: .isPinned(true), in: database.viewContext)) == 1 }
    }
}
```

`RecordingLogger` captures what the database logs. `spinMainRunLoop()` lets pending merges land.

## AmphoraKit or SwiftData?

The surface is deliberately close to SwiftData: `@Entity`, `@Attribute` and `@Relationship` read
like `@Model` and its macros. What differs is what lies underneath — AmphoraKit is Core Data, with
nothing hidden:

| | AmphoraKit | SwiftData |
|---|---|---|
| Batch requests | insert, update and delete, typed (`insert([[AttributeAssignment]])`, `update(matching:set:)`) | delete only |
| Predicates | `NSPredicate` underneath: traversals, `SUBQUERY`, raw formats as an escape hatch | `#Predicate`, which refuses what it can't translate |
| Storage layout | yours: prefixed column names, `storeAs:` widths, raw values, `StorageConvertible`, coders onto an existing column type and format | chosen by the framework; `originalName:` renames, transformers and `Codable` values encode their own way |
| Model and migrations | an `.xcdatamodeld`, lightweight migrations, existing stores open as they are | the Swift schema, versioned schemas and migration plans |
| Concurrency | serial background queues by label with priorities, a fresh context per task, a `clear()` safe while tasks run, a coalescing `FetchController` | `ModelActor`, `@Query` |
| Contexts | typed by schema: a context of one model can't reach another's entities | one `ModelContext` type |

Pick AmphoraKit when an app already has a Core Data store, writes in bulk (a sync engine, an
importer), needs predicates `#Predicate` can't express, or must keep a column layout another
system shares. For a new app without those needs, SwiftData is the simpler choice. Both can be
open in one app: a file importing the two qualifies the macros, `@AmphoraKit.Attribute`.

## License

MIT — see [LICENSE](LICENSE).
