import CoreData

/// Generates the typed queries, sorts and fields of an entity, and the domain accessors of its
/// storage properties.
///
/// Reads every `@NSManaged` property of the class and every `@Stored` declaration, and adds to
/// the class:
/// - `struct Query: EntityQuery` with two static functions per attribute (`.name(Match<String>)`,
///   `.name("x")`), two per to-one relationship taking a nullability match or the target's query
///   (`.folder(.name("x"))`), one per to-many relationship taking a `CollectionMatch`;
/// - `struct Sort: EntitySort` with one static per attribute;
/// - `struct Assignment: EntityAssignment` with one static per attribute encoding the value to its
///   stored form, for `insert`, `update(matching:set:)` and `update(with:)`: `[.order(3)]`;
/// - the `@NSManaged` storage of every `@Attribute` / `@Relationship` declaration;
/// - one static `Field` per attribute and to-one relationship, for the expression form of the
///   queries: `Note.score > 2 && Note.name == "x"`;
/// - a read-only domain accessor for every prefixed storage property that has no `@Stored`
///   declaration and no member of the same name: `var text: String { a_text }`.
///
/// Attribute names come from `@Stored` declarations when there is one, otherwise from the storage
/// name with its prefix removed. Types come from `@Stored` declarations when there is one,
/// otherwise from the storage type. A storage property marked `@StorageOnly` gets nothing; a
/// nested `Query` or `Sort` the class declares itself is kept.
///
/// - Parameter attributePrefix: The prefix of the attribute storage properties, `"a_"` for `a_text`.
/// - Parameter relationshipPrefix: The prefix of the relationship storage properties, `"r_"` for `r_folder`.
/// - Parameter generatesAccessors: Whether to write the domain accessors. The macro only sees the
///   class body: turn it off when the accessors live in extensions, where a generated one would be
///   a redeclaration.
///
@attached(member, names: named(Query), named(Sort), named(Assignment), arbitrary)
public macro Entity(attributePrefix: String = "", relationshipPrefix: String = "", generatesAccessors: Bool = true) = #externalMacro(module: "AmphoraKitMacrosPlugin", type: "EntityMacro")

/// Leaves a storage property out of what `@Entity` generates: no query, no field, no sort, no accessor.
///
/// ```swift
/// @StorageOnly @NSManaged var a_shapeVersion: Int64
/// ```
///
@attached(peer)
public macro StorageOnly() = #externalMacro(module: "AmphoraKitMacrosPlugin", type: "StorageOnlyMacro")

/// Exposes a storage property under a domain name and type.
///
/// ```swift
/// @Stored(\Note.a_pinned) var isPinned: Bool
/// @Stored(\Note.a_kind, default: Kind.note) var kind: Kind       // Kind: RawRepresentable or StorageConvertible
/// @Stored(\Note.a_startBarsBeats) var start: BarBeatPosition?     // nil when the text doesn't decode
/// @Stored(\Note.r_cue) var cue: Cue?                              // nil when the object is a zombie
/// @Stored(\Note.r_tags, access: .readWrite) var tags: [Tag]       // zombies removed
/// ```
///
/// The property becomes computed. Its type decides the conversion: identical to the storage,
/// a `RawRepresentable` or `StorageConvertible` decoded from it (optional, or with a `default`),
/// a relationship read zombie-safe. `@Entity` reads these declarations to name and type the
/// queries.
///
/// The key path needs its root (`\Note.a_kind`) and the default its type (`Kind.note`): the macro
/// is checked before the type's members exist, so neither can be inferred.
///
@attached(accessor)
public macro Stored<Root, Value>(_ keyPath: KeyPath<Root, Value>, access: StoredAccess = .readonly) = #externalMacro(module: "AmphoraKitMacrosPlugin", type: "StoredMacro")

/// Exposes a storage property under a domain name and type, with a fallback when the stored
/// value doesn't decode. See `Stored(_:access:)`.
@attached(accessor)
public macro Stored<Root, Value, Exposed>(_ keyPath: KeyPath<Root, Value>, default: Exposed, access: StoredAccess = .readonly) = #externalMacro(module: "AmphoraKitMacrosPlugin", type: "StoredMacro")


/// Declares an attribute in one line: `@Entity` on the class writes the `@NSManaged` storage, the
/// property becomes its accessor.
///
/// ```swift
/// @Attribute var name: String                                          // @NSManaged var a_name: String
/// @Attribute("a_sortOrder", storeAs: Int32.self) var order: Int          // stored in another width
/// @Attribute(default: Kind.note) var kind: Kind                         // RawRepresentable, a_kind: String
/// @Attribute var start: BarBeatPosition?                                // StorageConvertible, a_start: String?
/// @Attribute(storeAs: String?.self, default: Kind.note) var kind: Kind   // optional column, non-optional property
/// @Attribute(storeAs: Set<String>?.self) var labels: Set<String>         // optional column, empty for nil
/// @Attribute(access: .readWrite) var isPinned: Bool                      // with a setter
/// ```
///
/// The storage name is the property name behind the `attributePrefix` of the enclosing `@Entity`,
/// unless given. Without `storeAs:`, the column takes the property's type when Core Data stores
/// it as is, and `Type.StoredColumn` otherwise — the raw value of a `RawRepresentable`, the storage
/// of a `StorageConvertible`, or the type's own `typealias StoredColumn`. `storeAs:` stays for a
/// column whose optionality differs from the property's, an `Int` in another width, a collection
/// of converted values and a coder. The storage stays `internal` (or the property's `public`/`package`): `#keyPath`
/// and the key-value APIs need to reach it. `storeAs:` is for lossless, order-preserving
/// encodings only — integer widths, raw values, `StorageConvertible` — so that the typed queries
/// `@Entity` generates on the exposed type stay right; unit conversions stay hand-written.
///
@attached(accessor)
public macro Attribute(_ name: String? = nil, access: StoredAccess = .readonly) = #externalMacro(module: "AmphoraKitMacrosPlugin", type: "AttributeMacro")

/// Declares an attribute with a fallback when the stored value doesn't decode, its column type
/// inferred. See `Attribute(_:access:)`.
@attached(accessor)
public macro Attribute<Exposed>(_ name: String? = nil, default: Exposed, access: StoredAccess = .readonly) = #externalMacro(module: "AmphoraKitMacrosPlugin", type: "AttributeMacro")

/// Declares an attribute stored in another type. See `Attribute(_:access:)`.
@attached(accessor)
public macro Attribute<Stored>(_ name: String? = nil, storeAs: Stored.Type, access: StoredAccess = .readonly) = #externalMacro(module: "AmphoraKitMacrosPlugin", type: "AttributeMacro")

/// Declares an attribute stored in another type, with a fallback when the stored value doesn't
/// decode. See `Attribute(_:access:)`.
@attached(accessor)
public macro Attribute<Stored, Exposed>(_ name: String? = nil, storeAs: Stored.Type, default: Exposed, access: StoredAccess = .readonly) = #externalMacro(module: "AmphoraKitMacrosPlugin", type: "AttributeMacro")

/// Declares an attribute encoded by a coder: `@Attribute(coder: ScaleChainCoder.self) var
/// scales: [Scale]`, the column typed by the coder's `Stored`. The accessor, the queries and the
/// assignments go through the coder; the column gets no sort and no static field. See
/// `StorageCoder`.
@attached(accessor)
public macro Attribute<Coder: StorageCoder>(_ name: String? = nil, coder: Coder.Type, access: StoredAccess = .readonly) = #externalMacro(module: "AmphoraKitMacrosPlugin", type: "AttributeMacro")

/// Declares an attribute encoded by a coder, its column type spelled out. See
/// `Attribute(_:coder:access:)`.
@attached(accessor)
public macro Attribute<Stored, Coder: StorageCoder>(_ name: String? = nil, storeAs: Stored.Type, coder: Coder.Type, access: StoredAccess = .readonly) = #externalMacro(module: "AmphoraKitMacrosPlugin", type: "AttributeMacro") where Coder.Stored == Stored

/// Declares a relationship in one line: `@Entity` on the class writes the `@NSManaged` storage,
/// the property becomes its zombie-safe accessor.
///
/// ```swift
/// @Relationship var cue: Cue?            // @NSManaged var r_cue: Cue?, nil when it is a zombie
/// @Relationship var notes: [Note]        // @NSManaged var r_notes: Set<Note>, zombies removed
/// @Relationship(.sorted) var cues: [Cue]  // sorted by Cue's Comparable conformance
/// ```
///
/// The storage name is the property name behind the `relationshipPrefix` of the enclosing
/// `@Entity`, unless given. A to-many relationship reads in no particular order, unless
/// declared `.sorted`.
///
@attached(accessor)
public macro Relationship(_ name: String? = nil, access: StoredAccess = .readonly) = #externalMacro(module: "AmphoraKitMacrosPlugin", type: "RelationshipMacro")

/// Declares a to-many relationship read in order: `.sorted` sorts its objects by the target's
/// `Comparable` conformance, a compile error when it has none. See `Relationship(_:access:)`.
@attached(accessor)
public macro Relationship(_ order: RelationshipOrder, _ name: String? = nil, access: StoredAccess = .readonly) = #externalMacro(module: "AmphoraKitMacrosPlugin", type: "RelationshipMacro")
