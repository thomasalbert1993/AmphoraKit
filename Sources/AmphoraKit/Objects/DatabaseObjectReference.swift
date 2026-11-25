import CoreData

/// A `Sendable` handle on an object, by identifier: what crosses queues and actors, resolved again
/// in the context that needs the object.
///
/// ```swift
/// let reference = note.reference                       // on the note's queue
/// try await database.enqueueBackgroundTaskAndSave { context in
///     guard let note = try reference.resolve(in: context) else { return }
///     …
/// }
/// ```
///
/// Typed by the entity it was taken from: a sub-entity's reference resolves to the sub-entity.
public struct DatabaseObjectReference<Object: IdentifiableDatabaseObject>: Sendable, Hashable, Identifiable where Object.ID: Sendable {

    /// The identifier of the object.
    public let id: Object.ID

    /// A reference to the object with the identifier.
    public init(id: Object.ID) {
        self.id = id
    }

    /// A reference to the object. Reads its identifier: call it on the object's queue.
    public init(_ object: Object) {
        self.id = object.id
    }

    /// The object in a context, `nil` when there is none with the identifier.
    public func resolve(in context: DatabaseContext<Object.Schema>) throws -> Object? {
        try Object.fetchFirst(id: id, in: context)
    }
}

extension IdentifiableDatabaseObject where ID: Sendable {

    /// A `Sendable` reference to the object. Reads its identifier: call it on the object's queue.
    public var reference: DatabaseObjectReference<Self> {
        DatabaseObjectReference(self)
    }
}

extension Sequence {

    /// The objects in a context, in the order of the references, those that no longer exist left
    /// out. One fetch.
    public func resolve<Object>(in context: DatabaseContext<Object.Schema>) throws -> [Object] where Element == DatabaseObjectReference<Object> {
        let ids = map(\.id)
        let objects = try Object.fetch(ids: ids, in: context)
        let byID = Dictionary(objects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }
}


//-------------------
// MARK: Contexts
//-------------------

extension DatabaseObject {

    /// The same object in another context, `nil` when it doesn't exist there — deleted, or never
    /// saved: an object with a temporary identifier only lives in its own context.
    public func `in`(_ context: DatabaseContext<Schema>) -> Self? {
        if managedObjectContext === context.nsContext {
            return self
        }
        return (try? context.nsContext.existingObject(with: objectID)) as? Self
    }

    /// The context of the object, `nil` once it was deleted and saved, or its context reset.
    public var databaseContext: DatabaseContext<Schema>? {
        managedObjectContext.map { DatabaseContext<Schema>($0) }
    }

    /// Whether the object lives in the view context of its database.
    public var isInViewContext: Bool {
        guard let managedObjectContext, let database = DatabaseContext<Schema>(managedObjectContext).database else {
            return false
        }
        return managedObjectContext === database.persistentContainer.viewContext
    }
}

extension Sequence where Element: DatabaseObject {

    /// The same objects in another context, in order, those that don't exist there left out.
    public func `in`(_ context: DatabaseContext<Element.Schema>) -> [Element] {
        compactMap { $0.in(context) }
    }
}
