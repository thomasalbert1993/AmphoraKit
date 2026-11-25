import CoreData
import Synchronization

/// A Core Data store with serial background queues, a safe `clear()`, and schema-typed contexts.
///
/// ```swift
/// let database = Database<LibrarySchema>(configuration: .init(name: "Library"))
/// try database.setup()
/// let books = try await database.enqueueBackgroundTask(label: shelfId) { context in
///     try Book.fetch(matching: .shelfId(shelfId), in: context).map(\.title)
/// }
/// ```
///
/// Background work runs on one serial queue per label (`enqueueBackgroundTask(label:…)`), each
/// task on a fresh background context. `clear()` destroys and recreates the store without ever
/// pulling it from under a running task: tasks queued before the call are abandoned with
/// `DatabaseError.storeCleared`, running ones are waited for, and the rest of the app is told
/// through `didClearNotification`, delivered synchronously on the main actor.
///
public final class Database<Schema: DatabaseSchema>: Sendable {

    /// The configuration the database was created with.
    public let configuration: DatabaseConfiguration

    /// The persistent container. Prefer the typed contexts; this is the escape hatch.
    public let persistentContainer: NSPersistentContainer

    /// The name of a background queue.
    public typealias Label = String

    /// Posted on the main actor at the end of `clear()`, after `didClear`, with the database as
    /// object. Observers registered with `queue: nil` run before `clear()` returns.
    public static var didClearNotification: Notification.Name {
        Notification.Name("AmphoraKit.Database.didClear")
    }

    public init(configuration: DatabaseConfiguration) {
        self.configuration = configuration
        self.persistentContainer = NSPersistentContainer(name: configuration.name, managedObjectModel: Schema.model)

        let description = persistentContainer.persistentStoreDescriptions.first ?? NSPersistentStoreDescription()
        switch configuration.storage {
            case .persistent(let url?):
                description.url = url
            case .persistent(nil):
                break
            case .ephemeral:
                description.url = URL(fileURLWithPath: "/dev/null")
        }
        description.shouldAddStoreAsynchronously = false
        for (key, value) in configuration.storeOptions.dictionary {
            description.setOption(value, forKey: key)
        }
        persistentContainer.persistentStoreDescriptions = [description]
    }

    /// The description the store is opened with — URL, type and `storeOptions` — kept when it
    /// is recreated. Hand it to what needs it, such as `NSCoreDataCoreSpotlightDelegate`.
    public var storeDescription: NSPersistentStoreDescription {
        persistentContainer.persistentStoreDescriptions[0]
    }


    //-------------------
    // MARK: Setup
    //-------------------

    /// Opens the store. Idempotent: a second call returns `.loaded` and does nothing.
    ///
    /// - Throws: The load error when `loadFailurePolicy` is `.propagate`, or the recreation error
    ///   when `.destroyAndRecreate` fails too; the database is then `notSetUp`.
    @MainActor
    @discardableResult
    public func setup() throws -> SetupOutcome {
        if state.withLock({ $0.isSetup }) {
            return .loaded
        }

        if let storeURL = seedableStoreURL, !FileManager.default.fileExists(atPath: storeURL.path) {
            seedStore(at: storeURL)
        }

        nonisolated(unsafe) var loadError: (any Error)?
        persistentContainer.loadPersistentStores { _, error in
            loadError = error
        }

        var outcome = SetupOutcome.loaded
        if let loadError {
            switch configuration.loadFailurePolicy {
                case .propagate:
                    configuration.logger?.error("Failed to open the store", loadError)
                    throw loadError
                case .destroyAndRecreate:
                    configuration.logger?.error("Failed to open the store, destroying and recreating it", loadError)
                    try destroyAndRecreateStore()
                    outcome = .recreatedAfterLoadFailure
            }
        }

        let viewContext = persistentContainer.viewContext
        viewContext.mergePolicy = configuration.viewContextMergePolicy.nsMergePolicy
        viewContext.automaticallyMergesChangesFromParent = true
        tag(viewContext)

        state.withLock { $0.isSetup = true }
        return outcome
    }

    /// Whether `setup()` succeeded.
    public var isSetUp: Bool {
        state.withLock { $0.isSetup }
    }

    /// The main-queue context.
    public var viewContext: DatabaseContext<Schema> {
        DatabaseContext(persistentContainer.viewContext)
    }


    //-------------------
    // MARK: Clearing
    //-------------------

    /// Destroys the store file and recreates an empty one.
    ///
    /// Sequence: `willClear` → the queued tasks are abandoned (`storeCleared`) → the running
    /// tasks are waited for, up to `timeout` → the view context is reset, the store destroyed and
    /// recreated → `didClear` → `didClearNotification`, delivered synchronously to observers
    /// registered without a queue.
    ///
    /// - Throws: `DatabaseError.clearTimedOut` when running tasks didn't finish in time — the store
    ///   is left intact, the abandoned tasks stay abandoned — or the error of the store recreation,
    ///   after which the database reports `storeUnavailable` until recreated.
    ///
    /// - Important: Never call it from inside a database task: the task holds the store open and
    ///   `clear()` would wait for it.
    @MainActor
    public func clear(timeout: Duration = .seconds(10)) throws {
        configuration.willClear?()

        let operations: [Operation] = try state.withLock { state in
            guard state.isSetup else { throw DatabaseError.notSetUp }
            state.storeEpoch += 1
            defer { state.operations.removeAll() }
            return Array(state.operations.values)
        }
        // Pending operations resume their continuation with `storeCleared`; running ones finish.
        // Only this database's: the queues may be shared with other databases.
        for operation in operations {
            operation.cancel()
        }

        clearLock.lock()
        defer { clearLock.unlock() }

        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        guard storeGate.wait(timeout: .now() + seconds) == .success else {
            configuration.logger?.error("Clearing the database timed out after \(seconds) s: the store is left as is")
            throw DatabaseError.clearTimedOut
        }

        persistentContainer.viewContext.reset()
        do {
            try destroyAndRecreateStore()
        }
        catch {
            // The coordinator is left without a store: tasks fail with `storeUnavailable`
            // rather than aborting the process.
            configuration.logger?.error("Failed to destroy and recreate the store", error)
            throw error
        }

        configuration.didClear?()
        NotificationCenter.default.post(name: Self.didClearNotification, object: self)
    }


    //-------------------
    // MARK: Store lifetime
    //-------------------

    /// The epoch of the loaded store, incremented by every `clear()`.
    ///
    /// Capture it when queueing work and hand it to `withOpenStore(queuedAt:_:)`, so that work
    /// queued for a store that no longer exists is skipped.
    public var currentStoreEpoch: Int {
        state.withLock { $0.storeEpoch }
    }

    /// Runs work while holding the store open: `clear()` cannot destroy the store underneath it.
    ///
    /// - Parameter epoch: The epoch at the time the work was queued, `nil` for synchronous work.
    /// - Throws: `notSetUp`, `storeCleared` when the epoch is stale, `storeUnavailable` when no
    ///   store is loaded, or whatever `work` throws.
    public func withOpenStore<T>(queuedAt epoch: Int? = nil, _ work: () throws -> T) throws -> T {
        // Entering the gate is atomic with the checks, and blocks while a clear is in progress:
        // work queued during a clear runs on the new store once it exists.
        clearLock.lock()
        do {
            try state.withLock { state in
                guard state.isSetup else { throw DatabaseError.notSetUp }
                if let epoch, epoch != state.storeEpoch { throw DatabaseError.storeCleared }
                guard !persistentContainer.persistentStoreCoordinator.persistentStores.isEmpty else {
                    throw DatabaseError.storeUnavailable
                }
                storeGate.enter()
            }
        }
        catch {
            clearLock.unlock()
            throw error
        }
        clearLock.unlock()
        defer { storeGate.leave() }
        return try work()
    }


    //-------------------
    // MARK: Exporting
    //-------------------

    /// Writes a copy of the store to a single SQLite file — no `-wal` or `-shm` beside it — ready
    /// to be bundled as a `seedStoreURL`. The open store is left untouched, and the copy includes
    /// what is saved, the write-ahead log included; unsaved changes of the contexts are not.
    ///
    /// - Parameter destinationURL: The file to write, replaced when it exists.
    /// - Throws: `notSetUp`, `storeUnavailable` (no store, or an `.ephemeral` one), or the copy error.
    public func exportStore(to destinationURL: URL) throws {
        guard case .persistent = configuration.storage else {
            throw DatabaseError.storeUnavailable
        }
        try withOpenStore {
            guard let storeURL = persistentContainer.persistentStoreCoordinator.persistentStores.first?.url else {
                throw DatabaseError.storeUnavailable
            }
            // The store opened read-only by a coordinator of its own, then migrated to the
            // destination: the open store is never removed nor added back. Migrating, unlike
            // `replacePersistentStore`, leaves no write-ahead log beside the copy.
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: persistentContainer.managedObjectModel)
            var sourceOptions: [String: Any] = configuration.storeOptions.dictionary
            sourceOptions[NSReadOnlyPersistentStoreOption] = true
            let source = try coordinator.addPersistentStore(type: .sqlite, at: storeURL, options: sourceOptions)

            var destinationOptions: [String: Any] = configuration.storeOptions.dictionary
            destinationOptions[NSSQLitePragmasOption] = configuration.storeOptions.sqlitePragmas.merging(["journal_mode": "DELETE"]) { $1 }
            try Self.removeStoreFiles(at: destinationURL)
            try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let copy = try coordinator.migratePersistentStore(source, to: destinationURL, options: destinationOptions, type: .sqlite)
            try coordinator.remove(copy)
        }
    }

    /// Removes a SQLite store file and its `-wal` and `-shm` files, those that exist.
    private static func removeStoreFiles(at url: URL) throws {
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }


    //-------------------
    // MARK: Internal
    //-------------------

    struct State {
        var isSetup = false
        var storeEpoch = 0
        /// The queued operations of this database, until they finish: what `clear()` cancels.
        var operations: [ObjectIdentifier: Operation] = [:]
    }

    let state = Mutex(State())

    /// Held by `clear()` while the store is being replaced; taken briefly by every task to enter
    /// the gate, so no task starts on a store about to disappear.
    let clearLock = NSLock()

    /// Counts the tasks holding the store open; `clear()` waits for it to drain.
    let storeGate = DispatchGroup()

    static var defaultLabel: Label { "amphorakit.default" }

    /// A fresh background context, tagged with its database.
    func newBackgroundContext() -> DatabaseContext<Schema> {
        let context = persistentContainer.newBackgroundContext()
        context.mergePolicy = configuration.backgroundMergePolicy.nsMergePolicy
        tag(context)
        return DatabaseContext(context)
    }

    /// Merges the object IDs of a batch request into the view context, on the main queue, unless
    /// the store was cleared since.
    func mergeIntoViewContext(_ changes: [String: [NSManagedObjectID]], queuedAt epoch: Int) {
        DispatchQueue.main.async { [self] in
            _ = try? withOpenStore(queuedAt: epoch) {
                NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [persistentContainer.viewContext])
            }
        }
    }

    /// Logs a task failure, stale work at info level.
    func log(_ error: any Error, for taskDescription: String) {
        guard let logger = configuration.logger else { return }
        switch error {
            case DatabaseError.storeCleared:
                logger.info("Database \(taskDescription) skipped: the store was cleared")
            case DatabaseError.storeUnavailable:
                logger.error("Database \(taskDescription) skipped: no store is loaded", nil)
            default:
                logger.error("Database \(taskDescription) failed\(Self.validationDetails(of: error))", error)
        }
    }

    private func tag(_ context: NSManagedObjectContext) {
        context.userInfo[DatabaseBox.userInfoKey] = DatabaseBox(self)
    }

    /// Destroys the store and adds it back from its description, so that its type and options
    /// survive, seeded again when a seed is configured.
    private func destroyAndRecreateStore() throws {
        let coordinator = persistentContainer.persistentStoreCoordinator
        let description = storeDescription
        guard let storeURL = coordinator.persistentStores.first?.url ?? description.url else {
            throw DatabaseError.storeUnavailable
        }
        try coordinator.destroyPersistentStore(at: storeURL, type: NSPersistentStore.StoreType(rawValue: description.type))

        if seedableStoreURL != nil {
            seedStore(at: storeURL)
        }

        // `shouldAddStoreAsynchronously` is off: the handler runs before `addPersistentStore` returns
        nonisolated(unsafe) var addError: (any Error)?
        coordinator.addPersistentStore(with: description) { _, error in
            addError = error
        }
        if let addError {
            throw addError
        }
    }

    /// The store URL when a seed applies to it: a seed is configured and the store is a file.
    private var seedableStoreURL: URL? {
        guard configuration.seedStoreURL != nil, case .persistent = configuration.storage else {
            return nil
        }
        return storeDescription.url
    }

    /// Copies the seed store, with its `-wal` and `-shm` files, to the store URL. A failure is
    /// logged and leaves no partial copy: the store then opens empty.
    private func seedStore(at storeURL: URL) {
        guard let seedURL = configuration.seedStoreURL else { return }
        let fileManager = FileManager.default
        let suffixes = ["", "-wal", "-shm"]
        let destinations = suffixes.map { URL(fileURLWithPath: storeURL.path + $0) }
        do {
            try fileManager.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            for (suffix, destination) in zip(suffixes, destinations) {
                let source = URL(fileURLWithPath: seedURL.path + suffix)
                // the seed's own file is required, its journal files only copied when present
                guard suffix.isEmpty || fileManager.fileExists(atPath: source.path) else { continue }
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: source, to: destination)
            }
            configuration.logger?.info("Store seeded from \(seedURL.lastPathComponent)")
        }
        catch {
            for destination in destinations {
                try? fileManager.removeItem(at: destination)
            }
            configuration.logger?.error("Failed to seed the store from \(seedURL.path), it opens empty", error)
        }
    }

    /// What a Core Data validation error is about: the entity and identifier of each underlying
    /// error with its message, "Multiple validation errors occurred" saying nothing by itself.
    private static func validationDetails(of error: any Error) -> String {
        let underlying = ((error as NSError).userInfo[NSDetailedErrorsKey] as? [Any])?.compactMap { $0 as? NSError } ?? []
        guard !underlying.isEmpty else { return "" }
        let details = underlying.map { detail -> String in
            let object = detail.userInfo[NSValidationObjectErrorKey] as? NSManagedObject
            let entity = object?.entity.name ?? "?"
            let id = (object as? any IdentifiableDatabaseObject).map { String(describing: $0.id) }
                ?? object?.objectID.uriRepresentation().lastPathComponent
                ?? "?"
            return "\(entity)/\(id): \(detail.localizedDescription)"
        }
        return " — " + details.joined(separator: "; ")
    }
}
