import CoreData
import Foundation
import Testing
@testable import AmphoraKit
import AmphoraKitTestSupport

@MainActor
struct SetupTests {

    @Test("an ephemeral store persists nothing between two databases")
    func ephemeralIsEmpty() async throws {
        let (first, _) = try makeDatabase(name: "Shared")
        try await first.seedItems(["a"])
        let (second, _) = try makeDatabase(name: "Shared")
        #expect(try await second.itemCount() == 0)
        #expect(try await first.itemCount() == 1)
    }

    @Test("a persistent store lives at the given URL and survives a new database")
    func persistentStore() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AmphoraKit-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = TestDatabase(configuration: .init(name: "Persistent", storage: .persistent(url: url)))
        try first.setup()
        try await first.seedItems(["kept"])
        #expect(FileManager.default.fileExists(atPath: url.path))
        let second = TestDatabase(configuration: .init(name: "Persistent", storage: .persistent(url: url)))
        try second.setup()
        #expect(try await second.itemCount() == 1)
    }

    @Test("the default persistent location is <Application Support>/<name>.sqlite")
    func defaultLocation() {
        let database = TestDatabase(configuration: .init(name: "Located"))
        let url = database.persistentContainer.persistentStoreDescriptions.first?.url
        #expect(url == NSPersistentContainer.defaultDirectoryURL().appendingPathComponent("Located.sqlite"))
    }

    @Test("a load failure is propagated when asked, and the database stays unusable")
    func propagateLoadFailure() async throws {
        let unwritable = URL(fileURLWithPath: "/nonexistent-directory-\(UUID().uuidString)/store.sqlite")
        let logger = RecordingLogger()
        var configuration = DatabaseConfiguration(name: "Broken", storage: .persistent(url: unwritable), loadFailurePolicy: .propagate)
        configuration.logger = logger
        let database = TestDatabase(configuration: configuration)
        #expect(throws: (any Error).self) { try database.setup() }
        #expect(!database.isSetUp)
        #expect(logger.errors.contains { $0.message.contains("Failed to open the store") })
        await #expect(throws: DatabaseError.notSetUp) { try await database.enqueueBackgroundTask { _ in } }
    }

    @Test("a corrupt store is destroyed and recreated when asked, and reported as such")
    func recreateAfterLoadFailure() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AmphoraKit-corrupt-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("this is not a database".utf8).write(to: url)
        let logger = RecordingLogger()
        var configuration = DatabaseConfiguration(name: "Corrupt", storage: .persistent(url: url))
        configuration.logger = logger
        let database = TestDatabase(configuration: configuration)
        #expect(try database.setup() == .recreatedAfterLoadFailure)
        #expect(database.isSetUp)
        #expect(logger.errors.contains { $0.message.contains("destroying and recreating") })
        try await database.seedItems(["fresh"])
        #expect(try await database.itemCount() == 1)
    }
}
