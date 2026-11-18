import CoreData
import Testing
import AmphoraKit
import AmphoraKitMacros
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
