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
            attribute("a_length", .stringAttributeType, optional: true),
            attribute("a_chain", .stringAttributeType, optional: true),
            attribute("a_meter", .integer32AttributeType, defaultValue: 0),
            attribute("a_priority", .integer64AttributeType, defaultValue: 0),
            attribute("a_memo", .stringAttributeType, optional: true),
            transformable("a_tags"),
            transformable("a_kinds"),
            transformable("a_labels"),
            transformable("a_extras"),
            transformable("a_framings"),
            transformable("a_angles"),
            transformable("a_framing"),
            shotReel
        ]
        reel.properties = [
            attribute("a_id", .stringAttributeType),
            attribute("a_title", .stringAttributeType, defaultValue: ""),
            reelShots
        ]

        let take = NSEntityDescription()
        take.name = "Take"
        take.managedObjectClassName = NSStringFromClass(Take.self)
        take.properties = [
            attribute("a_id", .stringAttributeType),
            attribute("a_mood", .stringAttributeType, defaultValue: ""),
        ]

        let model = NSManagedObjectModel()
        model.entities = [shot, reel, take]
        return model
    }

    private static func transformable(_ name: String) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .transformableAttributeType
        attribute.valueTransformerName = NSValueTransformerName.secureUnarchiveFromDataTransformerName.rawValue
        attribute.isOptional = true
        return attribute
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
        /// Stored in an `Int32` column rather than the raw value's `Int64`.
        typealias StoredColumn = Int32
        case none, ready, done
    }

    /// The identifier.
    @Attribute var id: String

    /// The shot name.
    @Attribute(access: .readWrite) var name: String

    /// The position in the reel.
    @Attribute("a_sortOrder", storeAs: Int32.self, access: .readWrite) var order: Int

    /// The framing.
    @Attribute(default: Kind.wide, access: .readWrite) var kind: Kind

    /// The progress.
    @Attribute(default: Status.none, access: .readWrite) var status: Status

    /// A lens.
    enum Lens: String, Sendable {
        case prime, zoom
    }

    /// The lens, `nil` when the column holds none: no assignment, `nil` has no stored form there.
    @Attribute(storeAs: String.self) var lens: Lens?

    /// A fallback framing over an optional column.
    @Attribute(storeAs: String?.self, default: Kind.close) var backupKind: Kind

    /// A length shown as "4. 2" (raw value) and stored as "4-2" (storage).
    struct Length: RawRepresentable, StorageConvertible, Hashable, Sendable {
        var bars: Int
        var beats: Int
        init(bars: Int, beats: Int) { self.bars = bars; self.beats = beats }
        var rawValue: String { "\(bars). \(beats)" }
        init?(rawValue: String) {
            let parts = rawValue.components(separatedBy: ". ").compactMap(Int.init)
            guard parts.count == 2 else { return nil }
            self.init(bars: parts[0], beats: parts[1])
        }
        var storage: String { "\(bars)-\(beats)" }
        init?(storage: String) {
            let parts = storage.components(separatedBy: "-").compactMap(Int.init)
            guard parts.count == 2 else { return nil }
            self.init(bars: parts[0], beats: parts[1])
        }
    }

    /// The length, stored by its storage form rather than its raw value.
    @Attribute(access: .readWrite) var length: Length?

    /// Tags stored as raw values in a transformable array.
    @Attribute(access: .readWrite) var tags: [Kind]?

    /// Framings stored as raw values in a transformable set.
    @Attribute(access: .readWrite) var kinds: Set<Kind>?

    /// Labels in an optional column, empty for `nil`, without `storeAs` or `default:`.
    @Attribute(access: .readWrite) var labels: Set<String>

    /// Extra values in an optional column, empty for `nil`, without `storeAs` or `default:`.
    @Attribute(access: .readWrite) var extras: [String: String]

    /// Framings as raw values in an optional column, empty for `nil`, without `storeAs` or `default:`.
    @Attribute(access: .readWrite) var framings: [Kind]

    /// Angles as raw values in an optional set column, empty for `nil`, without `storeAs` or `default:`.
    @Attribute(access: .readWrite) var angles: Set<Kind>

    /// A framing move, coded as comma-joined raw values, `nil` when empty.
    @Attribute(coder: KindChainCoder.self, access: .readWrite) var chain: [Kind]

    /// A meter stored as a code, `0` for none, in a non-optional column.
    enum Meter: NilStorageConvertible, Sendable {
        case common, waltz
        static var nilStorage: Int32 { 0 }
        typealias OptionalStoredColumn = Int32
        init?(storage: Int32) {
            switch storage {
                case 1: self = .common
                case 2: self = .waltz
                default: return nil
            }
        }
        var storage: Int32 { self == .common ? 1 : 2 }
    }

    /// The meter, `nil` stored as `0`.
    @Attribute(access: .readWrite) var meter: Meter?

    /// An urgency stored as its integer raw value, in the raw value's own width.
    enum Priority: Int, Sendable {
        case low, high
    }

    /// The urgency.
    @Attribute(default: Priority.low, access: .readWrite) var priority: Priority

    /// Lines of a memo, stored joined, empty when the column holds none.
    struct Memo: EmptyStorageConvertible, Equatable, Sendable {
        typealias StoredColumn = String?
        var lines: [String]
        init() { lines = [] }
        init(lines: [String]) { self.lines = lines }
        init?(storage: String) { lines = storage.isEmpty ? [] : storage.components(separatedBy: "|") }
        var storage: String { lines.joined(separator: "|") }
    }

    /// The memo, empty for an empty column, without a `default:`.
    @Attribute(access: .readWrite) var memo: Memo

    /// A framing setup stored as a dictionary, the way a JSON value is.
    struct Setup: StorageConvertible, Equatable, Sendable {
        var focal: Int
        init(focal: Int) { self.focal = focal }
        init?(storage: [String: Any]) {
            guard let focal = storage["focal"] as? Int else { return nil }
            self.focal = focal
        }
        var storage: [String: Any] { ["focal": focal] }
    }

    /// The setup: a dictionary of `Any` underneath, so no equality, no sort and no field.
    @Attribute("a_framing", storeAs: [String: Any]?.self, access: .readWrite) var setup: Setup?

    /// A free note.
    @Attribute(access: .readWrite) var note: String?

    /// Whether the shot is pinned.
    @Attribute("a_pinned", access: .readWrite) var isPinned: Bool

    /// The reel, `nil` when it is a zombie.
    @Relationship(access: .readWrite) var reel: Reel?
}

/// Shots compare by their position in the reel: a reel declares its shots `.sorted`.
extension Shot: Comparable {

    static func < (lhs: Shot, rhs: Shot) -> Bool {
        lhs.order < rhs.order
    }
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

    /// The shots in reel order, zombies removed.
    @Relationship(.sorted) var shots: [Shot]
}

/// A take whose storage is private to its class body: everything else reads `stored`.
@objc(AmphoraKitTake)
@Entity(attributePrefix: "a_", relationshipPrefix: "r_", storageAccess: .private)
final class Take: NSManagedObject, IdentifiableDatabaseObject {

    typealias Schema = AttributeSchema

    static var idKey: String { "a_id" }

    /// How the take felt.
    enum Mood: String, Sendable {
        case calm, tense
    }

    /// The identifier.
    @Attribute var id: String

    /// The mood, calm when the column holds none or an unknown value.
    @Attribute(default: Mood.calm) var mood: Mood
}

/// Codes a chain of framings as comma-joined raw values, an empty one as `nil`.
enum KindChainCoder: StorageCoder {

    static func decode(_ stored: String?) -> [Shot.Kind] {
        stored?.components(separatedBy: ",").compactMap(Shot.Kind.init(rawValue:)) ?? []
    }

    static func encode(_ value: [Shot.Kind]) -> String? {
        value.isEmpty ? nil : value.map(\.rawValue).joined(separator: ",")
    }
}
