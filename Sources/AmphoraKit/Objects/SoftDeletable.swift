import CoreData

/// An entity whose objects are marked deleted rather than removed: a Boolean attribute, at
/// `softDeletedKey`, set to `true`.
///
/// Every fetch built from a typed query leaves them out — `fetch`, `fetchFirst`, `count`,
/// `exists`, `Request`, `FetchController`, the batch `deleteAll(matching:)` and
/// `update(matching:)` — unless the query asks for them:
///
/// ```swift
/// Entry.fetch(matching: .projectId(id), in: context)                     // live entries only
/// Entry.fetch(matching: Entry.Query.projectId(id).withDeleted(), in: context) // all of them
/// Entry.fetch(matching: .deleted(true), in: context)                     // the deleted ones
/// Entry.fetch(id: entryId, in: context)                                  // deleted or not
/// ```
///
/// A query on the identifier (`idKey`) finds deleted objects too: looking an object up by its
/// identifier means that object, whatever its state. Raw `NSFetchRequest`s and `NSPredicate`s are
/// left as written. In a hierarchy, the root adopts the protocol and its sub-entities inherit it.
///
public protocol SoftDeletable: DatabaseObject {

    /// The Boolean attribute marking an object deleted.
    static var softDeletedKey: String { get }
}

extension SoftDeletable {

    /// Whether the object is marked deleted.
    public var isSoftDeleted: Bool {
        (value(forKey: Self.softDeletedKey) as? Bool) ?? false
    }

    /// The object, `nil` when it is marked deleted.
    public var nilIfSoftDeleted: Self? {
        isSoftDeleted ? nil : self
    }
}

extension Sequence where Element: SoftDeletable {

    /// The objects not marked deleted, in order.
    public func removingSoftDeleted() -> [Element] {
        filter { !$0.isSoftDeleted }
    }
}

extension EntityQuery where Root: SoftDeletable {

    /// The same query, the objects marked deleted included.
    public func withDeleted() -> Self {
        .init(expression.includingSoftDeleted())
    }

    /// The objects marked deleted (`true`) or not (`false`), a missing flag counting as not.
    public static func deleted(_ isDeleted: Bool) -> Self {
        let render: (String) -> PredicateFragment
        if isDeleted {
            render = { key in PredicateFragment("%K == YES", [key]) }
        }
        else {
            render = { key in softDeletedLiveFragment(forKey: key) }
        }
        let node = QueryExpression<Root>.Node.leaf(key: Root.softDeletedKey, render: render)
        return Self(QueryExpression<Root>(node, includesSoftDeleted: true))
    }
}

/// The objects not marked deleted. Spelled out: SQLite reads `flag != YES` as unknown for a
/// missing flag, and leaves those objects out.
func softDeletedLiveFragment(forKey key: String) -> PredicateFragment {
    PredicateFragment("(%K == nil OR %K == NO)", [key, key])
}

extension DatabaseObject {

    /// The predicate a typed query fetches with: the query's, and — for a `SoftDeletable` entity,
    /// unless the query asks for them or names an identifier — the soft-deleted objects left out.
    static func filteredPredicate(_ query: Query?) -> NSPredicate? {
        guard let softDeletable = Self.self as? any SoftDeletable.Type else {
            return query?.nsPredicate
        }
        if let expression = query?.expression {
            let namesIdentifier = (Self.self as? any IdentifiableDatabaseObject.Type).map { expression.mentions(key: $0.idKey) } ?? false
            if expression.includesSoftDeleted || namesIdentifier {
                return expression.nsPredicate
            }
        }
        let live = softDeletedLiveFragment(forKey: softDeletable.softDeletedKey).nsPredicate
        guard let predicate = query?.nsPredicate else {
            return live
        }
        return NSCompoundPredicate(andPredicateWithSubpredicates: [predicate, live])
    }
}
