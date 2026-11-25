import Foundation

/// The typed predicate of an entity, the nested `Query` type `@Entity` generates.
///
/// Conforming types are concrete and nested in their entity: implicit members (`.name("x")`)
/// only resolve against a concrete type, so the per-attribute members are declared on the nested
/// type itself. The members shared by a family of entities (`.id(_:)` for identifiable ones) live
/// in constrained extensions of this protocol and resolve just as well. The boolean operators
/// are generic functions of the package: the compiler binds them from the expected query type,
/// and operators declared in macro-generated types are not reliably found from other files.
///
public protocol DatabaseQuery {

    /// The entity. Left unconstrained on purpose: a same-type requirement back to `DatabaseObject.Query`
    /// would make the two protocols mutually recursive, which the compiler rejects.
    associatedtype Root

    /// The wrapped expression.
    var expression: QueryExpression<Root> { get }

    /// Wraps an expression.
    init(_ expression: QueryExpression<Root>)
}

extension DatabaseQuery {

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

    /// Combines queries with OR. `nil` for an empty list.
    public static func any(of queries: [Self]) -> Self? {
        queries.dropFirst().reduce(queries.first) { partial, next in
            partial.map { .init(.or($0.expression, next.expression)) }
        }
    }
}

extension DatabaseQuery where Root: IdentifiableDatabaseObject {

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

/// Both queries match.
public func && <Query: DatabaseQuery>(lhs: Query, rhs: Query) -> Query {
    .init(.and(lhs.expression, rhs.expression))
}

/// Either query matches.
public func || <Query: DatabaseQuery>(lhs: Query, rhs: Query) -> Query {
    .init(.or(lhs.expression, rhs.expression))
}

/// The query doesn't match.
public prefix func ! <Query: DatabaseQuery>(query: Query) -> Query {
    .init(.not(query.expression))
}


//-------------------
// MARK: Field
//-------------------

/// A typed attribute of an entity, for the expression form of the queries: `Note.score > 2`,
/// `Note.name == "x" && Note.isPinned == true`.
///
/// `@Entity` declares one static per attribute on the entity itself (`static var score:
/// Field<Note, Double>`), so the entity name qualifies the field; the comparison operators live
/// here and return the entity's `Query`.
///
public struct Field<Root: DatabaseObject, Value>: Sendable, Hashable {

    /// The storage key of the attribute.
    public let key: String

    /// Creates a field for a key.
    public init(key: String) {
        self.key = key
    }

    /// The query matching this field against a condition. The operators call it.
    public func matching(_ match: Match<Value>) -> Root.Query {
        .init(.match(key, match))
    }

    /// Equal to the value.
    public static func == (lhs: Field, rhs: Value) -> Root.Query where Value: Equatable {
        lhs.matching(.equal(rhs))
    }

    /// Different from the value.
    public static func != (lhs: Field, rhs: Value) -> Root.Query where Value: Equatable {
        lhs.matching(.notEqual(rhs))
    }

    /// Less than the value.
    public static func < (lhs: Field, rhs: Value) -> Root.Query where Value: Comparable {
        lhs.matching(.lessThan(rhs))
    }

    /// Less than or equal to the value.
    public static func <= (lhs: Field, rhs: Value) -> Root.Query where Value: Comparable {
        lhs.matching(.lessOrEqual(rhs))
    }

    /// Greater than the value.
    public static func > (lhs: Field, rhs: Value) -> Root.Query where Value: Comparable {
        lhs.matching(.greaterThan(rhs))
    }

    /// Greater than or equal to the value.
    public static func >= (lhs: Field, rhs: Value) -> Root.Query where Value: Comparable {
        lhs.matching(.greaterOrEqual(rhs))
    }

    /// One of the values.
    public static func ~= (lhs: Field, rhs: [Value]) -> Root.Query where Value: Equatable {
        lhs.matching(.in(rhs))
    }
}

extension IdentifiableDatabaseObject {

    /// The identifier field, for the expression form of the queries: `Note.id == "x"`.
    public static var id: Field<Self, ID> {
        .init(key: idKey)
    }
}


//-------------------
// MARK: Sort
//-------------------

/// The typed sort descriptor of an entity, the nested `Sort` type `@Entity` generates.
public protocol DatabaseSort {

    /// The entity. Left unconstrained on purpose: a same-type requirement back to `DatabaseObject.Query`
    /// would make the two protocols mutually recursive, which the compiler rejects.
    associatedtype Root

    /// The wrapped expression.
    var expression: SortExpression<Root> { get }

    /// Wraps an expression.
    init(_ expression: SortExpression<Root>)
}

extension DatabaseSort {

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

extension DatabaseSort where Root: IdentifiableDatabaseObject {

    /// Sorts by identifier.
    public static var id: Self {
        .init(key: Root.idKey)
    }
}


//-------------------
// MARK: Former names
//-------------------

/// The former name of `DatabaseQuery`. It clashed with App Intents' `EntityQuery`: the compiler's
/// constant extraction took the queries of class entities for intent queries, and crashed.
@available(*, deprecated, renamed: "DatabaseQuery")
public typealias EntityQuery = DatabaseQuery

/// The former name of `DatabaseSort`, renamed along with `DatabaseQuery`.
@available(*, deprecated, renamed: "DatabaseSort")
public typealias EntitySort = DatabaseSort
