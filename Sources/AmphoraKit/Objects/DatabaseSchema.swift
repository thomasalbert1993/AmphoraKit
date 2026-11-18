import CoreData

/// A marker type naming a Core Data model.
///
/// A schema ties together a `Database`, its contexts and its entities at the type level: a
/// `DatabaseContext<Schema>` can only be handed to entities whose `Schema` matches, so contexts of
/// two different models can never be mixed by accident.
///
/// ```swift
/// enum LibrarySchema: DatabaseSchema {
///     nonisolated(unsafe) static let model = NSManagedObjectModel(contentsOf: modelURL)!
/// }
/// ```
///
public protocol DatabaseSchema: Sendable {

    /// The managed object model of the schema, loaded once.
    static var model: NSManagedObjectModel { get }
}
