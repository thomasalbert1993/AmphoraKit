import CoreData
import Foundation
import Testing
@testable import AmphoraKit
import AmphoraKitTestSupport

@MainActor
struct FetchControllerTests {

    @Test("an interval of zero emits on every change, with the live results")
    func synchronousEmission() async throws {
        let (database, _) = try makeDatabase()
        let controller = FetchController<TestItem>(sortedBy: [.name], in: database, coalescingInterval: 0)
        var emissions: [[String]] = []
        controller.onChange { emissions.append($0.map(\.name)) }
        try await database.seedItems(["a"])
        try await awaitCondition { emissions.count == 1 }
        try await database.seedItems(["b"])
        try await awaitCondition { emissions.count == 2 }
        #expect(emissions == [["a"], ["a", "b"]])
        #expect(controller.results.map(\.name) == ["a", "b"])
    }

    @Test("a burst of changes becomes a leading call and a single trailing call")
    func coalescing() async throws {
        let (database, _) = try makeDatabase()
        let controller = FetchController<TestItem>(matching: .all, sortedBy: [.name], in: database, coalescingInterval: 0.3)
        var counts: [Int] = []
        controller.onChange { counts.append($0.count) }
        for name in ["a", "b", "c", "d"] {
            try await database.seedItems([name])
            try await Task.sleep(for: .milliseconds(30))
        }
        try await awaitCondition { counts.count >= 1 }
        #expect(counts.first == 1)
        try await awaitCondition(timeout: .seconds(2)) { counts.count == 2 }
        try await Task.sleep(for: .milliseconds(400))
        #expect(counts == [1, 4])
    }

    @Test("refetch emits now and cancels the trailing emission")
    func refetch() async throws {
        let (database, _) = try makeDatabase()
        let controller = FetchController<TestItem>(sortedBy: [.name], in: database, coalescingInterval: 0.3)
        var counts: [Int] = []
        controller.onChange { counts.append($0.count) }
        try await database.seedItems(["a"])
        try await awaitCondition { counts.count == 1 }
        try await database.seedItems(["b"])
        try await Task.sleep(for: .milliseconds(50))
        controller.refetch()
        #expect(counts == [1, 2])
        try await Task.sleep(for: .milliseconds(400))
        #expect(counts == [1, 2])
    }

    @Test("notifyChangesOnly reports changes with empty results and leaves the caller's request alone")
    func notifyChangesOnly() async throws {
        let (database, _) = try makeDatabase()
        let request = TestItem.baseFetchRequest(sortedBy: [.name])
        request.fetchBatchSize = 20
        let controller = FetchController(request, in: database, notifyChangesOnly: true, coalescingInterval: 0)
        var notified = 0
        controller.onChange { results in
            notified += 1
            #expect(results.isEmpty)
        }
        try await database.seedItems(["a"])
        try await awaitCondition { notified == 1 }
        #expect(controller.results.isEmpty)
        #expect(request.fetchBatchSize == 20)
        #expect(request.returnsObjectsAsFaults)
    }

    @Test("clear refetches synchronously, inside clear, and changes keep flowing afterwards")
    func clear() async throws {
        let (database, _) = try makeDatabase()
        try await database.seedItems(["a", "b"])
        let controller = FetchController<TestItem>(sortedBy: [.name], in: database, coalescingInterval: 0)
        #expect(controller.results.count == 2)
        var emissions: [[String]] = []
        controller.onChange { emissions.append($0.map(\.name)) }
        try database.clear()
        #expect(emissions == [[]])
        #expect(controller.results.isEmpty)
        try await database.seedItems(["c"])
        try await awaitCondition { emissions.count == 2 }
        #expect(emissions.last == ["c"])
    }
}
