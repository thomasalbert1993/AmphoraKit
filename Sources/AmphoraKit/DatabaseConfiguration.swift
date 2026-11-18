import CoreData

/// How a `Database` opens its store and behaves around it.
///
/// The model itself comes from the database's `Schema`; the configuration names the store file
/// and chooses where it lives, how contexts merge, what happens when the store fails to open,
/// where logs go, and what runs around `clear()`.
///
public struct DatabaseConfiguration: Sendable {

    /// Where the store lives.
    public enum Storage: Sendable, Hashable {

        /// A SQLite file at the URL, or at `<Application Support>/<name>.sqlite` when `nil`.
        case persistent(url: URL? = nil)

        /// A SQLite store written to `/dev/null`: nothing is persisted, yet batch requests work,
        /// unlike `NSInMemoryStoreType`. Meant for tests.
        case ephemeral
    }

    /// The merge policy of a context, as a value.
    public enum MergePolicy: Sendable, Hashable {
        case error
        case propertyStoreTrump
        case propertyObjectTrump
        case overwrite
        case rollback

        var nsMergePolicy: NSMergePolicy {
            switch self {
                case .error: return NSMergePolicy.error
                case .propertyStoreTrump: return NSMergePolicy.mergeByPropertyStoreTrump
                case .propertyObjectTrump: return NSMergePolicy.mergeByPropertyObjectTrump
                case .overwrite: return NSMergePolicy.overwrite
                case .rollback: return NSMergePolicy.rollback
            }
        }
    }

    /// What `setup()` does when the store fails to open.
    public enum LoadFailurePolicy: Sendable, Hashable {

        /// Destroys the store file and recreates an empty one. `setup()` then reports
        /// `SetupOutcome.recreatedAfterLoadFailure` so the owner can reset what depended on it.
        case destroyAndRecreate

        /// Rethrows the load error; the database stays unusable (`DatabaseError.notSetUp`).
        case propagate
    }

    /// The store file name, without extension.
    public var name: String

    /// Where the store lives.
    public var storage: Storage

    /// The merge policy of the view context.
    public var viewContextMergePolicy: MergePolicy

    /// The merge policy of the background contexts.
    public var backgroundMergePolicy: MergePolicy

    /// What `setup()` does when the store fails to open.
    public var loadFailurePolicy: LoadFailurePolicy

    /// Where the database logs, `nil` for nowhere.
    public var logger: (any DatabaseLogging)?

    /// Runs on the main actor at the start of `clear()`, before anything is torn down.
    public var willClear: (@MainActor @Sendable () -> Void)?

    /// Runs on the main actor once the store was recreated, before `Database.didClearNotification`
    /// is posted: the owner cleans what it keeps beside the store (files, defaults) before the
    /// rest of the app is told.
    public var didClear: (@MainActor @Sendable () -> Void)?

    public init(
        name: String,
        storage: Storage = .persistent(),
        viewContextMergePolicy: MergePolicy = .propertyObjectTrump,
        backgroundMergePolicy: MergePolicy = .propertyStoreTrump,
        loadFailurePolicy: LoadFailurePolicy = .destroyAndRecreate,
        logger: (any DatabaseLogging)? = nil
    ) {
        self.name = name
        self.storage = storage
        self.viewContextMergePolicy = viewContextMergePolicy
        self.backgroundMergePolicy = backgroundMergePolicy
        self.loadFailurePolicy = loadFailurePolicy
        self.logger = logger
    }
}

/// What `Database.setup()` did.
public enum SetupOutcome: Sendable, Hashable {

    /// The store opened, or was already open.
    case loaded

    /// The store failed to open and was destroyed and recreated empty
    /// (`DatabaseConfiguration.LoadFailurePolicy.destroyAndRecreate`).
    case recreatedAfterLoadFailure
}
