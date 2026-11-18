import Foundation

/// A predicate over an entity, kept structured so that its keys can be re-rooted when a query
/// is traversed through a relationship.
///
/// Entities don't expose this type directly: their nested `Query` wraps one and offers the typed
/// members. Everything renders to an `NSPredicate` through `nsPredicate`.
///
public struct QueryExpression<Root> {

    indirect enum Node {
        /// A condition on the attribute at `key`, rendered by `render` once the key is resolved.
        case leaf(key: String, render: (String) -> PredicateFragment)
        case and([Node])
        case or([Node])
        case not(Node)
        case all
        /// A hand-written predicate. It cannot be re-rooted: traversing it through a relationship traps.
        case raw(PredicateFragment)
    }

    let node: Node

    init(_ node: Node) {
        self.node = node
    }


    //-------------------
    // MARK: Building
    //-------------------

    /// A condition on an attribute.
    public static func match<Value>(_ key: String, _ match: Match<Value>) -> Self {
        .init(.leaf(key: key, render: match.fragment(forKey:)))
    }

    /// A condition on a to-many relationship.
    public static func collection<Element>(_ key: String, _ match: CollectionMatch<Element>) -> Self {
        .init(.leaf(key: key, render: match.fragment(forKey:)))
    }

    /// A condition on a to-one relationship, expressed as a query of the related entity whose
    /// keys are re-rooted under `key`: `.folder(.name("x"))` renders `folder.name == "x"`.
    public static func relation<Target>(_ key: String, _ query: QueryExpression<Target>) -> Self {
        .init(query.node.rerooted(under: key))
    }

    /// Matches everything.
    public static var all: Self {
        .init(.all)
    }

    public static func and(_ lhs: Self, _ rhs: Self) -> Self {
        .init(.and([lhs.node, rhs.node]))
    }

    public static func or(_ lhs: Self, _ rhs: Self) -> Self {
        .init(.or([lhs.node, rhs.node]))
    }

    public static func not(_ expression: Self) -> Self {
        .init(.not(expression.node))
    }

    /// A hand-written predicate, for what the typed members can't express. Keys are the caller's
    /// responsibility; the expression cannot be traversed through a relationship.
    public init(unsafeFormat format: String, _ arguments: [Any] = []) {
        self.init(.raw(PredicateFragment(format, arguments)))
    }

    /// Wraps an existing predicate. Same restrictions as `init(unsafeFormat:_:)`.
    public init(unsafePredicate predicate: NSPredicate) {
        self.init(.raw(PredicateFragment(predicate.predicateFormat)))
    }


    //-------------------
    // MARK: Rendering
    //-------------------

    /// The resulting predicate.
    public var nsPredicate: NSPredicate {
        fragment(prefix: "").nsPredicate
    }

    /// Whether the object matches, evaluated in memory.
    public func evaluate(with object: Root) -> Bool {
        nsPredicate.evaluate(with: object)
    }

    func fragment(prefix: String) -> PredicateFragment {
        node.fragment(prefix: prefix)
    }
}

extension QueryExpression.Node {

    func fragment(prefix: String) -> PredicateFragment {
        switch self {
            case .leaf(let key, let render):
                return render(prefix + key)
            case .and(let nodes):
                return .joined(nodes.map { $0.fragment(prefix: prefix) }, by: "AND")
            case .or(let nodes):
                return .joined(nodes.map { $0.fragment(prefix: prefix) }, by: "OR")
            case .not(let node):
                let inner = node.fragment(prefix: prefix)
                return PredicateFragment("NOT (\(inner.format))", inner.arguments)
            case .all:
                return PredicateFragment("TRUEPREDICATE")
            case .raw(let fragment):
                precondition(prefix.isEmpty, "A raw predicate cannot be traversed through a relationship (prefix \"\(prefix)\").")
                return fragment
        }
    }

    /// The same node with every key re-rooted under a relationship key.
    func rerooted<NewRoot>(under key: String) -> QueryExpression<NewRoot>.Node {
        switch self {
            case .leaf(let leafKey, let render):
                return .leaf(key: "\(key).\(leafKey)", render: render)
            case .and(let nodes):
                return .and(nodes.map { $0.rerooted(under: key) })
            case .or(let nodes):
                return .or(nodes.map { $0.rerooted(under: key) })
            case .not(let node):
                return .not(node.rerooted(under: key))
            case .all:
                return .all
            case .raw(let fragment):
                preconditionFailure("A raw predicate cannot be traversed through a relationship (\(key)): \(fragment.format)")
        }
    }
}
