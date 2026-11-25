import Foundation
import Synchronization
import AmphoraKit

extension Database {

    /// A database on an ephemeral store, not yet set up. Each call opens an independent store.
    ///
    /// - Parameter queues: The background queues, to share with other databases; its own by default.
    public static func ephemeral(
        name: String = "AmphoraKitTest",
        queues: DatabaseQueues = .init(),
        logger: (any DatabaseLogging)? = nil
    ) -> Database<Schema> {
        Database(configuration: DatabaseConfiguration(name: name, storage: .ephemeral, queues: queues, logger: logger))
    }

    /// Opens the store on the first call, clears it on the next ones: the one line a test
    /// bootstrap needs.
    @MainActor
    public func resetForNextTest() throws {
        if isSetUp {
            try clear()
        } else {
            try setup()
        }
    }
}

/// A logger that records what the database reports, for assertions.
public final class RecordingLogger: DatabaseLogging {

    /// A recorded line.
    public struct Entry: Equatable, Sendable {
        public enum Level: Sendable { case info, error }
        public let level: Level
        public let message: String
        public let errorDescription: String?
    }

    private let storage = Mutex<[Entry]>([])

    public init() { }

    /// Everything recorded so far, in order.
    public var entries: [Entry] {
        storage.withLock { $0 }
    }

    /// The error lines.
    public var errors: [Entry] {
        entries.filter { $0.level == .error }
    }

    public func info(_ message: String) {
        storage.withLock { $0.append(Entry(level: .info, message: message, errorDescription: nil)) }
    }

    public func error(_ message: String, _ error: (any Error)?) {
        storage.withLock { $0.append(Entry(level: .error, message: message, errorDescription: error.map { String(describing: $0) })) }
    }
}
