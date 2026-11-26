import CoreData
import AmphoraKit
import AmphoraKitTestSupport

/// A schema with an entity hierarchy declared with `@Entity`: an abstract root, a two-level
/// branch and a sibling.
///
/// ```
/// HierarchyAsset (abstract)          a_id, a_name
/// ├── HierarchyDynamicAsset          a_provider
/// │   └── HierarchyLens (final)      a_mount, r_brand → HierarchyBrand
/// └── HierarchyBrand (final)         a_label
/// ```
enum HierarchySchema: DatabaseSchema {

    nonisolated(unsafe) static let model: NSManagedObjectModel = makeModel()

    private static func makeModel() -> NSManagedObjectModel {
        let asset = entity("HierarchyAsset", HierarchyAsset.self, abstract: true, [
            attribute("a_id", .stringAttributeType),
            attribute("a_name", .stringAttributeType, defaultValue: ""),
            // optional and without default: a nil flag must read as not deleted
            attribute("a_deleted", .booleanAttributeType)
        ])
        let dynamicAsset = entity("HierarchyDynamicAsset", HierarchyDynamicAsset.self, [
            attribute("a_provider", .stringAttributeType, defaultValue: "")
        ])
        let lens = entity("HierarchyLens", HierarchyLens.self, [
            attribute("a_mount", .stringAttributeType, defaultValue: "")
        ])
        let brand = entity("HierarchyBrand", HierarchyBrand.self, [
            attribute("a_label", .stringAttributeType, defaultValue: "")
        ])

        let lensBrand = NSRelationshipDescription()
        lensBrand.name = "r_brand"
        lensBrand.destinationEntity = brand
        lensBrand.maxCount = 1
        lensBrand.isOptional = true
        lensBrand.deleteRule = .nullifyDeleteRule
        let brandLenses = NSRelationshipDescription()
        brandLenses.name = "r_lenses"
        brandLenses.destinationEntity = lens
        brandLenses.maxCount = 0
        brandLenses.isOptional = true
        brandLenses.deleteRule = .nullifyDeleteRule
        lensBrand.inverseRelationship = brandLenses
        brandLenses.inverseRelationship = lensBrand
        lens.properties.append(lensBrand)
        brand.properties.append(brandLenses)

        asset.subentities = [dynamicAsset, brand]
        dynamicAsset.subentities = [lens]

        let memo = entity("HierarchyMemo", HierarchyMemo.self, [
            attribute("a_id", .stringAttributeType),
            attribute("a_text", .stringAttributeType, defaultValue: ""),
            attribute("a_deletedAt", .dateAttributeType)
        ])

        let model = NSManagedObjectModel()
        model.entities = [asset, dynamicAsset, lens, brand, memo]
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
}

/// The abstract root: a non-final entity, its generated types are classes. Soft-deletable, which
/// its sub-entities inherit.
@objc(AmphoraKitHierarchyAsset)
@Entity(attributePrefix: "a_", relationshipPrefix: "r_")
class HierarchyAsset: NSManagedObject, IdentifiableDatabaseObject, SoftDeletable {

    typealias Schema = HierarchySchema

    static var idKey: String { "a_id" }

    static var softDeletion: SoftDeletion { .flag("a_deleted") }

    @NSManaged var a_id: String
    @NSManaged var a_name: String
    @NSManaged var a_deleted: NSNumber?
}

/// A sub-entity that has sub-entities of its own.
@objc(AmphoraKitHierarchyDynamicAsset)
@Entity(attributePrefix: "a_", relationshipPrefix: "r_", parent: HierarchyAsset.self)
class HierarchyDynamicAsset: HierarchyAsset {

    @NSManaged var a_provider: String
}

/// A leaf, two levels down, related to an entity of the sibling branch.
@objc(AmphoraKitHierarchyLens)
@Entity(attributePrefix: "a_", relationshipPrefix: "r_", parent: HierarchyDynamicAsset.self)
final class HierarchyLens: HierarchyDynamicAsset {

    @NSManaged var a_mount: String
    @NSManaged var r_brand: HierarchyBrand?
}

/// A sibling leaf, one level down.
@objc(AmphoraKitHierarchyBrand)
@Entity(attributePrefix: "a_", relationshipPrefix: "r_", parent: HierarchyAsset.self)
final class HierarchyBrand: HierarchyAsset {

    @NSManaged var a_label: String
    @NSManaged var r_lenses: Set<HierarchyLens>
}

/// An entity outside the hierarchy, soft-deleted by date.
@objc(AmphoraKitHierarchyMemo)
@Entity(attributePrefix: "a_")
final class HierarchyMemo: NSManagedObject, IdentifiableDatabaseObject, SoftDeletable {

    typealias Schema = HierarchySchema

    static var idKey: String { "a_id" }

    static var softDeletion: SoftDeletion { .date("a_deletedAt") }

    @NSManaged var a_id: String
    @NSManaged var a_text: String
    @NSManaged var a_deletedAt: Date?
}
