import CoreData
import AmphoraKit

/// The schema of the bundled test model: a programmatic `NSManagedObjectModel` with two entities,
/// so that packages and apps can exercise AmphoraKit without an `.xcdatamodeld`.
///
/// `TestItem` keeps plain attribute names and the default `id` key; `TestFolder` uses the
/// `a_` / `r_` storage prefixes and `a_id`, the way a prefixed model would.
///
public enum TestSchema: DatabaseSchema {

    nonisolated(unsafe) public static let model: NSManagedObjectModel = makeModel()

    private static func makeModel() -> NSManagedObjectModel {
        let item = NSEntityDescription()
        item.name = "TestItem"
        item.managedObjectClassName = NSStringFromClass(TestItem.self)

        let folder = NSEntityDescription()
        folder.name = "TestFolder"
        folder.managedObjectClassName = NSStringFromClass(TestFolder.self)

        let itemFolder = NSRelationshipDescription()
        itemFolder.name = "folder"
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
            attribute("id", .stringAttributeType),
            attribute("name", .stringAttributeType),
            attribute("order", .integer32AttributeType, defaultValue: 0),
            attribute("score", .doubleAttributeType, defaultValue: 0),
            attribute("isDone", .booleanAttributeType, defaultValue: false),
            attribute("createdAt", .dateAttributeType),
            attribute("note", .stringAttributeType, optional: true),
            attribute("kindRaw", .stringAttributeType, defaultValue: TestItem.Kind.plain.rawValue),
            attribute("positionRaw", .stringAttributeType, optional: true),
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


//-------------------
// MARK: TestItem
//-------------------

/// A test entity with plain attribute names and the default `id` key.
///
/// Its nested `Query`, `Field` and `Sort` are written by hand, exactly as `@Entity` generates them.
@objc(AmphoraKitTestItem)
public final class TestItem: NSManagedObject, IdentifiableDatabaseObject {

    public typealias Schema = TestSchema

    public static var idKey: String { "id" }

    @NSManaged public var id: String
    @NSManaged public var name: String
    @NSManaged public var order: Int32
    @NSManaged public var score: Double
    @NSManaged public var isDone: Bool
    @NSManaged public var createdAt: Date
    @NSManaged public var note: String?
    @NSManaged public var kindRaw: String
    @NSManaged public var positionRaw: String?
    @NSManaged public var folder: TestFolder?

    /// How many times `didUpdate()` ran, for the tests of `update(with:)`.
    public private(set) var didUpdateCount = 0

    public func didUpdate() {
        didUpdateCount += 1
    }

    /// A stored enum.
    public enum Kind: String, CaseIterable, Sendable {
        case plain, urgent, archived
    }

    /// The kind, decoded from `kindRaw`.
    public var kind: Kind {
        get { Kind.fromStorage(kindRaw) ?? .plain }
        set { kindRaw = newValue.rawValue }
    }

    /// A position encoded as text, decoded from `positionRaw`.
    public var position: Position? {
        get { positionRaw.flatMap(Position.fromStorage) }
        set { positionRaw = newValue?.storage }
    }

    public struct Query: EntityQuery {
        public let expression: QueryExpression<TestItem>
        public init(_ expression: QueryExpression<TestItem>) { self.expression = expression }

        public static func && (lhs: Query, rhs: Query) -> Query { .init(.and(lhs.expression, rhs.expression)) }
        public static func || (lhs: Query, rhs: Query) -> Query { .init(.or(lhs.expression, rhs.expression)) }
        public static prefix func ! (query: Query) -> Query { .init(.not(query.expression)) }

        public static func name(_ match: Match<String>) -> Query { .init(.match("name", match)) }
        public static func name(_ value: String) -> Query { .name(.equal(value)) }
        public static func order(_ match: Match<Int32>) -> Query { .init(.match("order", match)) }
        public static func order(_ value: Int32) -> Query { .order(.equal(value)) }
        public static func score(_ match: Match<Double>) -> Query { .init(.match("score", match)) }
        public static func score(_ value: Double) -> Query { .score(.equal(value)) }
        public static func isDone(_ match: Match<Bool>) -> Query { .init(.match("isDone", match)) }
        public static func isDone(_ value: Bool) -> Query { .isDone(.equal(value)) }
        public static func createdAt(_ match: Match<Date>) -> Query { .init(.match("createdAt", match)) }
        public static func createdAt(_ value: Date) -> Query { .createdAt(.equal(value)) }
        public static func note(_ match: Match<String?>) -> Query { .init(.match("note", match)) }
        public static func note(_ value: String?) -> Query { .note(.equal(value)) }
        public static func kind(_ match: Match<Kind>) -> Query { .init(.match("kindRaw", match)) }
        public static func kind(_ value: Kind) -> Query { .kind(.equal(value)) }
        public static func position(_ match: Match<Position?>) -> Query { .init(.match("positionRaw", match)) }
        public static func position(_ value: Position?) -> Query { .position(.equal(value)) }
        public static func folder(_ match: Match<TestFolder?>) -> Query { .init(.match("folder", match)) }
        public static func folder(_ query: TestFolder.Query) -> Query { .init(.relation("folder", query.expression)) }
    }

    public struct Field<Value>: EntityField {
        public typealias Root = TestItem
        public let key: String
        public init(key: String) { self.key = key }

        public static var name: Field<String> { .init(key: "name") }
        public static var order: Field<Int32> { .init(key: "order") }
        public static var score: Field<Double> { .init(key: "score") }
        public static var isDone: Field<Bool> { .init(key: "isDone") }
        public static var createdAt: Field<Date> { .init(key: "createdAt") }
        public static var note: Field<String?> { .init(key: "note") }
        public static var kind: Field<Kind> { .init(key: "kindRaw") }

        public static func == (lhs: Field, rhs: Value) -> Query where Value: Equatable { .init(lhs.matching(.equal(rhs))) }
        public static func != (lhs: Field, rhs: Value) -> Query where Value: Equatable { .init(lhs.matching(.notEqual(rhs))) }
        public static func < (lhs: Field, rhs: Value) -> Query where Value: Comparable { .init(lhs.matching(.lessThan(rhs))) }
        public static func <= (lhs: Field, rhs: Value) -> Query where Value: Comparable { .init(lhs.matching(.lessOrEqual(rhs))) }
        public static func > (lhs: Field, rhs: Value) -> Query where Value: Comparable { .init(lhs.matching(.greaterThan(rhs))) }
        public static func >= (lhs: Field, rhs: Value) -> Query where Value: Comparable { .init(lhs.matching(.greaterOrEqual(rhs))) }
        public static func ~= (lhs: Field, rhs: [Value]) -> Query where Value: Equatable { .init(lhs.matching(.in(rhs))) }
    }

    public struct Sort: EntitySort {
        public let expression: SortExpression<TestItem>
        public init(_ expression: SortExpression<TestItem>) { self.expression = expression }

        public static var name: Sort { .init(key: "name") }
        public static var order: Sort { .init(key: "order") }
        public static var score: Sort { .init(key: "score") }
        public static var createdAt: Sort { .init(key: "createdAt") }
    }
}

extension TestItem {

    /// A bar-beat position stored as `"bar-beat"`, the shape of a `StorageConvertible` composite.
    public struct Position: StorageConvertible, Hashable, Sendable {
        public var bar: Int
        public var beat: Int

        public init(bar: Int, beat: Int) {
            self.bar = bar
            self.beat = beat
        }

        public var storage: String { "\(bar)-\(beat)" }

        public init?(storage: String) {
            let parts = storage.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2 else { return nil }
            self.init(bar: parts[0], beat: parts[1])
        }
    }
}


//-------------------
// MARK: TestFolder
//-------------------

/// A test entity with `a_` / `r_` storage prefixes and `a_id` as identifier.
@objc(AmphoraKitTestFolder)
public final class TestFolder: NSManagedObject, IdentifiableDatabaseObject {

    public typealias Schema = TestSchema

    public static var idKey: String { "a_id" }

    @NSManaged public var a_id: String
    @NSManaged public var a_name: String
    @NSManaged public var r_items: Set<TestItem>

    public var id: String { a_id }

    /// The folder name.
    public var name: String {
        get { a_name }
        set { a_name = newValue }
    }

    public struct Query: EntityQuery {
        public let expression: QueryExpression<TestFolder>
        public init(_ expression: QueryExpression<TestFolder>) { self.expression = expression }

        public static func && (lhs: Query, rhs: Query) -> Query { .init(.and(lhs.expression, rhs.expression)) }
        public static func || (lhs: Query, rhs: Query) -> Query { .init(.or(lhs.expression, rhs.expression)) }
        public static prefix func ! (query: Query) -> Query { .init(.not(query.expression)) }

        public static func name(_ match: Match<String>) -> Query { .init(.match("a_name", match)) }
        public static func name(_ value: String) -> Query { .name(.equal(value)) }
        public static func items(_ match: CollectionMatch<TestItem>) -> Query { .init(.collection("r_items", match)) }
    }

    public struct Field<Value>: EntityField {
        public typealias Root = TestFolder
        public let key: String
        public init(key: String) { self.key = key }

        public static var name: Field<String> { .init(key: "a_name") }

        public static func == (lhs: Field, rhs: Value) -> Query where Value: Equatable { .init(lhs.matching(.equal(rhs))) }
        public static func != (lhs: Field, rhs: Value) -> Query where Value: Equatable { .init(lhs.matching(.notEqual(rhs))) }
        public static func < (lhs: Field, rhs: Value) -> Query where Value: Comparable { .init(lhs.matching(.lessThan(rhs))) }
        public static func > (lhs: Field, rhs: Value) -> Query where Value: Comparable { .init(lhs.matching(.greaterThan(rhs))) }
        public static func ~= (lhs: Field, rhs: [Value]) -> Query where Value: Equatable { .init(lhs.matching(.in(rhs))) }
    }

    public struct Sort: EntitySort {
        public let expression: SortExpression<TestFolder>
        public init(_ expression: SortExpression<TestFolder>) { self.expression = expression }

        public static var name: Sort { .init(key: "a_name") }
    }
}
