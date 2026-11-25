@preconcurrency import CoreData // the contexts run the closures on their queue; Core Data is not annotated for Sendable yet

extension IdentifiableDatabaseObject {

    /// The object with the identifier.
    ///
    /// - Throws: `DatabaseError.notFound` when there is none.
    public static func fetch(id: ID, in context: DatabaseContext<Schema>) throws -> Self {
        guard let object = try fetchFirst(matching: .id(id), in: context) else {
            throw DatabaseError.notFound(entity: entityName, id: String(describing: id))
        }
        return object
    }

    /// The object with the identifier, `nil` when there is none.
    public static func fetchFirst(id: ID, in context: DatabaseContext<Schema>) throws -> Self? {
        try fetchFirst(matching: .id(id), in: context)
    }

    /// The object with the identifier, `nil` when there is none or the fetch fails (logged).
    public static func fetchFirstOrNil(id: ID, in context: DatabaseContext<Schema>) -> Self? {
        fetchFirstOrNil(matching: .id(id), in: context)
    }

    /// The objects with the identifiers, in no particular order.
    public static func fetch(ids: [ID], in context: DatabaseContext<Schema>) throws -> [Self] {
        guard !ids.isEmpty else { return [] }
        return try fetch(matching: .ids(ids), in: context)
    }

    /// The objects with the identifiers, in no particular order, an empty array when the fetch
    /// fails (logged).
    public static func fetchOrEmpty(ids: [ID], in context: DatabaseContext<Schema>) -> [Self] {
        guard !ids.isEmpty else { return [] }
        return fetchOrEmpty(matching: .ids(ids), in: context)
    }

    /// Inserts an object with the identifier, then calls `didCreate()`.
    ///
    /// The identifier belongs to the root entity: an object of another sub-entity holding it
    /// counts as existing.
    ///
    /// - Throws: `DatabaseError.alreadyExists` when an object has the identifier,
    ///   `DatabaseError.abstractEntity` when the entity is abstract, or the fetch error.
    @discardableResult
    public static func create(id: ID, in context: DatabaseContext<Schema>) throws -> Self {
        if try objectInHierarchy(id: id, in: context) != nil {
            throw DatabaseError.alreadyExists(entity: entityName, id: String(describing: id))
        }
        return try insert(id: id, in: context)
    }

    /// The object with the identifier, inserted with just that identifier — then `didCreate()` —
    /// when there is none.
    ///
    /// - Throws: `DatabaseError.alreadyExists` when an object of another sub-entity holds the
    ///   identifier, `DatabaseError.abstractEntity` when it would insert into an abstract entity,
    ///   or the fetch error.
    public static func fetchOrCreate(id: ID, in context: DatabaseContext<Schema>) throws -> Self {
        if let existing = try objectInHierarchy(id: id, in: context) {
            guard let object = existing as? Self else {
                throw DatabaseError.alreadyExists(entity: existing.entity.name ?? entityName, id: String(describing: id))
            }
            return object
        }
        return try insert(id: id, in: context)
    }

    /// The object holding the identifier anywhere in the entity's hierarchy, the root's
    /// sub-entities included.
    private static func objectInHierarchy(id: ID, in context: DatabaseContext<Schema>) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: RootEntity.entityName)
        request.predicate = RootEntity.Query.id(id).nsPredicate
        request.fetchLimit = 1
        return try context.nsContext.performAndWait { try context.nsContext.fetch(request).first }
    }

    private static func insert(id: ID, in context: DatabaseContext<Schema>) throws -> Self {
        guard !isAbstract(in: context) else {
            throw DatabaseError.abstractEntity(entityName)
        }
        // Inserted and set up on the context's queue, safe from any thread.
        nonisolated(unsafe) let storedID: Any = id
        return context.nsContext.performAndWait {
            let object = Self(context: context)
            object.setValue(storedID, forKey: idKey)
            object.didCreate()
            return object
        }
    }

    /// Deletes the object with the identifier, if any, with a batch request.
    public static func delete(id: ID, in context: DatabaseContext<Schema>) throws {
        try deleteAll(matching: .id(id), in: context)
    }

    /// Deletes the objects with the identifiers with a batch request.
    public static func delete(ids: [ID], in context: DatabaseContext<Schema>) throws {
        guard !ids.isEmpty else { return }
        try deleteAll(matching: .ids(ids), in: context)
    }

    /// Sets typed values on the objects with the identifiers with a batch request.
    public static func update(ids: [ID], set assignments: [AttributeAssignment], in context: DatabaseContext<Schema>) throws {
        try update(ids: ids, AttributeAssignment.values(assignments), in: context)
    }

    /// Sets attribute values on the objects with the identifiers with a batch request.
    public static func update(ids: [ID], _ values: [String: Any], in context: DatabaseContext<Schema>) throws {
        guard !ids.isEmpty else { return }
        try update(matching: .ids(ids), values, in: context)
    }
}
