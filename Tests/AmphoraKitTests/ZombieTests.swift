import CoreData
import Foundation
import Testing
@testable import AmphoraKit
import AmphoraKitTestSupport

@MainActor
struct ZombieTests {

    @Test("removingZombies drops the faults whose row a batch delete removed, without trapping")
    func removingZombiesDropsInaccessibleFaults() async throws {
        let (database, _) = try makeDatabase()
        try await database.seedItems(["z1", "z2"])
        let viewContext = database.viewContext
        viewContext.stalenessInterval = 0
        let items = try TestItem.fetch(sortedBy: [.name], in: viewContext)
        #expect(items.count == 2)
        // Turn the first one back into a fault, then delete its row from another context.
        viewContext.refresh(items[0], mergeChanges: false)
        #expect(items[0].isFault)
        try await database.enqueueBackgroundTask { context in
            try TestItem.delete(id: "z1", in: context)
        }
        try await awaitCondition { items[0].isZombie }
        let alive = items.removingZombies()
        #expect(alive.map(\.name) == ["z2"])
        #expect(items[0].nilIfZombie == nil)
        #expect(items[1].nilIfZombie === items[1])
    }

    @Test("a detached object is a zombie")
    func detached() async throws {
        let (database, _) = try makeDatabase()
        let item = TestItem(context: database.viewContext.nsContext)
        item.id = "tmp"; item.name = "tmp"; item.createdAt = .now
        #expect(!item.isZombie)
        database.viewContext.delete(item)
        #expect(item.isZombie)
        let set: Set<TestItem> = [item]
        #expect(set.removingZombies().isEmpty)
    }
}
