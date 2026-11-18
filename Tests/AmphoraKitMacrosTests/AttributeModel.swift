import CoreData
import AmphoraKit
import AmphoraKitMacros

/// A schema whose entities declare their storage with `@Attribute` and `@Relationship` only.
enum AttributeSchema: DatabaseSchema {

    nonisolated(unsafe) static let model: NSManagedObjectModel = makeModel()

    private static func makeModel() -> NSManagedObjectModel {
        let shot = NSEntityDescription()
        shot.name = "Shot"
        shot.managedObjectClassName = NSStringFromClass(Shot.self)

        let reel = NSEntityDescription()
        reel.name = "Reel"
        reel.managedObjectClassName = NSStringFromClass(Reel.self)

        let shotReel = NSRelationshipDescription()
        shotReel.name = "r_reel"
        shotReel.destinationEntity = reel
        shotReel.maxCount = 1
        shotReel.isOptional = true
        shotReel.deleteRule = .nullifyDeleteRule

        let reelShots = NSRelationshipDescription()
        reelShots.name = "r_shots"
        reelShots.destinationEntity = shot
        reelShots.maxCount = 0
        reelShots.isOptional = true
        reelShots.deleteRule = .nullifyDeleteRule

        shotReel.inverseRelationship = reelShots
        reelShots.inverseRelationship = shotReel

        shot.properties = [
            attribute("a_id", .stringAttributeType),
            attribute("a_name", .stringAttributeType, defaultValue: ""),
            attribute("a_sortOrder", .integer32AttributeType, defaultValue: 0),
            attribute("a_kind", .stringAttributeType, defaultValue: Shot.Kind.wide.rawValue),
            attribute("a_status", .integer32AttributeType, defaultValue: 0),
            attribute("a_note", .stringAttributeType, optional: true),
            attribute("a_pinned", .booleanAttributeType, defaultValue: false),
            attribute("a_lens", .stringAttributeType, defaultValue: ""),
            attribute("a_backupKind", .stringAttributeType, optional: true),
            shotReel
        ]
        reel.properties = [
            attribute("a_id", .stringAttributeType),
            attribute("a_title", .stringAttributeType, defaultValue: ""),
            reelShots
        ]

        let model = NSManagedObjectModel()
        model.entities = [shot, reel]
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

/// An entity whose every column is declared by a macro.
@objc(AmphoraKitShot)
@Entity(attributePrefix: "a_", relationshipPrefix: "r_")
final class Shot: NSManagedObject, IdentifiableDatabaseObject {

    typealias Schema = AttributeSchema

    static var idKey: String { "a_id" }

    /// A framing.
    enum Kind: String, Sendable {
        case wide, close
    }

    /// A progress state stored as an integer.
    enum Status: Int, Sendable {
        case none, ready, done
    }

    /// The identifier.
    @Attribute var id: String

    /// The shot name.
    @Attribute(access: .readWrite) var name: String

    /// The position in the reel.
    @Attribute("a_sortOrder", storeAs: Int32.self, access: .readWrite) var order: Int

    /// The framing.
    @Attribute(storeAs: String.self, default: Kind.wide, access: .readWrite) var kind: Kind

    /// The progress.
    @Attribute(storeAs: Int32.self, default: Status.none, access: .readWrite) var status: Status

    /// A lens.
    enum Lens: String, Sendable {
        case prime, zoom
    }

    /// The lens, `nil` when the column holds none: no assignment, `nil` has no stored form there.
    @Attribute(storeAs: String.self) var lens: Lens?

    /// A fallback framing over an optional column.
    @Attribute(storeAs: String?.self, default: Kind.close) var backupKind: Kind

    /// A free note.
    @Attribute(access: .readWrite) var note: String?

    /// Whether the shot is pinned.
    @Attribute("a_pinned", access: .readWrite) var isPinned: Bool

    /// The reel, `nil` when it is a zombie.
    @Relationship(access: .readWrite) var reel: Reel?
}

/// A reel of shots.
@objc(AmphoraKitReel)
@Entity(attributePrefix: "a_", relationshipPrefix: "r_")
final class Reel: NSManagedObject, IdentifiableDatabaseObject {

    typealias Schema = AttributeSchema

    static var idKey: String { "a_id" }

    /// The identifier.
    @Attribute var id: String

    /// The reel title.
    @Attribute(access: .readWrite) var title: String

    /// The shots, zombies removed.
    @Relationship var shots: [Shot]
}
