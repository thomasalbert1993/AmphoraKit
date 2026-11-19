import CoreData

/// A `DatabaseObject` carrying a business identifier, stored under `idKey`.
///
/// Everything that assumes an identifier lives on this protocol: `fetch(id:)`, `fetchOrCreate(id:)`,
/// `delete(ids:)`, and the shared query members `.id(_:)` and `.ids(_:)`.
///
/// ```swift
/// protocol LibraryObject: IdentifiableDatabaseObject where ID == String, Schema == LibrarySchema {
///     var a_id: String { get set }
/// }
/// extension LibraryObject {
///     static var idKey: String { "a_id" }
///     var id: String { a_id }
/// }
/// ```
///
public protocol IdentifiableDatabaseObject: DatabaseObject, Identifiable where ID: Hashable {

    /// The Core Data attribute storing the identifier.
    static var idKey: String { get }

    /// The identifier.
    var id: ID { get }
}

extension IdentifiableDatabaseObject {

    public static func object(withID id: ID, in context: NSManagedObjectContext) -> Self? {
        try? fetch(id: id, in: DatabaseContext(context))
    }

    public static func objects(withIDs ids: [ID], in context: NSManagedObjectContext) -> [Self] {
        guard !ids.isEmpty else { return [] }
        return (try? fetch(ids: ids, in: DatabaseContext(context))) ?? []
    }
}
