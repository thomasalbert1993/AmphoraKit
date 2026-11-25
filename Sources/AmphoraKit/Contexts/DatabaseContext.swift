@preconcurrency import CoreData // the contexts run the closures on their queue; Core Data is not annotated for Sendable yet

/// A managed object context bound to a schema.
///
/// Every `Database` API hands out and takes `DatabaseContext<Schema>` rather than
/// `NSManagedObjectContext`, so a context of one model can never be given to the entities of
/// another: the mix is a compile error. The wrapper forwards what day-to-day code calls on a
/// context — reads through dynamic member lookup, writes through explicit methods — and exposes
/// the underlying `nsContext` for the rest.
///
@dynamicMemberLookup
public struct DatabaseContext<Schema: DatabaseSchema>: Sendable, Equatable {

    /// The underlying context.
    public let nsContext: NSManagedObjectContext

    init(_ nsContext: NSManagedObjectContext) {
        self.nsContext = nsContext
    }

    /// Wraps a context created outside of a `Database`. Debug builds check that the context's
    /// model is the schema's.
    public init(unsafe nsContext: NSManagedObjectContext) {
        assert(
            nsContext.persistentStoreCoordinator?.managedObjectModel === Schema.model
                || nsContext.parent?.persistentStoreCoordinator?.managedObjectModel === Schema.model,
            "The context's model is not \(Schema.self)'s"
        )
        self.init(nsContext)
    }

    /// The database that created the context, `nil` for a context created elsewhere.
    public var database: Database<Schema>? {
        // Read on the context's queue, from wherever it's asked (`isInViewContext`…).
        let box = nsContext.performAndWait { nsContext.userInfo[DatabaseBox.userInfoKey] as? DatabaseBox }
        return box?.database as? Database<Schema>
    }

    /// Reads any property of the underlying context: `context.hasChanges`, `context.deletedObjects`…
    public subscript<Value>(dynamicMember keyPath: KeyPath<NSManagedObjectContext, Value>) -> Value {
        nsContext[keyPath: keyPath]
    }

    public static func == (lhs: DatabaseContext, rhs: DatabaseContext) -> Bool {
        lhs.nsContext === rhs.nsContext
    }


    //-------------------
    // MARK: Forwarding
    //-------------------

    // Every operation runs on the context's queue (`performAndWait`, inline when already on it),
    // so that it is safe from any thread — the view context read from a background task included.

    public func perform(_ block: @escaping @Sendable () -> Void) {
        nsContext.perform(block)
    }

    public func performAndWait<T>(_ block: @Sendable () throws -> T) rethrows -> T {
        try nsContext.performAndWait(block)
    }

    public func save() throws {
        try nsContext.performAndWait { try nsContext.save() }
    }

    /// Saves when there are changes, inside `performAndWait`.
    public func saveIfNeeded() throws {
        try nsContext.performAndWait {
            if nsContext.hasChanges {
                try nsContext.save()
            }
        }
    }

    public func rollback() {
        nsContext.performAndWait { nsContext.rollback() }
    }

    public func reset() {
        nsContext.performAndWait { nsContext.reset() }
    }

    public func refreshAllObjects() {
        nsContext.performAndWait { nsContext.refreshAllObjects() }
    }

    public func processPendingChanges() {
        nsContext.performAndWait { nsContext.processPendingChanges() }
    }

    public func refresh(_ object: NSManagedObject, mergeChanges: Bool) {
        nonisolated(unsafe) let object = object // used on the context's queue, the object's own
        nsContext.performAndWait { nsContext.refresh(object, mergeChanges: mergeChanges) }
    }

    /// Marks an object of the schema for deletion.
    public func delete<T: DatabaseObject>(_ object: T) where T.Schema == Schema {
        nonisolated(unsafe) let object = object // used on the context's queue, the object's own
        nsContext.performAndWait { nsContext.delete(object) }
    }

    /// Runs a fetch request of the schema.
    public func fetch<T: DatabaseObject>(_ request: NSFetchRequest<T>) throws -> [T] where T.Schema == Schema {
        try nsContext.performAndWait { try nsContext.fetch(request) }
    }

    /// Counts the objects a fetch request of the schema matches.
    public func count<T: DatabaseObject>(for request: NSFetchRequest<T>) throws -> Int where T.Schema == Schema {
        try nsContext.performAndWait { try nsContext.count(for: request) }
    }

    /// Runs a store request — a batch request — on the context.
    func execute(_ request: NSPersistentStoreRequest) throws -> NSPersistentStoreResult {
        try nsContext.performAndWait { try nsContext.execute(request) }
    }

    /// The object with the identifier, fetched if needed.
    public func existingObject<T: DatabaseObject>(with objectID: NSManagedObjectID, as type: T.Type = T.self) throws -> T where T.Schema == Schema {
        guard let object = try nsContext.performAndWait({ try nsContext.existingObject(with: objectID) }) as? T else {
            throw DatabaseError.notFound(entity: T.entityName, id: objectID.uriRepresentation().absoluteString)
        }
        return object
    }

    /// How long fetched values are trusted before being refetched, in seconds.
    public var stalenessInterval: TimeInterval {
        get { nsContext.stalenessInterval }
        nonmutating set { nsContext.stalenessInterval = newValue }
    }

    /// The merge policy.
    public var mergePolicy: DatabaseConfiguration.MergePolicy? {
        get {
            switch nsContext.mergePolicy as? NSMergePolicy {
                case NSMergePolicy.error?: return .error
                case NSMergePolicy.mergeByPropertyStoreTrump?: return .propertyStoreTrump
                case NSMergePolicy.mergeByPropertyObjectTrump?: return .propertyObjectTrump
                case NSMergePolicy.overwrite?: return .overwrite
                case NSMergePolicy.rollback?: return .rollback
                default: return nil
            }
        }
        nonmutating set {
            if let newValue {
                nsContext.mergePolicy = newValue.nsMergePolicy
            }
        }
    }
}

/// The weak back-reference a `Database` leaves in the `userInfo` of every context it creates.
final class DatabaseBox: NSObject {

    static let userInfoKey = "AmphoraKit.database"

    weak var database: AnyObject?

    init(_ database: AnyObject) {
        self.database = database
    }
}
