import CoreData
import Foundation
import Synchronization
import Testing
@testable import AmphoraKit
import AmphoraKitTestSupport

@MainActor
struct StoreLifetimeTests {

    @Test("a database that was not set up reports it and runs nothing")
    func notSetUp() async throws {
        let database = TestDatabase.ephemeral()
        #expect(!database.isSetUp)
        #expect(throws: DatabaseError.notSetUp) { try database.withOpenStore { } }
        #expect(throws: DatabaseError.notSetUp) { try database.performAndSave { _ in } }
        await #expect(throws: DatabaseError.notSetUp) { try await database.enqueueBackgroundTask { _ in } }
        #expect(throws: DatabaseError.notSetUp) { try database.clear() }
    }

    @Test("setup is idempotent")
    func setupTwice() throws {
        let (database, _) = try makeDatabase()
        #expect(try database.setup() == .loaded)
        #expect(database.isSetUp)
    }

    @Test("work queued for the current store runs, work queued for a cleared store is skipped")
    func epochs() throws {
        let (database, _) = try makeDatabase()
        let epoch = database.currentStoreEpoch
        #expect(try database.withOpenStore(queuedAt: epoch) { 42 } == 42)
        try database.clear()
        #expect(database.currentStoreEpoch == epoch + 1)
        #expect(throws: DatabaseError.storeCleared) { try database.withOpenStore(queuedAt: epoch) { } }
        #expect(try database.withOpenStore(queuedAt: epoch + 1) { 1 } == 1)
    }

    @Test("clear empties the store and the next save works")
    func clearThenSave() async throws {
        let (database, _) = try makeDatabase()
        try await database.seedItems(["a", "b"])
        #expect(try await database.itemCount() == 2)
        try database.clear()
        #expect(try await database.itemCount() == 0)
        try database.performAndSave { context in
            let item = TestItem(context: context.nsContext)
            item.id = "c"; item.name = "c"; item.createdAt = .now
        }
        #expect(try await database.itemCount() == 1)
    }

    @Test("clear waits for a running task before destroying the store")
    func clearWaitsForRunningTask() async throws {
        let (database, _) = try makeDatabase()
        let started = Gate(), release = Gate()
        let finished = Mutex(false)
        let running = Task.detached {
            try await database.enqueueBackgroundTaskAndSave { context in
                started.open()
                release.wait()
                let item = TestItem(context: context.nsContext)
                item.id = "late"; item.name = "late"; item.createdAt = .now
                finished.withLock { $0 = true }
            }
        }
        #expect(started.wait())
        Task.detached {
            try? await Task.sleep(for: .milliseconds(200))
            release.open()
        }
        try database.clear(timeout: .seconds(5))
        // The task completed before the store was replaced; its row went with the old store.
        #expect(finished.withLock { $0 })
        _ = try await running.value
        #expect(try await database.itemCount() == 0)
    }

    @Test("a clear that times out leaves the store intact and the task finishes later")
    func clearTimeout() async throws {
        let (database, logger) = try makeDatabase()
        try await database.seedItems(["kept"])
        let started = Gate(), release = Gate()
        let running = Task.detached {
            try await database.enqueueBackgroundTask { _ in
                started.open()
                release.wait()
            }
        }
        #expect(started.wait())
        #expect(throws: DatabaseError.clearTimedOut) { try database.clear(timeout: .milliseconds(100)) }
        #expect(logger.errors.contains { $0.message.contains("timed out") })
        release.open()
        try await running.value
        // Intact: the row is still there, and a later clear succeeds.
        #expect(try await database.itemCount() == 1)
        try database.clear()
        #expect(try await database.itemCount() == 0)
    }

    @Test("clear runs the hooks, then posts the notification synchronously, before it returns")
    func clearHooksAndNotification() throws {
        let events = Mutex<[String]>([])
        var configuration = DatabaseConfiguration(name: "Hooks", storage: .ephemeral)
        configuration.willClear = { events.withLock { $0.append("will") } }
        configuration.didClear = { events.withLock { $0.append("did") } }
        let database = TestDatabase(configuration: configuration)
        try database.setup()
        let observation = NotificationCenter.default.addObserver(forName: TestDatabase.didClearNotification, object: database, queue: nil) { _ in
            events.withLock { $0.append("notification") }
        }
        defer { NotificationCenter.default.removeObserver(observation) }
        try database.clear()
        #expect(events.withLock { $0 } == ["will", "did", "notification"])
    }
}
