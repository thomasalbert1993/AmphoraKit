import Foundation

/// A condition on a to-many relationship.
///
/// ```swift
/// Folder.fetchOrEmpty(matching: .items(.any(.isDone(false))), in: context)
/// Folder.fetchOrEmpty(matching: .items(.count(.greaterThan(3))), in: context)
/// ```
///
public struct CollectionMatch<Element: DatabaseObject> {

    enum Kind {
        case any(QueryExpression<Element.RootEntity>)
        case none(QueryExpression<Element.RootEntity>)
        case count(Match<Int>)
    }

    let kind: Kind

    /// At least one related object matches the query.
    public static func any(_ query: Element.Query) -> Self {
        .init(kind: .any(query.expression))
    }

    /// No related object matches the query.
    public static func none(_ query: Element.Query) -> Self {
        .init(kind: .none(query.expression))
    }

    /// The number of related objects matches.
    public static func count(_ match: Match<Int>) -> Self {
        .init(kind: .count(match))
    }

    /// The relationship is empty.
    public static var isEmpty: Self {
        .count(.equal(0))
    }

    /// The relationship has at least one object.
    public static var isNotEmpty: Self {
        .count(.greaterThan(0))
    }

    /// The predicate fragment for the relationship stored under `key`.
    func fragment(forKey key: String) -> PredicateFragment {
        switch kind {
            case .any(let expression):
                return subquery(key, expression, suffix: "> 0")
            case .none(let expression):
                return subquery(key, expression, suffix: "== 0")
            case .count(let match):
                return match.fragment(forKey: "\(key).@count")
        }
    }

    private func subquery(_ key: String, _ expression: QueryExpression<Element.RootEntity>, suffix: String) -> PredicateFragment {
        let inner = expression.fragment(prefix: "$x.")
        return PredicateFragment("SUBQUERY(\(key), $x, \(inner.format)).@count \(suffix)", inner.arguments)
    }
}
