import CoreData
import Foundation
import Testing
@testable import AmphoraKit
import AmphoraKitTestSupport

@MainActor
struct DatabaseObjectTests {

    @Test("fetch(id:) uses the entity's id key")
    func fetchById() async throws {
        let (database, _) = try makeDatabase()
        try await database.seedItems(["i1", "i2"], folderNamed: "f1")
        let (itemName, folderName, found, none) = try database.perform { context in
            (
                try TestItem.fetch(id: "i1", in: context).name,
                try TestFolder.fetch(id: "f1", in: context).name,
                try TestItem.fetch(ids: ["i1", "i2", "missing"], in: context).count,
                try TestItem.fetch(ids: [], in: context).count
            )
        }
        #expect(itemName == "i1")
        #expect(folderName == "f1")
        #expect(found == 2)
        #expect(none == 0)
    }

    @Test("fetch(id:) reports a missing object with its entity and identifier")
    func notFound() async throws {
        let (database, _) = try makeDatabase()
        #expect(throws: DatabaseError.notFound(entity: "TestItem", id: "nope")) {
            try database.perform { context in
                _ = try TestItem.fetch(id: "nope", in: context)
            }
        }
    }

    @Test("fetchOrCreate finds then creates, once")
    func fetchOrCreate() async throws {
        let (database, _) = try makeDatabase()
        let sameObject = try database.perform { context -> Bool in
            let created = try TestFolder.fetchOrCreate(id: "f", in: context)
            created.name = "Folder"
            let found = try TestFolder.fetchOrCreate(id: "f", in: context)
            try context.save()
            return created === found
        }
        #expect(sameObject)
        let (count, name) = try database.perform { context in
            (try TestFolder.count(in: context), try TestFolder.fetch(id: "f", in: context).name)
        }
        #expect(count == 1)
        #expect(name == "Folder")
    }

    @Test("typed fetches filter, sort, limit and count")
    func typedFetches() async throws {
        let (database, _) = try makeDatabase()
        try await database.enqueueBackgroundTaskAndSave { context in
            for (index, name) in ["b", "a", "c"].enumerated() {
                let item = TestItem(context: context.nsContext)
                item.id = name; item.name = name; item.createdAt = .now
                item.score = Double(index)
                item.kind = index == 2 ? .archived : .plain
            }
        }
        let context = database.viewContext
        #expect(try TestItem.fetch(sortedBy: [.name], in: context).map(\.name) == ["a", "b", "c"])
        #expect(try TestItem.fetch(matching: .score(.greaterThan(0)), sortedBy: [.score.descending], in: context).map(\.name) == ["c", "a"])
        #expect(try TestItem.fetch(matching: [.kind(.plain), .name(.in(["a", "b"]))], in: context).count == 2)
        #expect(try TestItem.first(matching: .kind(.archived), in: context)?.name == "c")
        #expect(try TestItem.fetch(sortedBy: [.score], limit: 1, in: context).map(\.name) == ["b"])
        #expect(try TestItem.count(matching: .kind == .plain, in: context) == 2)
        #expect(TestItem.fetchAll(matching: .name("a"), in: context).count == 1)
        #expect(TestItem.fetchFirst(matching: .name("zzz"), in: context) == nil)
    }

    @Test("update(with:) sets values by key and calls didUpdate")
    func updateWithValues() async throws {
        let (database, _) = try makeDatabase()
        let item = TestItem(context: database.viewContext.nsContext)
        item.id = "u"; item.name = "u"; item.createdAt = .now
        item.update(with: ["name": "updated", "score": 7.0])
        #expect(item.name == "updated")
        #expect(item.score == 7)
        #expect(item.didUpdateCount == 1)
    }

    @Test("the raw predicate escape hatch still works")
    func rawPredicates() async throws {
        let (database, _) = try makeDatabase()
        try await database.seedItems(["x", "y"])
        let context = database.viewContext
        #expect(TestItem.fetchAll(matching: NSPredicate(format: "name == %@", "x"), in: context).count == 1)
        #expect(TestItem.fetchFirst(matching: NSPredicate(format: "name == %@", "y"), in: context)?.name == "y")
    }
}
