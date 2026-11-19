import CoreData

/// A value applied on one object (`apply(_:)`): an attribute in its stored form, like an
/// `Assignment`, or a relationship — to objects, or to the objects of identifiers resolved in the
/// object's own context when applied.
///
/// `@Entity` generates the entity's `Change`, every `Assignment` member included, plus four per
/// relationship: `.reel(reel)` and `.reel(id:)` for a to-one, `.takes(takes)` and `.takes(ids:)`
/// for a to-many. Batch requests can't set relationships: they take `Assignment`s only.
///
public protocol EntityChange {

    /// The entity.
    associatedtype Root: DatabaseObject

    /// The storage key of the attribute or relationship.
    var storageKey: String { get }

    /// The value, resolved when applied.
    var value: ChangeValue { get }

    /// Creates a change from a key and a value.
    init(storageKey: String, value: ChangeValue)
}

extension EntityChange {

    /// The change writing an assignment's stored value.
    public init<A: EntityAssignment>(_ assignment: A) where A.Root == Root {
        self.init(storageKey: assignment.storageKey, value: .stored(assignment.storageValue))
    }
}

/// The value of a change, resolved in the changed object's context when applied.
public struct ChangeValue {

    /// The value to write, from the object's context.
    let resolve: (NSManagedObjectContext?) -> Any?

    /// A value in its stored form, `nil` for none.
    public static func stored(_ value: Any?) -> ChangeValue {
        ChangeValue { _ in value }
    }

    /// The related object of a to-one relationship, `nil` for none.
    public static func object<Target: DatabaseObject>(_ target: Target?) -> ChangeValue {
        ChangeValue { _ in target }
    }

    /// The related objects of a to-many relationship.
    public static func objects<Target: DatabaseObject>(_ targets: [Target]) -> ChangeValue {
        ChangeValue { _ in Set(targets) }
    }

    /// The object of an identifier, for a to-one relationship: none when the context holds none.
    public static func object<Target: DatabaseObject>(_ type: Target.Type, id: Target.ID) -> ChangeValue {
        ChangeValue { context in context.flatMap { Target.object(withID: id, in: $0) } }
    }

    /// The objects of identifiers the context holds, for a to-many relationship.
    public static func objects<Target: DatabaseObject>(_ type: Target.Type, ids: [Target.ID]) -> ChangeValue {
        ChangeValue { context in Set(context.map { Target.objects(withIDs: ids, in: $0) } ?? []) }
    }
}

/// The `Change` of an entity without generated members: changes are written by key.
public struct UntypedChange<Root: DatabaseObject>: EntityChange {

    /// The storage key of the attribute or relationship.
    public let storageKey: String

    /// The value, resolved when applied.
    public let value: ChangeValue

    public init(storageKey: String, value: ChangeValue) {
        self.storageKey = storageKey
        self.value = value
    }
}
