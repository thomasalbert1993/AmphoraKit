import CoreData

/// A typed value written on one object (`update(with:)`): an attribute in its stored form, like an
/// `AttributeAssignment`, or a relationship, to the related object (or objects) itself.
///
/// `@Entity` generates the entity's `Assignment`, every `AttributeAssignment` member included, plus
/// one per relationship: `.reel(reel)` for a to-one, `.takes(takes)` for a to-many. A related
/// object is passed as fetched by the caller, who decides what a missing one means: `.reel(try?
/// .fetch(id: reelId, in: context))`. Batch requests can't set relationships: they take
/// `AttributeAssignment`s only.
///
public protocol EntityAssignment {

    /// The entity.
    associatedtype Root: DatabaseObject

    /// The storage key of the attribute or relationship.
    var storageKey: String { get }

    /// The value in its stored form — the related object, or set of objects — `nil` for none.
    var storageValue: Any? { get }

    /// Creates an assignment from a key and a stored value.
    init(storageKey: String, storageValue: Any?)
}

extension EntityAssignment {

    /// The assignment writing an attribute assignment's stored value.
    public init<A: EntityAttributeAssignment>(_ assignment: A) where A.Root == Root {
        self.init(storageKey: assignment.storageKey, storageValue: assignment.storageValue)
    }
}

/// The `Assignment` of an entity without generated members: values are written by key.
public struct UntypedAssignment<Root: DatabaseObject>: EntityAssignment {

    /// The storage key of the attribute or relationship.
    public let storageKey: String

    /// The value in its stored form, `nil` for none.
    public let storageValue: Any?

    public init(storageKey: String, storageValue: Any?) {
        self.storageKey = storageKey
        self.storageValue = storageValue
    }
}
