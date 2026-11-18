import CoreData

extension DatabaseObject {

    //-------------------
    // MARK: Requests
    //-------------------

    /// A fetch request on the entity, filtered, sorted and limited.
    public static func baseFetchRequest(matching queries: [Query] = [], sortedBy sorts: [Sort] = [], limit: Int? = nil) -> NSFetchRequest<Self> {
        let request = NSFetchRequest<Self>(entityName: entityName)
        request.predicate = Query.all(of: queries)?.nsPredicate
        request.sortDescriptors = sorts.map(\.nsSortDescriptor)
        if let limit {
            request.fetchLimit = limit
        }
        return request
    }

    /// A fetch request on the entity, filtered by one query.
    public static func baseFetchRequest(matching query: Query, sortedBy sorts: [Sort] = [], limit: Int? = nil) -> NSFetchRequest<Self> {
        baseFetchRequest(matching: [query], sortedBy: sorts, limit: limit)
    }


    //-------------------
    // MARK: Throwing
    //-------------------

    /// The objects matching every query, sorted.
    public static func fetch(matching queries: [Query] = [], sortedBy sorts: [Sort] = [], limit: Int? = nil, in context: DatabaseContext<Schema>) throws -> [Self] {
        try context.fetch(baseFetchRequest(matching: queries, sortedBy: sorts, limit: limit))
    }

    /// The objects matching the query, sorted.
    public static func fetch(matching query: Query, sortedBy sorts: [Sort] = [], limit: Int? = nil, in context: DatabaseContext<Schema>) throws -> [Self] {
        try fetch(matching: [query], sortedBy: sorts, limit: limit, in: context)
    }

    /// The objects a request returns.
    public static func fetch(request: NSFetchRequest<Self>, in context: DatabaseContext<Schema>) throws -> [Self] {
        try context.fetch(request)
    }

    /// The first object matching every query, in the sort order.
    public static func first(matching queries: [Query] = [], sortedBy sorts: [Sort] = [], in context: DatabaseContext<Schema>) throws -> Self? {
        try fetch(matching: queries, sortedBy: sorts, limit: 1, in: context).first
    }

    /// The first object matching the query, in the sort order.
    public static func first(matching query: Query, sortedBy sorts: [Sort] = [], in context: DatabaseContext<Schema>) throws -> Self? {
        try first(matching: [query], sortedBy: sorts, in: context)
    }

    /// How many objects match every query.
    public static func count(matching queries: [Query] = [], in context: DatabaseContext<Schema>) throws -> Int {
        try context.count(for: baseFetchRequest(matching: queries))
    }

    /// How many objects match the query.
    public static func count(matching query: Query, in context: DatabaseContext<Schema>) throws -> Int {
        try count(matching: [query], in: context)
    }


    //-------------------
    // MARK: Logged
    //-------------------

    /// The objects matching every query, an empty array when the fetch fails (logged).
    public static func fetchOrEmpty(matching queries: [Query] = [], sortedBy sorts: [Sort] = [], limit: Int? = nil, in context: DatabaseContext<Schema>) -> [Self] {
        logged(in: context, "fetch \(entityName)") { try fetch(matching: queries, sortedBy: sorts, limit: limit, in: context) } ?? []
    }

    /// The objects matching the query, an empty array when the fetch fails (logged).
    public static func fetchOrEmpty(matching query: Query, sortedBy sorts: [Sort] = [], limit: Int? = nil, in context: DatabaseContext<Schema>) -> [Self] {
        fetchOrEmpty(matching: [query], sortedBy: sorts, limit: limit, in: context)
    }

    /// The objects a request returns, an empty array when the fetch fails (logged).
    public static func fetchOrEmpty(request: NSFetchRequest<Self>, in context: DatabaseContext<Schema>) -> [Self] {
        logged(in: context, "fetch \(entityName)") { try fetch(request: request, in: context) } ?? []
    }

    /// The first object matching every query, `nil` when there is none or the fetch fails (logged).
    public static func fetchFirstOrNil(matching queries: [Query] = [], sortedBy sorts: [Sort] = [], in context: DatabaseContext<Schema>) -> Self? {
        logged(in: context, "fetch first \(entityName)") { try first(matching: queries, sortedBy: sorts, in: context) } ?? nil
    }

    /// The first object matching the query, `nil` when there is none or the fetch fails (logged).
    public static func fetchFirstOrNil(matching query: Query, sortedBy sorts: [Sort] = [], in context: DatabaseContext<Schema>) -> Self? {
        fetchFirstOrNil(matching: [query], sortedBy: sorts, in: context)
    }


    //-------------------
    // MARK: Raw predicates
    //-------------------

    /// The objects matching a raw predicate. The escape hatch of the typed queries.
    public static func fetchOrEmpty(matching predicate: NSPredicate?, sortedBy sortDescriptors: [NSSortDescriptor] = [], in context: DatabaseContext<Schema>) -> [Self] {
        let request = NSFetchRequest<Self>(entityName: entityName)
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        return fetchOrEmpty(request: request, in: context)
    }

    /// The first object matching a raw predicate. The escape hatch of the typed queries.
    public static func fetchFirstOrNil(matching predicate: NSPredicate?, sortedBy sortDescriptors: [NSSortDescriptor] = [], in context: DatabaseContext<Schema>) -> Self? {
        let request = NSFetchRequest<Self>(entityName: entityName)
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        request.fetchLimit = 1
        return fetchOrEmpty(request: request, in: context).first
    }


    //-------------------
    // MARK: Values
    //-------------------

    /// Sets the values by key and calls `didUpdate()`.
    public func update(with values: [String: Any]) {
        for (key, value) in values {
            setValue(value, forKey: key)
        }
        didUpdate()
    }

    static func logged<T>(in context: DatabaseContext<Schema>, _ description: String, _ work: () throws -> T) -> T? {
        do {
            return try work()
        }
        catch {
            context.database?.configuration.logger?.error("Failed to \(description)", error)
            return nil
        }
    }
}
