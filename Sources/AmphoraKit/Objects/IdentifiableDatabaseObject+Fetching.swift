import CoreData

extension IdentifiableDatabaseObject {

    /// The object with the identifier.
    ///
    /// - Throws: `DatabaseError.notFound` when there is none.
    public static func fetch(id: ID, in context: DatabaseContext<Schema>, prefetching relationships: [String] = []) throws -> Self {
        let request = baseFetchRequest(matching: .id(id), limit: 1)
        request.relationshipKeyPathsForPrefetching = relationships
        guard let object = try context.fetch(request).first else {
            throw DatabaseError.notFound(entity: entityName, id: String(describing: id))
        }
        return object
    }

    /// The objects with the identifiers, in no particular order.
    public static func fetch(ids: [ID], in context: DatabaseContext<Schema>, prefetching relationships: [String] = []) throws -> [Self] {
        guard !ids.isEmpty else { return [] }
        let request = baseFetchRequest(matching: .ids(ids))
        request.relationshipKeyPathsForPrefetching = relationships
        return try context.fetch(request)
    }

    /// The object with the identifier, inserted with just that identifier when there is none.
    public static func fetchOrCreate(id: ID, in context: DatabaseContext<Schema>) throws -> Self {
        if let existing = try first(matching: .id(id), in: context) {
            return existing
        }
        let object = Self(context: context.nsContext)
        object.setValue(id, forKey: idKey)
        return object
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

    /// Sets attribute values on the objects with the identifiers with a batch request.
    public static func update(ids: [ID], _ values: [String: Any], in context: DatabaseContext<Schema>) throws {
        guard !ids.isEmpty else { return }
        try update(matching: .ids(ids), values, in: context)
    }
}
