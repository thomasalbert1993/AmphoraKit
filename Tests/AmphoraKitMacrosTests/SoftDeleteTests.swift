import CoreData
import Testing
import AmphoraKit
import AmphoraKitTestSupport

/// Soft deletion, on the hierarchy's root and inherited by its sub-entities.
@Suite("Soft delete")
@MainActor
struct SoftDeleteTests {

    /// Three lenses, `lens-b` marked deleted, `lens-c` with no flag at all; a brand marked deleted.
    private func makeDatabase() throws -> Database<HierarchySchema> {
        let database = Database<HierarchySchema>.ephemeral(name: "SoftDelete")
        try database.setup()
        let context = database.viewContext.nsContext
        for (id, deleted) in [("lens-a", false as Bool?), ("lens-b", true), ("lens-c", nil)] {
            let lens = HierarchyLens(context: context)
            lens.a_id = id
            lens.a_name = id
            lens.a_mount = "PL"
            lens.a_deleted = deleted.map { NSNumber(value: $0) }
        }
        let brand = HierarchyBrand(context: context)
        brand.a_id = "brand-x"
        brand.a_deleted = true
        try context.save()
        return database
    }

    @Test("typed fetches leave the deleted objects out, a missing flag counting as live")
    func filtered() throws {
        let database = try makeDatabase()
        let context = database.viewContext
        #expect(try HierarchyLens.fetch(sortedBy: [.id], in: context).map(\.id) == ["lens-a", "lens-c"])
        #expect(try HierarchyLens.count(matching: .mount("PL"), in: context) == 2)
        #expect(try HierarchyLens.fetchFirst(matching: [], sortedBy: [.id.descending], in: context)?.id == "lens-c")
        #expect(try !HierarchyBrand.exists(in: context))
        #expect(try HierarchyAsset.count(in: context) == 2)
        #expect(try HierarchyLens.fetch(request: HierarchyLens.request(), in: context).count == 2)
    }

    @Test("withDeleted and deleted(_:) ask for the deleted objects")
    func optOut() throws {
        let database = try makeDatabase()
        let context = database.viewContext
        let all = HierarchyLens.Query.mount("PL").withDeleted()
        #expect(try HierarchyLens.count(matching: all, in: context) == 3)
        #expect(try HierarchyLens.fetch(matching: .deleted(true), in: context).map(\.id) == ["lens-b"])
        #expect(try HierarchyLens.count(matching: .deleted(false), in: context) == 2)
        // the flag survives the boolean operators
        let combined: HierarchyLens.Query = .mount("PL") && HierarchyLens.Query.id(.notEqual("lens-a")).withDeleted()
        #expect(try HierarchyLens.count(matching: combined, in: context) == 2)
        #expect(try HierarchyAsset.count(matching: HierarchyAsset.Query.all.withDeleted(), in: context) == 4)
    }

    @Test("a lookup by identifier finds a deleted object")
    func identifierLookups() throws {
        let database = try makeDatabase()
        let context = database.viewContext
        #expect(try HierarchyLens.fetch(id: "lens-b", in: context).isSoftDeleted)
        #expect(try HierarchyLens.fetchFirst(id: "lens-b", in: context) != nil)
        #expect(try HierarchyLens.fetch(ids: ["lens-a", "lens-b"], in: context).count == 2)
        #expect(try HierarchyLens.count(matching: .id("lens-b"), in: context) == 1)
        #expect(throws: DatabaseError.alreadyExists(entity: "HierarchyLens", id: "lens-b")) { try HierarchyLens.create(id: "lens-b", in: context) }
    }

    @Test("a FetchController and the batch requests apply the filter")
    func controllerAndBatches() async throws {
        let database = try makeDatabase()
        let controller = FetchController(HierarchyLens.request(sortedBy: [.id]), in: database, coalescingInterval: 0)
        #expect(controller.results.map(\.id) == ["lens-a", "lens-c"])

        try await database.enqueueBackgroundTaskAndSave { context in
            try HierarchyLens.update(matching: .mount("PL"), set: [.mount("EF")], in: context)
            try HierarchyLens.deleteAll(matching: .id("lens-c"), in: context)
        }
        try await awaitCondition { (try? HierarchyLens.count(matching: HierarchyLens.Query.all.withDeleted(), in: database.viewContext)) == 2 }
        let context = database.viewContext
        // the deleted lens kept its mount, the batch update skipped it
        #expect(try HierarchyLens.fetch(id: "lens-b", in: context).a_mount == "PL")
        #expect(try HierarchyLens.fetch(id: "lens-a", in: context).a_mount == "EF")
    }

    // MARK: By date

    /// Three memos: `memo-old` deleted long ago, `memo-new` deleted a minute ago, `memo-live` live.
    private func makeMemos() throws -> Database<HierarchySchema> {
        let database = Database<HierarchySchema>.ephemeral(name: "SoftDeleteByDate")
        try database.setup()
        let context = database.viewContext.nsContext
        for (id, deletedAt) in [("memo-old", Date(timeIntervalSinceNow: -90 * 86_400) as Date?), ("memo-new", Date(timeIntervalSinceNow: -60)), ("memo-live", nil)] {
            let memo = HierarchyMemo(context: context)
            memo.a_id = id
            memo.a_deletedAt = deletedAt
        }
        try context.save()
        return database
    }

    @Test("an entity soft-deleted by date is filtered the same way")
    func byDate() throws {
        let database = try makeMemos()
        let context = database.viewContext
        #expect(try HierarchyMemo.fetch(in: context).map(\.id) == ["memo-live"])
        #expect(try HierarchyMemo.count(matching: .deleted(true), in: context) == 2)
        #expect(try HierarchyMemo.count(matching: .deleted(false), in: context) == 1)
        #expect(try HierarchyMemo.count(matching: HierarchyMemo.Query.all.withDeleted(), in: context) == 3)
        #expect(try HierarchyMemo.fetch(id: "memo-old", in: context).isSoftDeleted)
    }

    @Test("a deletion date is read, and queried by range")
    func deletionDates() throws {
        let database = try makeMemos()
        let context = database.viewContext
        let purgeable = try HierarchyMemo.fetch(matching: .deleted(.lessThan(Date(timeIntervalSinceNow: -30 * 86_400))), in: context)
        #expect(purgeable.map(\.id) == ["memo-old"])
        #expect(try HierarchyMemo.fetch(id: "memo-new", in: context).softDeletionDate != nil)
        #expect(try HierarchyMemo.fetch(id: "memo-live", in: context).softDeletionDate == nil)
        // a flag records no date: a range matches nothing
        #expect(try HierarchyLens.count(matching: .deleted(.lessThan(.now)), in: context) == 0)
        #expect(try HierarchyLens.count(in: context) == 0)
    }

    @Test("the helpers read the flag")
    func helpers() throws {
        let database = try makeDatabase()
        let lenses = try HierarchyLens.fetch(matching: HierarchyLens.Query.all.withDeleted(), sortedBy: [.id], in: database.viewContext)
        #expect(lenses.map(\.isSoftDeleted) == [false, true, false])
        #expect(lenses.allSatisfy { $0.softDeletionDate == nil })
        #expect(lenses.compactMap(\.nilIfSoftDeleted).map(\.id) == ["lens-a", "lens-c"])
        #expect(lenses.removingSoftDeleted().map(\.id) == ["lens-a", "lens-c"])
    }
}
