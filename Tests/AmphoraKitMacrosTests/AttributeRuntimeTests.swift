import CoreData
import Testing
import AmphoraKit
import AmphoraKitTestSupport

/// Entities declared with `@Attribute` and `@Relationship` only, against a real store.
@Suite("Attribute runtime")
@MainActor
struct AttributeRuntimeTests {

    private func makeDatabase() throws -> Database<AttributeSchema> {
        let database = Database<AttributeSchema>.ephemeral(name: "Attributes")
        try database.setup()
        return database
    }

    @Test("The generated storage is real @NSManaged storage: #keyPath, KVC, save and fetch work")
    func storageIsManaged() throws {
        #expect(#keyPath(Shot.a_sortOrder) == "a_sortOrder")
        #expect(#keyPath(Reel.r_shots) == "r_shots")

        let database = try makeDatabase()
        let context = database.viewContext
        let reel = Reel(context: context)
        reel.a_id = "r1"
        reel.title = "Day 1"
        let shot = Shot(context: context)
        shot.a_id = "s1"
        shot.name = "Opening"
        shot.order = 3
        shot.kind = .close
        shot.status = .ready
        shot.reel = reel
        try context.save()

        #expect(shot.a_sortOrder == 3)
        #expect(shot.a_kind == "close")
        #expect(shot.a_status == 1)
        #expect(shot.value(forKey: "a_sortOrder") as? Int32 == 3)

        let fetched = try #require(try Shot.fetch(matching: .order(3), in: context).first)
        #expect(fetched === shot)
        #expect(fetched.reel === reel)
        #expect(reel.shots.map(\.id) == ["s1"])

        shot.a_kind = "garbage"
        #expect(shot.kind == .wide)

        // An exposed integer wider than its column saturates instead of trapping.
        shot.order = .max
        #expect(shot.a_sortOrder == .max)
    
    }

    @Test("A type both RawRepresentable and StorageConvertible goes by its storage; collections of enums go by raw values")
    func storageFormsAndCollections() throws {
        let database = try makeDatabase()
        let context = database.viewContext
        let shot = Shot(context: context)
        shot.a_id = "s"
        shot.length = Shot.Length(bars: 4, beats: 2)
        shot.tags = [.close, .wide]
        shot.kinds = [.wide]
        try context.save()

        #expect(shot.a_length == "4-2")
        #expect(shot.length == Shot.Length(bars: 4, beats: 2))
        #expect(shot.a_tags == ["close", "wide"])
        #expect(shot.tags == [.close, .wide])
        #expect(shot.a_kinds == ["wide"])
        #expect(shot.kinds == [.wide])

        #expect(Shot.Query.length(Shot.Length(bars: 4, beats: 2)).nsPredicate.predicateFormat == #"a_length == "4-2""#)
        let values = Shot.Assignment.values([.length(Shot.Length(bars: 1, beats: 0)), .tags([.wide]), .kinds([.close])])
        #expect(values["a_length"] as? String == "1-0")
        #expect(values["a_tags"] as? [String] == ["wide"])
        #expect(values["a_kinds"] as? Set<String> == ["close"])
    }

    @Test("A collection over an optional column reads empty for nil without a default")
    func optionalCollectionColumns() throws {
        let database = try makeDatabase()
        let context = database.viewContext
        let shot = Shot(context: context)
        shot.a_id = "e"
        #expect(shot.a_labels == nil && shot.a_extras == nil && shot.a_framings == nil && shot.a_angles == nil)
        #expect(shot.labels.isEmpty && shot.extras.isEmpty && shot.framings.isEmpty && shot.angles.isEmpty)
        #expect(shot.tags == nil, "an optional property still reads nil")

        shot.labels = ["a"]
        shot.extras = ["k": "v"]
        shot.framings = [.close, .wide]
        shot.angles = [.wide]
        try context.save()

        #expect(shot.a_framings == ["close", "wide"])
        #expect(shot.labels == ["a"] && shot.extras == ["k": "v"] && shot.framings == [.close, .wide] && shot.angles == [.wide])
    }

    @Test("A NilStorageConvertible stores nil as its nilStorage, and isNil matches it")
    func nilStorageColumn() throws {
        let database = try makeDatabase()
        let context = database.viewContext
        let none = Shot(context: context)
        none.a_id = "none"
        #expect(none.a_meter == 0)
        #expect(none.meter == nil)
        let waltz = Shot(context: context)
        waltz.a_id = "waltz"
        waltz.meter = .waltz
        #expect(waltz.a_meter == 2)
        waltz.meter = nil
        #expect(waltz.a_meter == 0, "nil is written as the nil storage")
        waltz.meter = .waltz
        try context.save()

        #expect(Shot.Query.meter(.isNil).nsPredicate.predicateFormat == "a_meter == 0")
        #expect(Shot.Query.meter(.isNotNil).nsPredicate.predicateFormat == "a_meter != 0")
        #expect(Shot.Query.meter(nil).nsPredicate.predicateFormat == "a_meter == 0")
        #expect(Shot.Query.meter(.waltz).nsPredicate.predicateFormat == "a_meter == 2")
        #expect(try Shot.fetch(matching: .meter(.isNil), in: context).map(\.a_id) == ["none"])
        #expect(try Shot.fetch(matching: .meter(.isNotNil), in: context).map(\.a_id) == ["waltz"])

        #expect(Shot.Assignment.values([.meter(nil)])["a_meter"] as? Int32 == 0)
        #expect(Shot.Assignment.values([.meter(.common)])["a_meter"] as? Int32 == 1)
    }

    @Test("An integer enum stored in its raw value's width reads, writes, queries and assigns")
    func integerEnumOwnWidth() throws {
        let database = try makeDatabase()
        let context = database.viewContext
        let shot = Shot(context: context)
        shot.a_id = "p"
        #expect(shot.priority == .low)
        shot.priority = .high
        #expect(shot.a_priority == 1)
        try context.save()
        #expect(Shot.Query.priority(.high).nsPredicate.predicateFormat == "a_priority == 1")
        #expect(try Shot.count(matching: .priority(.high), in: context) == 1)
        #expect(Shot.Assignment.values([.priority(.high)])["a_priority"] as? Int == 1)
    }

    @Test("A to-many relationship declared .sorted reads in the target's order; the plain read leaves them be")
    func toManySorted() throws {
        let database = try makeDatabase()
        let context = database.viewContext
        let reel = Reel(context: context)
        reel.a_id = "r"
        for (id, order) in [("c", 3), ("a", 1), ("b", 2)] {
            let shot = Shot(context: context)
            shot.a_id = id
            shot.order = order
            shot.reel = reel
        }
        try context.save()
        #expect(reel.shots.map(\.id) == ["a", "b", "c"])
        #expect(Set(StoredAccessor.read(reel.r_shots).map(\.id)) == ["a", "b", "c"])
    }

    @Test("An EmptyStorageConvertible reads empty for nil, writes and assigns its storage")
    func emptyStorageColumn() throws {
        let database = try makeDatabase()
        let context = database.viewContext
        let shot = Shot(context: context)
        shot.a_id = "m"
        #expect(shot.a_memo == nil)
        #expect(shot.memo == Shot.Memo())
        shot.memo = Shot.Memo(lines: ["a", "b"])
        #expect(shot.a_memo == "a|b")
        try context.save()
        #expect(Shot.Query.memo(Shot.Memo(lines: ["a", "b"])).nsPredicate.predicateFormat == #"a_memo == "a|b""#)
        #expect(try Shot.count(matching: .memo(Shot.Memo(lines: ["a", "b"])), in: context) == 1)
        #expect(Shot.Assignment.values([.memo(Shot.Memo(lines: ["c"]))])["a_memo"] as? String == "c")
    }

    @Test("A coded column reads, writes, queries and assigns through its coder")
    func codedColumn() throws {
        let database = try makeDatabase()
        let context = database.viewContext
        let shot = Shot(context: context)
        shot.a_id = "c"
        #expect(shot.chain == [])
        shot.chain = [.wide, .close]
        #expect(shot.a_chain == "wide,close")
        shot.chain = []
        #expect(shot.a_chain == nil, "an empty chain is stored as nil")
        shot.chain = [.close]
        try context.save()

        #expect(Shot.Query.chain([.wide, .close]).nsPredicate.predicateFormat == #"a_chain == "wide,close""#)
        #expect(Shot.Query.chain([]).nsPredicate.predicateFormat == "a_chain == nil")
        #expect(Shot.Query.chain(.isEmpty).nsPredicate.predicateFormat == "a_chain == nil")
        #expect(Shot.Query.chain(.isNotEmpty).nsPredicate.predicateFormat == "a_chain != nil")
        #expect(try Shot.count(matching: .chain(.isNotEmpty), in: context) == 1)
        #expect(Shot.Query.chain(.in([[.close], [.wide]])).nsPredicate.predicateFormat == #"a_chain IN {"close", "wide"}"#)
        #expect(try Shot.count(matching: .chain([.close]), in: context) == 1)

        let values = Shot.Assignment.values([.chain([.wide]), .chain([])])
        #expect(values["a_chain"] is NSNull, "the last assignment of a key wins")
        #expect(Shot.Assignment.values([.chain([.wide])])["a_chain"] as? String == "wide")
    }

    @Test("The queries are typed on the exposed types and keyed on the storage")
    func queries() throws {
        #expect(Shot.Query.order(.greaterThan(2)).nsPredicate.predicateFormat == "a_sortOrder > 2")
        #expect(Shot.Query.kind(.close).nsPredicate.predicateFormat == #"a_kind == "close""#)
        #expect(Shot.Query.status(.done).nsPredicate.predicateFormat == "a_status == 2")
        #expect(Shot.Query.isPinned(true).nsPredicate.predicateFormat == "a_pinned == 1")
        #expect(Shot.Query.reel(.title("Day 1")).nsPredicate.predicateFormat == #"r_reel.a_title == "Day 1""#)
        #expect(Reel.Query.shots(.any(.order(1))).nsPredicate.predicateFormat == "SUBQUERY(r_shots, $x, $x.a_sortOrder == 1).@count > 0")
        #expect((Shot.order >= 2 && Shot.note == nil).nsPredicate.predicateFormat == "a_sortOrder >= 2 AND a_note == nil")
        #expect(Shot.order.key == "a_sortOrder")
    }

    @Test("Assignments encode to the stored form for batch inserts, batch updates and update(with:)")
    func assignments() throws {
        let values = Shot.Assignment.values([.order(4), .kind(.close), .status(.done), .note(nil), .id("x")])
        #expect(values["a_sortOrder"] as? Int32 == 4)
        #expect(values["a_kind"] as? String == "close")
        #expect(values["a_status"] as? Int32 == 2)
        #expect(values["a_note"] is NSNull)
        #expect(values["a_id"] as? String == "x")
        let optionals = Shot.Assignment.values([.backupKind(.wide), .order(1)])
        #expect(optionals["a_backupKind"] as? String == "wide")

        let database = try makeDatabase()
        let context = database.viewContext
        try Shot.insert([
            [.id("a"), .name("A"), .order(1), .kind(.wide)],
            [.id("b"), .name("B"), .order(2), .kind(.close), .note("n")],
        ], in: context)
        #expect(try Shot.count(matching: .kind(.close), in: context) == 1)

        try Shot.update(matching: .order(.lessThan(2)), set: [.isPinned(true), .status(.ready)], in: context)
        let a = try Shot.fetch(id: "a", in: context)
        context.refresh(a, mergeChanges: false)
        #expect(a.isPinned)
        #expect(a.status == .ready)

        let b = try Shot.fetch(id: "b", in: context)
        b.update(with: [.note(nil), .order(9)])
        #expect(b.note == nil)
        #expect(b.order == 9)
    }
}
