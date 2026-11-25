import CoreData
import Foundation
import Testing
@testable import AmphoraKit
import AmphoraKitTestSupport

@MainActor
struct StoreOptionsTests {

    private let options = DatabaseConfiguration.StoreOptions(
        persistentHistoryTracking: true,
        remoteChangeNotifications: true,
        sqlitePragmas: ["journal_mode": "DELETE"]
    )

    @Test("the store opens with its options")
    func optionsAtSetup() throws {
        let (database, _, _) = makeFileDatabase(storeOptions: options)
        try database.setup()
        expectOptions(of: database)
    }

    @Test("the options survive a clear")
    func optionsAfterClear() throws {
        let (database, _, _) = makeFileDatabase(storeOptions: options)
        try database.setup()
        try database.clear()
        expectOptions(of: database)
    }

    @Test("the options survive the recreation after a load failure")
    func optionsAfterLoadFailure() throws {
        let directory = temporaryDirectory()
        try Data("not a SQLite store".utf8).write(to: directory.appendingPathComponent("Store.sqlite"))
        let (database, _, _) = makeFileDatabase(in: directory, storeOptions: options)

        #expect(try database.setup() == .recreatedAfterLoadFailure)
        expectOptions(of: database)
    }

    @Test("the store description carries the options")
    func storeDescription() {
        let (database, _, storeURL) = makeFileDatabase(storeOptions: options)
        #expect(database.storeDescription.url == storeURL)
        #expect(database.storeDescription.options[NSPersistentHistoryTrackingKey] as? NSNumber == true)
    }

    @Test("default options set nothing")
    func defaults() {
        #expect(DatabaseConfiguration.StoreOptions().dictionary.isEmpty)
    }

    @Test("history is recorded once tracked")
    func historyIsRecorded() async throws {
        let (database, _, _) = makeFileDatabase(storeOptions: options)
        try database.setup()
        try await database.seedItems(["a"])
        let transactions = try await database.enqueueBackgroundTask { context in
            let request = NSPersistentHistoryChangeRequest.fetchHistory(after: .distantPast)
            let result = try context.nsContext.execute(request) as? NSPersistentHistoryResult
            return (result?.result as? [NSPersistentHistoryTransaction])?.count ?? 0
        }
        #expect(transactions == 1)
    }

    private func expectOptions(of database: TestDatabase, sourceLocation: SourceLocation = #_sourceLocation) {
        let store = database.persistentContainer.persistentStoreCoordinator.persistentStores.first
        #expect(store?.options?[NSPersistentHistoryTrackingKey] as? NSNumber == true, sourceLocation: sourceLocation)
        #expect(store?.options?[NSPersistentStoreRemoteChangeNotificationPostOptionKey] as? NSNumber == true, sourceLocation: sourceLocation)
        #expect((store?.options?[NSSQLitePragmasOption] as? [String: String])?["journal_mode"] == "DELETE", sourceLocation: sourceLocation)
    }
}
