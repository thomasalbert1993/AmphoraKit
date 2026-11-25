import CoreData
import Foundation
import Testing
@testable import AmphoraKit
import AmphoraKitTestSupport

@MainActor
struct CreationAndLookupTests {

    // MARK: Creation

    @Test("create inserts an object with the identifier and calls didCreate once the identifier is set")
    func create() async throws {
        let (database, _) = try makeDatabase()
        let outcome = try await database.enqueueBackgroundTaskAndSave { context in
            let item = try TestItem.create(id: "a", in: context)
            item.name = "A"
            item.createdAt = .now
            return (item.didCreateCount, item.idSeenByDidCreate)
        }
        #expect(outcome.0 == 1)
        #expect(outcome.1 == "a")
        #expect(try await database.itemCount() == 1)
    }

    @Test("create throws when the identifier exists, and inserts nothing")
    func createDuplicate() async throws {
        let (database, _) = try makeDatabase()
        try await database.seedItems(["a"])
        await #expect(throws: DatabaseError.alreadyExists(entity: "TestItem", id: "a")) {
            try await database.enqueueBackgroundTaskAndSave { context in
                _ = try TestItem.create(id: "a", in: context)
            }
        }
        #expect(try await database.itemCount() == 1)
    }

    @Test("fetchOrCreate calls didCreate when it inserts only")
    func fetchOrCreateCallsDidCreate() async throws {
        let (database, _) = try makeDatabase()
        try await database.seedItems(["a"])
        let counts = try await database.enqueueBackgroundTask { context in
            let existing = try TestItem.fetchOrCreate(id: "a", in: context)
            let created = try TestItem.fetchOrCreate(id: "b", in: context)
            return [existing.didCreateCount, created.didCreateCount]
        }
        #expect(counts == [0, 1])
    }


    // MARK: Lookup

    @Test("fetchFirst(id:) and fetchFirstOrNil(id:) return the object or nil, fetch(id:) throws")
    func lookupByID() async throws {
        let (database, _) = try makeDatabase()
        try await database.seedItems(["a"])
        let names = try await database.enqueueBackgroundTask { context in
            [try TestItem.fetchFirst(id: "a", in: context)?.name,
             try TestItem.fetchFirst(id: "z", in: context)?.name,
             TestItem.fetchFirstOrNil(id: "a", in: context)?.name,
             TestItem.fetchFirstOrNil(id: "z", in: context)?.name]
        }
        #expect(names == ["a", nil, "a", nil])
        await #expect(throws: DatabaseError.notFound(entity: "TestItem", id: "z")) {
            try await database.enqueueBackgroundTask { context in _ = try TestItem.fetch(id: "z", in: context) }
        }
    }

    @Test("fetchOrEmpty(ids:) returns the objects found, nothing for no identifier")
    func fetchOrEmptyByIDs() async throws {
        let (database, _) = try makeDatabase()
        try await database.seedItems(["a", "b", "c"])
        let counts = try await database.enqueueBackgroundTask { context in
            [TestItem.fetchOrEmpty(ids: ["a", "c", "z"], in: context).count, TestItem.fetchOrEmpty(ids: [], in: context).count]
        }
        #expect(counts == [2, 0])
    }

    @Test("fetchFirst returns the first object in the sort order")
    func fetchFirst() async throws {
        let (database, _) = try makeDatabase()
        try await database.seedItems(["b", "a", "c"])
        let first = try await database.enqueueBackgroundTask { context in
            try TestItem.fetchFirst(matching: [], sortedBy: [.name.descending], in: context)?.name
        }
        #expect(first == "c")
        let byRequest = try await database.enqueueBackgroundTask { context in
            try TestItem.fetchFirst(request: Request(sortedBy: [.name]), in: context)?.name
        }
        #expect(byRequest == "a")
    }


    // MARK: Existence

    @Test("exists tells whether an object matches")
    func exists() async throws {
        let (database, _) = try makeDatabase()
        try await database.seedItems(["a", "b"])
        let answers = try await database.enqueueBackgroundTask { context in
            [try TestItem.exists(in: context),
             try TestItem.exists(matching: .name("a"), in: context),
             try TestItem.exists(matching: [.name("a"), .name("b")], in: context),
             try TestItem.exists(request: Request(matching: .name("b")), in: context),
             try TestItem.exists(request: Request(matching: .name("z")), in: context)]
        }
        #expect(answers == [true, true, false, true, false])
    }

    @Test("exists on an empty store is false")
    func existsEmpty() async throws {
        let (database, _) = try makeDatabase()
        #expect(try await database.enqueueBackgroundTask { context in try TestItem.exists(in: context) } == false)
    }
}
