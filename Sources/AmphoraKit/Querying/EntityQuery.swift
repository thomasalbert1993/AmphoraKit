import Foundation

/// The typed predicate of an entity, the nested `Query` type `@Entity` generates.
///
/// Conforming types are concrete and nested in their entity: implicit members (`.name("x")`,
/// `.name == "x"`) only resolve against a concrete type, so the per-attribute members and the
/// `&&` / `||` / `!` operators are declared on the nested type itself. The members shared by a
/// family of entities (`.id(_:)` for identifiable ones) live in constrained extensions of this
/// protocol and resolve just as well.
///
public protocol EntityQuery {

    /// The entity. Left unconstrained on purpose: a same-type requirement back to `DatabaseObject.Query`
    /// would make the two protocols mutually recursive, which the compiler rejects.
    associatedtype Root

    /// The wrapped expression.
    var expression: QueryExpression<Root> { get }

    /// Wraps an expression.
    init(_ expression: QueryExpression<Root>)
}

extension EntityQuery {

    /// Matches everything.
    public static var all: Self {
        .init(.all)
    }

    /// A hand-written predicate, for what the typed members can't express.
    public init(unsafeFormat format: String, _ arguments: Any...) {
        self.init(QueryExpression(unsafeFormat: format, arguments))
    }

    /// Wraps an existing predicate.
    public init(unsafePredicate predicate: NSPredicate) {
        self.init(QueryExpression(unsafePredicate: predicate))
    }

    /// The resulting predicate.
    public var nsPredicate: NSPredicate {
        expression.nsPredicate
    }

    /// Whether the object matches, evaluated in memory.
    public func evaluate(with object: Root) -> Bool {
        expression.evaluate(with: object)
    }

    /// Combines queries with AND. `nil` for an empty list.
    public static func all(of queries: [Self]) -> Self? {
        queries.dropFirst().reduce(queries.first) { partial, next in
            partial.map { .init(.and($0.expression, next.expression)) }
        }
    }
}

extension EntityQuery where Root: IdentifiableDatabaseObject {

    /// The object with the identifier.
    public static func id(_ id: Root.ID) -> Self {
        .init(.match(Root.idKey, Match<Root.ID>.equal(id)))
    }

    /// A condition on the identifier.
    public static func id(_ match: Match<Root.ID>) -> Self {
        .init(.match(Root.idKey, match))
    }

    /// The objects with one of the identifiers.
    public static func ids(_ ids: [Root.ID]) -> Self {
        .init(.match(Root.idKey, Match<Root.ID>.in(ids)))
    }
}


//-------------------
// MARK: Field
//-------------------

/// A typed attribute of an entity, the nested `Field<Value>` type `@Entity` generates, for the
/// expression form of the queries: `.score > 2`, `.name == "x"`.
///
/// The comparison operators are declared on the nested type (see `EntityQuery`); the package
/// provides the building blocks they delegate to.
///
public protocol EntityField {

    /// The entity. Left unconstrained on purpose: a same-type requirement back to `DatabaseObject.Query`
    /// would make the two protocols mutually recursive, which the compiler rejects.
    associatedtype Root

    /// The attribute type.
    associatedtype Value

    /// The attribute key.
    var key: String { get }

    /// Creates a field for a key.
    init(key: String)
}

extension EntityField {

    /// The query matching this field against a condition. The operators of the nested type call it.
    public func matching(_ match: Match<Value>) -> QueryExpression<Root> {
        .match(key, match)
    }
}

extension EntityField where Root: IdentifiableDatabaseObject, Value == Root.ID {

    /// The identifier field.
    public static var id: Self {
        .init(key: Root.idKey)
    }
}


//-------------------
// MARK: Sort
//-------------------

/// The typed sort descriptor of an entity, the nested `Sort` type `@Entity` generates.
public protocol EntitySort {

    /// The entity. Left unconstrained on purpose: a same-type requirement back to `DatabaseObject.Query`
    /// would make the two protocols mutually recursive, which the compiler rejects.
    associatedtype Root

    /// The wrapped expression.
    var expression: SortExpression<Root> { get }

    /// Wraps an expression.
    init(_ expression: SortExpression<Root>)
}

extension EntitySort {

    /// Creates an ascending sort on a key.
    public init(key: String, ascending: Bool = true, stringComparison: SortExpression<Root>.StringComparison = .standard) {
        self.init(SortExpression(key: key, ascending: ascending, stringComparison: stringComparison))
    }

    /// The same sort, descending.
    public var descending: Self {
        .init(SortExpression(key: expression.key, ascending: false, stringComparison: expression.stringComparison))
    }

    /// The same sort, ascending.
    public var ascending: Self {
        .init(SortExpression(key: expression.key, ascending: true, stringComparison: expression.stringComparison))
    }

    /// The same sort with another string comparison.
    public func comparing(_ comparison: SortExpression<Root>.StringComparison) -> Self {
        .init(SortExpression(key: expression.key, ascending: expression.ascending, stringComparison: comparison))
    }

    /// The resulting sort descriptor.
    public var nsSortDescriptor: NSSortDescriptor {
        expression.nsSortDescriptor
    }
}

extension EntitySort where Root: IdentifiableDatabaseObject {

    /// Sorts by identifier.
    public static var id: Self {
        .init(key: Root.idKey)
    }
}
