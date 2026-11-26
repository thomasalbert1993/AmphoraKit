import CoreData
import AmphoraKit
import AmphoraKitTestSupport

/// A schema shaped like Crewmate's: one `cd_` prefix for attributes and relationships,
/// transformables, an app base class that is not an entity, a hierarchy and soft deletion.
enum SharedPrefixSchema: DatabaseSchema {

    nonisolated(unsafe) static let model: NSManagedObjectModel = makeModel()

    private static func makeModel() -> NSManagedObjectModel {
        let asset = entity("SharedAsset", SharedAsset.self, abstract: true, [
            attribute("cd_id", .stringAttributeType),
            attribute("cd_name", .stringAttributeType, defaultValue: ""),
            attribute("cd_deleted", .booleanAttributeType, defaultValue: false),
            attribute("cd_publishedAt", .dateAttributeType),
            transformable("cd_rawContent"),
            transformable("cd_localizedName"),
            transformable("cd_keywords")
        ])
        let gear = entity("SharedGear", SharedGear.self, [
            attribute("cd_weight", .doubleAttributeType, defaultValue: 0)
        ])
        let brand = entity("SharedBrand", SharedBrand.self, [
            attribute("cd_id", .stringAttributeType),
            attribute("cd_label", .stringAttributeType, defaultValue: "")
        ])

        let gearBrand = relationship("cd_brand", to: brand, toMany: false)
        let brandGears = relationship("cd_gears", to: gear, toMany: true)
        gearBrand.inverseRelationship = brandGears
        brandGears.inverseRelationship = gearBrand
        let accessories = relationship("cd_accessories", to: gear, toMany: true)
        let accessoryOf = relationship("cd_accessoryOf", to: gear, toMany: true)
        accessories.inverseRelationship = accessoryOf
        accessoryOf.inverseRelationship = accessories
        gear.properties += [gearBrand, accessories, accessoryOf]
        brand.properties += [brandGears]

        asset.subentities = [gear]
        let model = NSManagedObjectModel()
        model.entities = [asset, gear, brand]
        return model
    }

    private static func entity(_ name: String, _ type: NSManagedObject.Type, abstract: Bool = false, _ properties: [NSPropertyDescription]) -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = name
        entity.managedObjectClassName = NSStringFromClass(type)
        entity.isAbstract = abstract
        entity.properties = properties
        return entity
    }

    private static func attribute(_ name: String, _ type: NSAttributeType, defaultValue: Any? = nil) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = defaultValue == nil
        attribute.defaultValue = defaultValue
        return attribute
    }

    private static func transformable(_ name: String) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .transformableAttributeType
        attribute.valueTransformerName = NSValueTransformerName.secureUnarchiveFromDataTransformerName.rawValue
        attribute.isOptional = true
        return attribute
    }

    private static func relationship(_ name: String, to destination: NSEntityDescription, toMany: Bool) -> NSRelationshipDescription {
        let relationship = NSRelationshipDescription()
        relationship.name = name
        relationship.destinationEntity = destination
        relationship.maxCount = toMany ? 0 : 1
        relationship.isOptional = true
        relationship.deleteRule = .nullifyDeleteRule
        return relationship
    }
}

/// The app's base class: not an entity. Caches the identifier so that it reads from any thread.
class SharedDatabaseObject: NSManagedObject {

    private var cachedID: String?

    var id: String {
        if let cachedID {
            return cachedID
        }
        let id = managedObjectContext?.performAndWait { value(forKey: "cd_id") as? String } ?? ""
        cachedID = id
        return id
    }
}

/// The root, under the base class: no `parent:`.
@objc(AmphoraKitSharedAsset)
@Entity(attributePrefix: "cd_", relationshipPrefix: "cd_")
class SharedAsset: SharedDatabaseObject, IdentifiableDatabaseObject, SoftDeletable {

    typealias Schema = SharedPrefixSchema

    static var idKey: String { "cd_id" }

    static var softDeletion: SoftDeletion { .flag("cd_deleted") }

    @StorageOnly @NSManaged var cd_id: String
    @NSManaged var cd_name: String
    @NSManaged var cd_deleted: Bool
    @NSManaged var cd_publishedAt: Date?
    @NSManaged var cd_rawContent: [String: Any]?
    @NSManaged var cd_localizedName: [String: String]?
    @NSManaged var cd_keywords: Set<String>?
}

/// A sub-entity with a to-one, and to-many relationships to its own entity.
@objc(AmphoraKitSharedGear)
@Entity(attributePrefix: "cd_", relationshipPrefix: "cd_", parent: SharedAsset.self)
final class SharedGear: SharedAsset {

    @NSManaged var cd_weight: Double
    @NSManaged var cd_brand: SharedBrand?
    @NSManaged var cd_accessories: Set<SharedGear>
    @NSManaged var cd_accessoryOf: Set<SharedGear>
}

/// A plain root under the base class.
@objc(AmphoraKitSharedBrand)
@Entity(attributePrefix: "cd_", relationshipPrefix: "cd_")
final class SharedBrand: SharedDatabaseObject, IdentifiableDatabaseObject {

    typealias Schema = SharedPrefixSchema

    static var idKey: String { "cd_id" }

    @StorageOnly @NSManaged var cd_id: String
    @NSManaged var cd_label: String
    @NSManaged var cd_gears: Set<SharedGear>
}
