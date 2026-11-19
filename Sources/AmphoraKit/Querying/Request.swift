import CoreData

/// A typed fetch: which objects (`query`), in what order (`sorts`), how many (`limit`). The typed
/// counterpart of an `NSFetchRequest`, built from an entity's generated `Query` and `Sort`.
///
/// ```swift
/// extension Note {
///     static func request(projectId: String) -> Request<Note> {
///         Request(matching: .projectId(projectId), sortedBy: [.createdAt])
///     }
/// }
///
/// let notes = try Note.fetch(request: Note.request(projectId: id), in: context)
/// let controller = FetchController(Note.request(projectId: id), in: database)
/// ```
///
/// A value: build variants with `sorted(by:)`, `limited(to:)` and `filtered(by:)`.
///
public struct Request<Root: DatabaseObject> {

    /// The condition the objects match, `nil` for all of them.
    public var query: Root.Query?

    /// The sort, first descriptor first.
    public var sorts: [Root.Sort]

    /// The maximum number of objects, `nil` for no limit.
    public var limit: Int?

    /// A request on the objects matching the query.
    public init(matching query: Root.Query? = nil, sortedBy sorts: [Root.Sort] = [], limit: Int? = nil) {
        self.query = query
        self.sorts = sorts
        self.limit = limit
    }

    /// A request on the objects matching every query.
    public init(matching queries: [Root.Query], sortedBy sorts: [Root.Sort] = [], limit: Int? = nil) {
        self.init(matching: Root.Query.all(of: queries), sortedBy: sorts, limit: limit)
    }

    /// The same request, sorted otherwise.
    public func sorted(by sorts: [Root.Sort]) -> Self {
        var copy = self
        copy.sorts = sorts
        return copy
    }

    /// The same request, limited.
    public func limited(to limit: Int?) -> Self {
        var copy = self
        copy.limit = limit
        return copy
    }

    /// The same request, narrowed by another condition.
    public func filtered(by query: Root.Query) -> Self {
        var copy = self
        copy.query = self.query.map { .init(.and($0.expression, query.expression)) } ?? query
        return copy
    }

    /// The Core Data request, a new one at each call.
    public var nsFetchRequest: NSFetchRequest<Root> {
        let request = NSFetchRequest<Root>(entityName: Root.entityName)
        request.predicate = query?.nsPredicate
        request.sortDescriptors = sorts.map(\.nsSortDescriptor)
        if let limit {
            request.fetchLimit = limit
        }
        return request
    }
}

extension DatabaseObject {

    /// The objects a typed request returns.
    public static func fetch(request: Request<Self>, in context: DatabaseContext<Schema>) throws -> [Self] {
        try fetch(request: request.nsFetchRequest, in: context)
    }

    /// The first object a typed request returns, in its order.
    public static func first(request: Request<Self>, in context: DatabaseContext<Schema>) throws -> Self? {
        try fetch(request: request.limited(to: 1), in: context).first
    }

    /// How many objects a typed request returns, its limit aside.
    public static func count(request: Request<Self>, in context: DatabaseContext<Schema>) throws -> Int {
        try context.count(for: request.limited(to: nil).nsFetchRequest)
    }

    /// The objects a typed request returns, an empty array when the fetch fails (logged).
    public static func fetchOrEmpty(request: Request<Self>, in context: DatabaseContext<Schema>) -> [Self] {
        fetchOrEmpty(request: request.nsFetchRequest, in: context)
    }

    /// The first object a typed request returns, `nil` when there is none or the fetch fails (logged).
    public static func fetchFirstOrNil(request: Request<Self>, in context: DatabaseContext<Schema>) -> Self? {
        fetchOrEmpty(request: request.limited(to: 1), in: context).first
    }
}
