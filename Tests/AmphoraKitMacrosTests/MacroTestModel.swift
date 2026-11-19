import CoreData
import AmphoraKit
import AmphoraKitTestSupport

/// A schema whose entities are declared with the macros, to check the generated members end to end.
enum MacroSchema: DatabaseSchema {

    nonisolated(unsafe) static let model: NSManagedObjectModel = makeModel()

    private static func makeModel() -> NSManagedObjectModel {
        let item = NSEntityDescription()
        item.name = "MacroItem"
        item.managedObjectClassName = NSStringFromClass(MacroItem.self)

        let folder = NSEntityDescription()
        folder.name = "MacroFolder"
        folder.managedObjectClassName = NSStringFromClass(MacroFolder.self)

        let itemFolder = NSRelationshipDescription()
        itemFolder.name = "r_folder"
        itemFolder.destinationEntity = folder
        itemFolder.maxCount = 1
        itemFolder.isOptional = true
        itemFolder.deleteRule = .nullifyDeleteRule

        let folderItems = NSRelationshipDescription()
        folderItems.name = "r_items"
        folderItems.destinationEntity = item
        folderItems.maxCount = 0
        folderItems.isOptional = true
        folderItems.deleteRule = .nullifyDeleteRule

        itemFolder.inverseRelationship = folderItems
        folderItems.inverseRelationship = itemFolder

        item.properties = [
            attribute("a_id", .stringAttributeType),
            attribute("a_name", .stringAttributeType),
            attribute("a_score", .doubleAttributeType, defaultValue: 0),
            attribute("a_pinned", .booleanAttributeType, defaultValue: false),
            attribute("a_kind", .stringAttributeType, defaultValue: MacroItem.Kind.plain.rawValue),
            attribute("a_position", .stringAttributeType, optional: true),
            attribute("a_secret", .stringAttributeType, defaultValue: ""),
            itemFolder
        ]
        folder.properties = [
            attribute("a_id", .stringAttributeType),
            attribute("a_name", .stringAttributeType),
            folderItems
        ]

        let model = NSManagedObjectModel()
        model.entities = [item, folder]
        return model
    }

    private static func attribute(_ name: String, _ type: NSAttributeType, optional: Bool = false, defaultValue: Any? = nil) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = optional
        attribute.defaultValue = defaultValue
        return attribute
    }
}

/// An entity declared with `@Entity` and `@Stored`: `id` and `name` accessors are generated, the
/// rest is annotated.
@objc(AmphoraKitMacroItem)
@Entity(attributePrefix: "a_", relationshipPrefix: "r_")
final class MacroItem: NSManagedObject, IdentifiableDatabaseObject {

    typealias Schema = MacroSchema

    static var idKey: String { "a_id" }

    @NSManaged var a_id: String
    @NSManaged var a_name: String
    @NSManaged var a_score: Double
    @NSManaged var a_pinned: Bool
    @NSManaged var a_kind: String
    @NSManaged var a_position: String?
    @StorageOnly @NSManaged var a_secret: String
    @NSManaged var r_folder: MacroFolder?

    /// A stored enum.
    enum Kind: String, CaseIterable, Sendable {
        case plain, urgent
    }

    /// Whether the item is pinned.
    @Stored(\MacroItem.a_pinned, access: .readWrite) var isPinned: Bool

    /// The kind, decoded from `a_kind`.
    @Stored(\MacroItem.a_kind, default: Kind.plain, access: .readWrite) var kind: Kind

    /// The position, decoded from `a_position`.
    @Stored(\MacroItem.a_position, access: .readWrite) var position: TestItem.Position?

    /// The folder, `nil` when it is a zombie.
    @Stored(\MacroItem.r_folder) var folder: MacroFolder?
}

/// An entity declaring its own `id`, so the macro doesn't.
@objc(AmphoraKitMacroFolder)
@Entity(attributePrefix: "a_", relationshipPrefix: "r_")
final class MacroFolder: NSManagedObject, IdentifiableDatabaseObject {

    typealias Schema = MacroSchema

    static var idKey: String { "a_id" }

    @NSManaged var a_id: String
    @NSManaged var a_name: String
    @NSManaged var r_items: Set<MacroItem>

    var id: String { a_id }

    /// The items, zombies removed.
    @Stored(\MacroFolder.r_items) var items: [MacroItem]
}

