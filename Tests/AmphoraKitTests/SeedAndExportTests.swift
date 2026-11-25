import CoreData
import Foundation
import Testing
@testable import AmphoraKit
import AmphoraKitTestSupport

@MainActor
struct SeedAndExportTests {

    /// A single-file store holding the given items, exported from a store of its own.
    private func makeSeed(_ names: [String]) async throws -> URL {
        let (source, _, _) = makeFileDatabase(name: "Source")
        try source.setup()
        try await source.seedItems(names)
        let seedURL = temporaryDirectory().appendingPathComponent("Seed.sqlite")
        try source.exportStore(to: seedURL)
        return seedURL
    }


    // MARK: Export

    @Test("an export reopens with every saved object, in a single file")
    func exportRoundTrip() async throws {
        let (source, _, _) = makeFileDatabase(name: "Source")
        try source.setup()
        try await source.seedItems(["a", "b", "c"])

        let exportURL = temporaryDirectory().appendingPathComponent("Export.sqlite")
        try source.exportStore(to: exportURL)
        #expect(!FileManager.default.fileExists(atPath: exportURL.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: exportURL.path + "-shm"))

        let reopened = TestDatabase(configuration: .init(name: "Export", storage: .persistent(url: exportURL)))
        try reopened.setup()
        #expect(try await reopened.itemCount() == 3)
    }

    @Test("exporting leaves the open store usable, with its options")
    func exportKeepsTheStore() async throws {
        let (source, _, _) = makeFileDatabase(name: "Source", storeOptions: .init(persistentHistoryTracking: true))
        try source.setup()
        try await source.seedItems(["a"])
        let storeBefore = source.persistentContainer.persistentStoreCoordinator.persistentStores.first

        try source.exportStore(to: temporaryDirectory().appendingPathComponent("Export.sqlite"))

        let storeAfter = source.persistentContainer.persistentStoreCoordinator.persistentStores.first
        #expect(storeAfter === storeBefore)
        #expect(storeAfter?.options?[NSPersistentHistoryTrackingKey] as? NSNumber == true)
        try await source.seedItems(["b"])
        #expect(try await source.itemCount() == 2)
    }

    @Test("an export replaces an existing file")
    func exportReplaces() async throws {
        let exportURL = temporaryDirectory().appendingPathComponent("Export.sqlite")
        try Data("stale".utf8).write(to: exportURL)
        let (source, _, _) = makeFileDatabase(name: "Source")
        try source.setup()
        try await source.seedItems(["a"])

        try source.exportStore(to: exportURL)

        let reopened = TestDatabase(configuration: .init(name: "Export", storage: .persistent(url: exportURL), loadFailurePolicy: .propagate))
        try reopened.setup()
        #expect(try await reopened.itemCount() == 1)
    }

    @Test("an ephemeral or closed store can't be exported")
    func exportUnavailable() throws {
        let exportURL = temporaryDirectory().appendingPathComponent("Export.sqlite")
        let (ephemeral, _) = try makeDatabase()
        #expect(throws: DatabaseError.storeUnavailable) { try ephemeral.exportStore(to: exportURL) }
        let (closed, _, _) = makeFileDatabase()
        #expect(throws: DatabaseError.notSetUp) { try closed.exportStore(to: exportURL) }
    }


    // MARK: Seed

    @Test("a missing store is seeded at setup")
    func seededAtSetup() async throws {
        let seedURL = try await makeSeed(["a", "b"])
        let (database, logger, _) = makeFileDatabase(seedStoreURL: seedURL)
        try database.setup()
        #expect(try await database.itemCount() == 2)
        #expect(logger.entries.contains { $0.level == .info && $0.message.contains("seeded") })
    }

    @Test("an existing store is not replaced by the seed")
    func existingStoreKept() async throws {
        let seedURL = try await makeSeed(["a", "b"])
        let directory = temporaryDirectory()

        let (first, _, _) = makeFileDatabase(in: directory)
        try first.setup()
        try await first.seedItems(["mine"])
        try first.persistentContainer.persistentStoreCoordinator.persistentStores.forEach {
            try first.persistentContainer.persistentStoreCoordinator.remove($0)
        }

        let (second, _, _) = makeFileDatabase(in: directory, seedStoreURL: seedURL)
        try second.setup()
        let names = try await second.enqueueBackgroundTask { context in try TestItem.fetch(in: context).map(\.name) }
        #expect(names == ["mine"])
    }

    @Test("the seed is copied again after a clear")
    func seededAfterClear() async throws {
        let seedURL = try await makeSeed(["a", "b"])
        let (database, _, _) = makeFileDatabase(seedStoreURL: seedURL)
        try database.setup()
        try await database.seedItems(["c"])
        #expect(try await database.itemCount() == 3)

        try database.clear()
        #expect(try await database.itemCount() == 2)
    }

    @Test("the seed is copied again after a load failure")
    func seededAfterLoadFailure() async throws {
        let seedURL = try await makeSeed(["a", "b"])
        let directory = temporaryDirectory()
        try Data("not a SQLite store".utf8).write(to: directory.appendingPathComponent("Store.sqlite"))
        let (database, _, _) = makeFileDatabase(in: directory, seedStoreURL: seedURL)

        #expect(try database.setup() == .recreatedAfterLoadFailure)
        #expect(try await database.itemCount() == 2)
    }

    @Test("a seed that can't be copied is logged and the store opens empty")
    func missingSeed() async throws {
        let missing = temporaryDirectory().appendingPathComponent("Missing.sqlite")
        let (database, logger, _) = makeFileDatabase(seedStoreURL: missing)
        try database.setup()
        #expect(try await database.itemCount() == 0)
        #expect(logger.errors.contains { $0.message.contains("Failed to seed") })
    }

    @Test("an ephemeral store ignores the seed")
    func ephemeralIgnoresSeed() async throws {
        let seedURL = try await makeSeed(["a"])
        let database = TestDatabase(configuration: .init(name: "Ephemeral", storage: .ephemeral, seedStoreURL: seedURL))
        try database.setup()
        #expect(try await database.itemCount() == 0)
    }
}
