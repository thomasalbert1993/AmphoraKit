import Foundation

/// A typed value for one attribute of an entity, the nested `AttributeAssignment` type `@Entity`
/// generates: `[.order(3), .kind(.marker)]` instead of `["a_sortOrder": Int32(3), "a_kind": "marker"]`.
///
/// Each generated member names the column and encodes the value to its stored form, so the key
/// and the value type are both checked by the compiler. Attributes only: the batch requests take
/// these, and can't set relationships — `EntityAssignment` adds them, for one object.
///
public protocol EntityAttributeAssignment {

    /// The entity. Left unconstrained, like `EntityQuery.Root`.
    associatedtype Root

    /// The storage key of the attribute.
    var storageKey: String { get }

    /// The value in its stored form, `nil` for none.
    var storageValue: Any? { get }

    /// Creates an assignment from a key and a stored value.
    init(storageKey: String, storageValue: Any?)
}

extension EntityAttributeAssignment {

    /// The assignments as the dictionary Core Data's key-value and batch APIs take, `NSNull` for `nil`.
    public static func values(_ assignments: [Self]) -> [String: Any] {
        var values: [String: Any] = [:]
        for assignment in assignments {
            values[assignment.storageKey] = assignment.storageValue ?? NSNull()
        }
        return values
    }
}

extension EntityAttributeAssignment where Root: IdentifiableDatabaseObject {

    /// Sets the identifier.
    public static func id(_ id: Root.ID) -> Self {
        .init(storageKey: Root.idKey, storageValue: id)
    }
}

/// The assignment type of an entity without generated members, written by key only.
public struct UntypedAttributeAssignment<Root>: EntityAttributeAssignment {

    /// The storage key of the attribute.
    public let storageKey: String

    /// The value in its stored form, `nil` for none.
    public let storageValue: Any?

    /// Creates an assignment from a key and a stored value.
    public init(storageKey: String, storageValue: Any?) {
        self.storageKey = storageKey
        self.storageValue = storageValue
    }
}
