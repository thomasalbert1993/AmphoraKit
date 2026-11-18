import CoreData
import Foundation
import Testing
@testable import AmphoraKit
import AmphoraKitTestSupport

typealias TestDatabase = Database<TestSchema>

/// An open ephemeral database, with a recording logger.
@MainActor
func makeDatabase(name: String = "AmphoraKitTest") throws -> (database: TestDatabase, logger: RecordingLogger) {
    let logger = RecordingLogger()
    let database = TestDatabase.ephemeral(name: name, logger: logger)
    try database.setup()
    return (database, logger)
}

extension TestDatabase {

    /// Inserts items with the given names in one saved task.
    @discardableResult
    func seedItems(_ names: [String], folderNamed folderName: String? = nil) async throws -> [String] {
        try await enqueueBackgroundTaskAndSave { context in
            let folder = try folderName.map { name -> TestFolder in
                let folder = try TestFolder.fetchOrCreate(id: name, in: context)
                folder.name = name
                return folder
            }
            return names.map { name in
                let item = TestItem(context: context.nsContext)
                item.id = name
                item.name = name
                item.createdAt = .now
                item.folder = folder
                return item.id
            }
        }
    }

    /// How many items the store holds, counted from a fresh task.
    func itemCount() async throws -> Int {
        try await enqueueBackgroundTask { context in
            try TestItem.count(in: context)
        }
    }
}

/// A gate a task can block on until the test opens it, with a timeout so a broken test fails
/// instead of hanging.
final class Gate: Sendable {

    private let semaphore = DispatchSemaphore(value: 0)

    func open() {
        semaphore.signal()
    }

    /// Blocks until opened. Returns `false` on timeout.
    @discardableResult
    func wait(seconds: Double = 5) -> Bool {
        semaphore.wait(timeout: .now() + seconds) == .success
    }
}
