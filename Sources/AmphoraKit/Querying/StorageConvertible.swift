import Foundation

/// A value stored in Core Data under another representation — a struct kept as a string, a
/// composite encoded as text.
///
/// `RawRepresentable` types need no conformance: enums stored by their raw value already fit.
/// Other types declare how they round-trip:
///
/// ```swift
/// struct BarBeatPosition: StorageConvertible {
///     var storage: String { "\(bar)-\(beat)" }
///     init?(storage: String) { … }
/// }
/// ```
///
/// Both kinds are read back with `fromStorage(_:)` and compared in predicates through their
/// storage value.
///
public protocol StorageConvertible {

    /// The stored representation.
    associatedtype Storage

    /// Decodes a value from its stored representation, `nil` when it doesn't parse.
    init?(storage: Storage)

    /// The stored representation of the value.
    var storage: Storage { get }
}

extension StorageConvertible {

    /// The Core Data column type of an `@Attribute` declared without `storeAs:`: the storage.
    public typealias StoredColumn = Storage

    /// The column type of an optional `@Attribute` declared without `storeAs:`: the optional
    /// storage. A `NilStorageConvertible` declares its own, the non-optional storage.
    public typealias OptionalStoredColumn = Storage?

    /// Decodes a value from its stored representation.
    public static func fromStorage(_ storage: Storage) -> Self? {
        Self(storage: storage)
    }
}

extension RawRepresentable {

    /// The Core Data column type of an `@Attribute` declared without `storeAs:`: the raw value.
    /// A type declares its own `StoredColumn` to store in another width (an `Int` raw value in an
    /// `Int32` column), or to choose when it is also `StorageConvertible` under another type.
    public typealias StoredColumn = RawValue

    /// The column type of an optional `@Attribute` declared without `storeAs:`: the optional raw
    /// value.
    public typealias OptionalStoredColumn = RawValue?

    /// Decodes a value from its raw value.
    public static func fromStorage(_ storage: RawValue) -> Self? {
        Self(rawValue: storage)
    }
}

/// A `StorageConvertible` whose absence is stored as a value rather than as `nil`: an integer
/// code with `0` for none, in a non-optional scalar column.
///
/// ```swift
/// extension TimeSignature: NilStorageConvertible {
///     static var nilStorage: Int32 { 0 }
///     typealias OptionalStoredColumn = Int32
///     …
/// }
///
/// @Attribute var timeSignature: TimeSignature?     // @NSManaged var a_timeSignature: Int32
/// ```
///
/// Writing `nil` stores `nilStorage`, and `isNil`, `isNotNil` and comparisons with `nil` match
/// it. The alias has to be declared by the type: one provided by this protocol would be
/// ambiguous with the one `StorageConvertible` provides.
///
public protocol NilStorageConvertible: StorageConvertible {

    /// The storage of a missing value.
    static var nilStorage: Storage { get }
}

/// The storage of `nil` for an optional of `type`: the `nilStorage` of a `NilStorageConvertible`
/// wrapped type, `nil` otherwise.
func nilStorage(forOptional type: Any.Type) -> Any? {
    guard let optional = type as? any OptionalValue.Type,
          let convertible = optional.wrappedType as? any NilStorageConvertible.Type else {
        return nil
    }
    return convertible.anyNilStorage
}

extension NilStorageConvertible {

    /// `nilStorage`, type-erased.
    static var anyNilStorage: Any {
        nilStorage
    }
}

/// An optional, seen through a protocol so that `Match` can offer `isNil` and the wrapped type's
/// comparisons on optional attributes.
public protocol OptionalValue {

    /// The wrapped type.
    associatedtype Wrapped

    /// The wrapped value, if any.
    var wrappedValue: Wrapped? { get }

    /// The wrapped type.
    static var wrappedType: Any.Type { get }
}

extension Optional: OptionalValue {

    public var wrappedValue: Wrapped? {
        self
    }

    public static var wrappedType: Any.Type {
        Wrapped.self
    }
}

/// The value a predicate compares against for a given Swift value: the storage of a
/// `StorageConvertible`, the raw value of a `RawRepresentable`, the unwrapped optional, the value
/// itself otherwise. `nil` stands for a missing value — but the `nilStorage` of a
/// `NilStorageConvertible`.
func storageValue(of value: Any) -> Any? {
    if let optional = value as? any OptionalValue {
        guard let wrapped = optional.wrappedValue else { return nilStorage(forOptional: type(of: value)) }
        return storageValue(of: wrapped)
    }
    if let convertible = value as? any StorageConvertible {
        return storageValue(of: convertible.storage)
    }
    // A collection of enums or composites is stored element by element. A string is a
    // collection too, of characters: it is a value.
    if !(value is String) {
        if let set = value as? Set<AnyHashable> {
            return Set(set.compactMap { storageValue(of: $0.base) as? AnyHashable })
        }
        if let array = value as? [Any] {
            return array.compactMap { storageValue(of: $0) }
        }
    }
    if let representable = value as? any RawRepresentable {
        return storageValue(of: representable.rawValue)
    }
    return value
}
