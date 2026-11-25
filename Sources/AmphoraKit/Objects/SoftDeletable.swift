import CoreData

/// An entity whose objects are marked deleted rather than removed, by a Boolean flag or by the
/// date of the deletion (`SoftDeletion`).
///
/// Every fetch built from a typed query leaves them out — `fetch`, `fetchFirst`, `count`,
/// `exists`, `Request`, `FetchController`, the batch `deleteAll(matching:)` and
/// `update(matching:)` — unless the query asks for them:
///
/// ```swift
/// extension Entry: SoftDeletable {
///     static var softDeletion: SoftDeletion { .flag("a_deleted") }     // or .date("a_deletedAt")
/// }
///
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

    /// The attribute marking an object deleted.
    static var softDeletion: SoftDeletion { get }
}

/// How a `SoftDeletable` entity marks its objects deleted.
public enum SoftDeletion: Sendable, Hashable {

    /// A Boolean attribute, `true` once deleted; a missing flag counts as live.
    case flag(String)

    /// A date attribute, the date of the deletion; `nil` while live.
    case date(String)

    /// The storage key of the attribute.
    public var key: String {
        switch self {
            case .flag(let key), .date(let key):
                return key
        }
    }

    /// The condition matching the objects not marked deleted. Spelled out for a flag: SQLite
    /// reads `flag != YES` as unknown for a missing flag, and would leave those objects out.
    func liveFragment(forKey key: String) -> PredicateFragment {
        switch self {
            case .flag:
                return PredicateFragment("(%K == nil OR %K == NO)", [key, key])
            case .date:
                return PredicateFragment("%K == nil", [key])
        }
    }

    /// The condition matching the objects marked deleted.
    func deletedFragment(forKey key: String) -> PredicateFragment {
        switch self {
            case .flag:
                return PredicateFragment("%K == YES", [key])
            case .date:
                return PredicateFragment("%K != nil", [key])
        }
    }
}

extension SoftDeletable {

    /// Whether the object is marked deleted.
    public var isSoftDeleted: Bool {
        let value = self.value(forKey: Self.softDeletion.key)
        switch Self.softDeletion {
            case .flag:
                return (value as? Bool) ?? false
            case .date:
                return value is Date
        }
    }

    /// When the object was marked deleted: the deletion date of a `.date` entity, `nil` for a
    /// live object or a `.flag` entity, which doesn't record it.
    public var softDeletionDate: Date? {
        guard case .date(let key) = Self.softDeletion else { return nil }
        return value(forKey: key) as? Date
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
        let softDeletion = Root.softDeletion
        let render: (String) -> PredicateFragment
        if isDeleted {
            render = { key in softDeletion.deletedFragment(forKey: key) }
        }
        else {
            render = { key in softDeletion.liveFragment(forKey: key) }
        }
        let node = QueryExpression<Root>.Node.leaf(key: softDeletion.key, render: render)
        return Self(QueryExpression<Root>(node, includesSoftDeleted: true))
    }
}

extension EntityQuery where Root: SoftDeletable {

    /// The objects marked deleted in a date range — before a purge, say. Matches nothing on a
    /// `.flag` entity, which doesn't record when.
    public static func deleted(_ match: Match<Date>) -> Self {
        guard case .date(let key) = Root.softDeletion else {
            return Self(QueryExpression<Root>(.raw(PredicateFragment("FALSEPREDICATE")), includesSoftDeleted: true))
        }
        return Self(QueryExpression<Root>.match(key, match).includingSoftDeleted())
    }
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
        let softDeletion = softDeletable.softDeletion
        let live = softDeletion.liveFragment(forKey: softDeletion.key).nsPredicate
        guard let predicate = query?.nsPredicate else {
            return live
        }
        return NSCompoundPredicate(andPredicateWithSubpredicates: [predicate, live])
    }
}
