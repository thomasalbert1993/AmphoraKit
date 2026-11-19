import CoreData

extension DatabaseObject {

    /// Deletes every object matching the query with a batch request, and merges the deletions
    /// into the context and the view context.
    public static func deleteAll(matching query: Query = .all, in context: DatabaseContext<Schema>) throws {
        let request = NSBatchDeleteRequest(fetchRequest: baseFetchRequest(matching: query) as! NSFetchRequest<NSFetchRequestResult>)
        request.resultType = .resultTypeObjectIDs
        let result = try execute(request, in: context, "batch delete") as? NSBatchDeleteResult
        mergeBatchChanges(NSDeletedObjectsKey, objectIDs: result?.result as? [NSManagedObjectID], into: context)
    }

    /// Deletes every object matching a raw predicate. The escape hatch of the typed queries.
    public static func deleteAll(matching predicate: NSPredicate?, in context: DatabaseContext<Schema>) throws {
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
        fetchRequest.predicate = predicate
        let request = NSBatchDeleteRequest(fetchRequest: fetchRequest)
        request.resultType = .resultTypeObjectIDs
        let result = try execute(request, in: context, "batch delete") as? NSBatchDeleteResult
        mergeBatchChanges(NSDeletedObjectsKey, objectIDs: result?.result as? [NSManagedObjectID], into: context)
    }

    /// Inserts rows from dictionaries of attribute values with a batch request, and merges the
    /// insertions into the context and the view context.
    public static func insert(_ values: [[String: Any]], in context: DatabaseContext<Schema>) throws {
        guard !values.isEmpty else { return }
        let request = NSBatchInsertRequest(entityName: entityName, objects: values)
        request.resultType = .objectIDs
        let result = try execute(request, in: context, "batch insert") as? NSBatchInsertResult
        mergeBatchChanges(NSInsertedObjectsKey, objectIDs: result?.result as? [NSManagedObjectID], into: context)
    }

    /// Inserts rows of typed values with a batch request: `[[.id("a"), .order(1)], [.id("b"), .order(2)]]`.
    public static func insert(_ rows: [[AttributeAssignment]], in context: DatabaseContext<Schema>) throws {
        try insert(rows.map(AttributeAssignment.values), in: context)
    }

    /// Sets typed values on every object matching the query with a batch request: `set: [.isPinned(true)]`.
    public static func update(matching query: Query, set assignments: [AttributeAssignment], in context: DatabaseContext<Schema>) throws {
        try update(matching: query, AttributeAssignment.values(assignments), in: context)
    }

    /// Sets attribute values on every object matching the query with a batch request, and merges
    /// the updates into the context and the view context.
    public static func update(matching query: Query, _ values: [String: Any], in context: DatabaseContext<Schema>) throws {
        guard !values.isEmpty else { return }
        let request = NSBatchUpdateRequest(entityName: entityName)
        request.predicate = query.nsPredicate
        request.propertiesToUpdate = values
        request.resultType = .updatedObjectIDsResultType
        let result = try execute(request, in: context, "batch update") as? NSBatchUpdateResult
        mergeBatchChanges(NSUpdatedObjectsKey, objectIDs: result?.result as? [NSManagedObjectID], into: context)
    }

    private static func execute(_ request: NSPersistentStoreRequest, in context: DatabaseContext<Schema>, _ description: String) throws -> NSPersistentStoreResult {
        do {
            return try context.nsContext.execute(request)
        }
        catch {
            context.database?.configuration.logger?.error("Failed \(description) of \(entityName)", error)
            throw error
        }
    }

    /// Merges the object IDs of a batch request into the context synchronously, then into the
    /// view context on the main queue — deferred so the merge never lands in the middle of a
    /// SwiftUI render pass, and skipped when the store was cleared meanwhile.
    private static func mergeBatchChanges(_ key: String, objectIDs: [NSManagedObjectID]?, into context: DatabaseContext<Schema>) {
        guard let objectIDs, !objectIDs.isEmpty else { return }
        let changes = [key: objectIDs]
        NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [context.nsContext])
        if let database = context.database, context.nsContext !== database.persistentContainer.viewContext {
            database.mergeIntoViewContext(changes, queuedAt: database.currentStoreEpoch)
        }
    }
}
