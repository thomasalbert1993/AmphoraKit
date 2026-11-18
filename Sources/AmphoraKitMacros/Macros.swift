import CoreData
@_exported import AmphoraKit

/// Generates the typed queries, sorts and fields of an entity, and the domain accessors of its
/// storage properties.
///
/// Reads every `@NSManaged` property of the class and every `@Stored` declaration, and adds to
/// the class:
/// - `struct Query: EntityQuery` with two static functions per attribute (`.name(Match<String>)`,
///   `.name("x")`), two per to-one relationship taking a nullability match or the target's query
///   (`.folder(.name("x"))`), one per to-many relationship taking a `CollectionMatch`;
/// - `struct Sort: EntitySort` with one static per attribute;
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
///
@attached(member, names: named(Query), named(Sort), arbitrary)
public macro Entity(attributePrefix: String = "", relationshipPrefix: String = "") = #externalMacro(module: "AmphoraKitMacrosPlugin", type: "EntityMacro")

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

