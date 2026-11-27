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
        let values = Shot.AttributeAssignment.values([.length(Shot.Length(bars: 1, beats: 0)), .tags([.wide]), .kinds([.close])])
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

        #expect(Shot.AttributeAssignment.values([.meter(nil)])["a_meter"] as? Int32 == 0)
        #expect(Shot.AttributeAssignment.values([.meter(.common)])["a_meter"] as? Int32 == 1)
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
        #expect(Shot.AttributeAssignment.values([.priority(.high)])["a_priority"] as? Int == 1)
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
        #expect(Shot.AttributeAssignment.values([.memo(Shot.Memo(lines: ["c"]))])["a_memo"] as? String == "c")
    }

    @Test("A value stored as a dictionary of Any reads, writes and assigns, without equality")
    func anyStorageColumn() throws {
        let database = try makeDatabase()
        let context = database.viewContext
        let shot = Shot(context: context)
        shot.a_id = "s"
        #expect(shot.setup == nil)
        shot.setup = Shot.Setup(focal: 35)
        #expect(shot.a_framing?["focal"] as? Int == 35)
        try context.save()
        #expect(shot.setup == Shot.Setup(focal: 35))
        #expect(Shot.AttributeAssignment.values([.setup(Shot.Setup(focal: 50))])["a_framing"] as? [String: Any] != nil)
        #expect(try Shot.count(matching: .setup(.isNil), in: context) == 0)
    }

    @Test("An opaque column reads, writes, assigns and matches nil, its type needing no equality")
    func opaqueColumn() throws {
        let database = try makeDatabase()
        let context = database.viewContext
        let shot = Shot(context: context)
        shot.a_id = "s"
        #expect(shot.rig == nil)
        #expect(try Shot.count(matching: .rig(.isNil), in: context) == 1)
        shot.rig = Shot.Rig(head: "fluid")
        #expect(shot.a_rig?["head"] as? String == "fluid")
        try context.save()
        #expect(shot.rig?.head == "fluid")
        #expect(Shot.AttributeAssignment.values([.rig(Shot.Rig(head: "geared"))])["a_rig"] as? [String: Any] != nil)
        #expect(try Shot.count(matching: .rig(.isNil), in: context) == 0)
    }

    @Test("A stored-form assignment writes the value as is, one this version can't decode included")
    func storedFormAssignment() {
        #expect(Shot.AttributeAssignment.values([.kind(stored: "drone")])["a_kind"] as? String == "drone")
        #expect(Shot.AttributeAssignment.values([.order(stored: 7)])["a_sortOrder"] as? Int32 == 7)
        #expect(Shot.AttributeAssignment.values([.chain(stored: "wide,nope")])["a_chain"] as? String == "wide,nope")
        #expect(Shot.AttributeAssignment.values([.meter(stored: 0)])["a_meter"] as? Int32 == 0)
    }

    @Test("A column carries the storage key and the storage type, coded columns and relationships included")
    func columns() {
        let order: Column<Shot, Int32> = Shot.Columns.order
        let kind: Column<Shot, String> = Shot.Columns.kind
        let lens: Column<Shot, String> = Shot.Columns.lens
        let backupKind: Column<Shot, String?> = Shot.Columns.backupKind
        let chain: Column<Shot, String?> = Shot.Columns.chain
        let meter: Column<Shot, Int32> = Shot.Columns.meter
        let note: Column<Shot, String?> = Shot.Columns.note
        #expect(order.key == "a_sortOrder")
        #expect(kind.key == "a_kind")
        #expect(lens.key == "a_lens")
        #expect(backupKind.key == "a_backupKind")
        #expect(chain.key == "a_chain")
        #expect(meter.key == "a_meter")
        #expect(note.key == "a_note")
        #expect(Shot.Columns.isPinned.key == "a_pinned")

        let reel: Column<Shot, Reel?> = Shot.Columns.reel
        let shots: Column<Reel, Set<Shot>> = Reel.Columns.shots
        let shotsField: Field<Reel, Set<Shot>> = Reel.shots
        #expect(reel.key == "r_reel")
        #expect(shots.key == "r_shots")
        #expect(shotsField.key == "r_shots")
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

        let values = Shot.AttributeAssignment.values([.chain([.wide]), .chain([])])
        #expect(values["a_chain"] is NSNull, "the last assignment of a key wins")
        #expect(Shot.AttributeAssignment.values([.chain([.wide])])["a_chain"] as? String == "wide")
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
        let values = Shot.AttributeAssignment.values([.order(4), .kind(.close), .status(.done), .note(nil), .id("x")])
        #expect(values["a_sortOrder"] as? Int32 == 4)
        #expect(values["a_kind"] as? String == "close")
        #expect(values["a_status"] as? Int32 == 2)
        #expect(values["a_note"] is NSNull)
        #expect(values["a_id"] as? String == "x")
        let optionals = Shot.AttributeAssignment.values([.backupKind(.wide), .order(1)])
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

    @Test("Assignments write attributes and relationships, to-one and to-many, on one object")
    func objectAssignments() throws {
        let database = try makeDatabase()
        let context = database.viewContext
        let reel = Reel(context: context)
        reel.update(with: [.id("r1"), .title("Reel")])
        let other = Reel(context: context)
        other.update(with: [.id("r2"), .title("Other")])

        let shot = Shot(context: context)
        shot.update(with: [.id("s1"), .name("One"), .kind(.wide), .reel(reel)])
        #expect(shot.name == "One")
        #expect(shot.kind == .wide)
        #expect(shot.reel === reel)

        shot.update(with: [.reel(other)])
        #expect(shot.reel === other)
        shot.update(with: [.reel(nil)])
        #expect(shot.reel == nil)

        let second = Shot(context: context)
        second.update(with: [.id("s2"), .name("Two")])
        reel.update(with: [.shots([shot, second])])
        #expect(Set(reel.shots.map(\.id)) == ["s1", "s2"])
        reel.update(with: [.shots([second])])
        #expect(reel.shots.map(\.id) == ["s2"])
    }

    @Test("stored reads a coded or defaulted column as stored and a relationship as Core Data holds it")
    func storedValues() throws {
        let database = try makeDatabase()
        let context = database.viewContext
        let reel = Reel(context: context)
        reel.update(with: [.id("r1")])
        let shot = Shot(context: context)
        shot.update(with: [.id("s1"), .kind(stored: "drone"), .reel(reel)])

        // The domain value falls back on the default, the stored form keeps the unknown value.
        #expect(shot.kind == .wide)
        #expect(shot.stored.kind == "drone")
        #expect(shot.stored.order == 0)
        #expect(reel.stored.shots == [shot])

        // A related object deleted in the context: the accessor drops it, `stored` still reaches it.
        context.delete(reel)
        #expect(shot.reel == nil)
        #expect(shot.stored.reel === reel)
    }

    @Test("Private storage: written and read through the assignments and stored only")
    func privateStorage() throws {
        let database = try makeDatabase()
        let context = database.viewContext
        let take = Take(context: context)
        take.update(with: [.id("t1"), .mood(stored: "joyful")])
        try context.save()

        #expect(take.mood == .calm)
        #expect(take.stored.mood == "joyful")
        let fetched = try #require(try Take.fetch(matching: .id("t1"), in: context).first)
        #expect(fetched === take)
        #expect(take.value(forKey: "a_mood") as? String == "joyful")
    }

    @Test("A key path into Columns names a column with its root inferred")
    func columnKeyPaths() {
        func key<Root: DatabaseObject, Stored>(_ keyPath: KeyPath<Root.Columns.Type, Column<Root, Stored>>, of root: Root.Type) -> String {
            Root.Columns.self[keyPath: keyPath].key
        }
        #expect(key(\.order, of: Shot.self) == "a_sortOrder")
        #expect(key(\.reel, of: Shot.self) == "r_reel")
        #expect(key(\.shots, of: Reel.self) == "r_shots")
    }
}
