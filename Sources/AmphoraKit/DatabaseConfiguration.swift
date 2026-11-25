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

    /// The options the store is opened with, every time: at `setup()`, and when it is recreated by
    /// `clear()` or after a load failure.
    public struct StoreOptions: Sendable, Hashable {

        /// Records every transaction in the store (`NSPersistentHistoryTrackingKey`), as
        /// `NSCoreDataCoreSpotlightDelegate` requires.
        public var persistentHistoryTracking: Bool

        /// Posts `NSPersistentStoreRemoteChange` on every write to the store, from this process or
        /// another (`NSPersistentStoreRemoteChangeNotificationPostOptionKey`).
        public var remoteChangeNotifications: Bool

        /// The data protection of the store files (`NSPersistentStoreFileProtectionKey`), `nil` for
        /// the system default. Ignored on macOS, which has no data protection classes.
        public var fileProtection: FileProtectionType?

        /// SQLite pragmas, such as `["journal_mode": "DELETE"]` (`NSSQLitePragmasOption`).
        public var sqlitePragmas: [String: String]

        public init(
            persistentHistoryTracking: Bool = false,
            remoteChangeNotifications: Bool = false,
            fileProtection: FileProtectionType? = nil,
            sqlitePragmas: [String: String] = [:]
        ) {
            self.persistentHistoryTracking = persistentHistoryTracking
            self.remoteChangeNotifications = remoteChangeNotifications
            self.fileProtection = fileProtection
            self.sqlitePragmas = sqlitePragmas
        }

        /// The options as store-description keys. Only the options that differ from Core Data's
        /// defaults are set.
        var dictionary: [String: NSObject] {
            var options: [String: NSObject] = [:]
            if persistentHistoryTracking {
                options[NSPersistentHistoryTrackingKey] = NSNumber(value: true)
            }
            if remoteChangeNotifications {
                options[NSPersistentStoreRemoteChangeNotificationPostOptionKey] = NSNumber(value: true)
            }
            #if !os(macOS)
            if let fileProtection {
                options[NSPersistentStoreFileProtectionKey] = fileProtection.rawValue as NSString
            }
            #endif
            if !sqlitePragmas.isEmpty {
                options[NSSQLitePragmasOption] = sqlitePragmas as NSDictionary
            }
            return options
        }
    }

    /// The store file name, without extension.
    public var name: String

    /// Where the store lives.
    public var storage: Storage

    /// The options the store is opened with, kept when it is recreated.
    public var storeOptions: StoreOptions

    /// A pre-filled store copied in place when the store file doesn't exist yet, and again after
    /// every recreation (`clear()`, load failure), along with its `-wal` and `-shm` files. A copy
    /// that fails is logged and the store opens empty. Ignored for `.ephemeral` storage.
    public var seedStoreURL: URL?

    /// The serial queues of the background tasks. Databases given the same instance share their
    /// labels — the default label included: a task of one never runs alongside a task of the
    /// other on the same label.
    public var queues: DatabaseQueues

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
        storeOptions: StoreOptions = .init(),
        seedStoreURL: URL? = nil,
        queues: DatabaseQueues = .init(),
        viewContextMergePolicy: MergePolicy = .propertyObjectTrump,
        backgroundMergePolicy: MergePolicy = .propertyStoreTrump,
        loadFailurePolicy: LoadFailurePolicy = .destroyAndRecreate,
        logger: (any DatabaseLogging)? = nil
    ) {
        self.name = name
        self.storage = storage
        self.storeOptions = storeOptions
        self.seedStoreURL = seedStoreURL
        self.queues = queues
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
