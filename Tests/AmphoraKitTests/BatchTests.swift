import CoreData
import Foundation
import Testing
@testable import AmphoraKit
import AmphoraKitTestSupport

@MainActor
struct BatchTests {

    @Test("a batch insert lands in the task context and in the view context")
    func insert() async throws {
        let (database, _) = try makeDatabase()
        let countInTask = try await database.enqueueBackgroundTask { context in
            // Built inside the task: a `[[String: Any]]` payload is not Sendable.
            let rows = (0..<1000).map { index -> [String: Any] in
                ["id": "r\(index)", "name": "Row \(index)", "createdAt": Date(), "score": Double(index), "kindRaw": "plain"]
            }
            try TestItem.insert(rows, in: context)
            return try TestItem.count(in: context)
        }
        #expect(countInTask == 1000)
        try await awaitCondition { (try? TestItem.count(in: database.viewContext)) == 1000 }
    }

    @Test("a BETWEEN query runs against the SQLite store, bounds included")
    func betweenFetchesFromStore() async throws {
        let (database, _) = try makeDatabase()
        let count = try await database.enqueueBackgroundTask { context in
            let rows = (1...6).map { index -> [String: Any] in
                ["id": "b\(index)", "name": "Row \(index)", "createdAt": Date(), "score": Double(index), "kindRaw": "plain"]
            }
            try TestItem.insert(rows, in: context)
            return try TestItem.count(matching: .score(.between(2, 4)), in: context)
        }
        #expect(count == 3)
    }

    @Test("a batch update is reflected on an object already registered in the view context")
    func update() async throws {
        let (database, _) = try makeDatabase()
        try await database.seedItems(["u1", "u2"])
        let registered = try TestItem.fetch(id: "u1", in: database.viewContext)
        #expect(registered.score == 0)
        try await database.enqueueBackgroundTask { context in
            try TestItem.update(matching: .name("u1"), ["score": 9.0], in: context)
            try TestItem.update(ids: ["u2"], ["score": 5.0], in: context)
            try TestItem.update(ids: [], ["score": 1.0], in: context)
        }
        try await awaitCondition { registered.score == 9 }
        #expect(try TestItem.fetch(id: "u2", in: database.viewContext).score == 5)
    }

    @Test("a batch delete turns the view context's object into a zombie")
    func delete() async throws {
        let (database, _) = try makeDatabase()
        try await database.seedItems(["d1", "d2", "d3"])
        let doomed = try TestItem.fetch(id: "d1", in: database.viewContext)
        try await database.enqueueBackgroundTask { context in
            try TestItem.delete(id: "d1", in: context)
            try TestItem.delete(ids: ["d2"], in: context)
            try TestItem.delete(ids: [], in: context)
        }
        try await awaitCondition { doomed.isZombie }
        #expect(try TestItem.count(in: database.viewContext) == 1)
        try await database.enqueueBackgroundTask { context in
            try TestItem.deleteAll(in: context)
        }
        try await awaitCondition { (try? TestItem.count(in: database.viewContext)) == 0 }
    }

    @Test("a typed deleteAll only removes what matches")
    func deleteMatching() async throws {
        let (database, _) = try makeDatabase()
        try await database.seedItems(["keep", "drop"])
        let remaining = try await database.enqueueBackgroundTask { context in
            try TestItem.deleteAll(matching: .name(.hasPrefix("dr")), in: context)
            return try TestItem.fetch(in: context).map(\.name)
        }
        #expect(remaining == ["keep"])
    }
}
