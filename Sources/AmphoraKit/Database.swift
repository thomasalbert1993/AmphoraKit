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
        persistentContainer.persistentStoreDescriptions = [description]
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

        let queues: [OperationQueue] = try state.withLock { state in
            guard state.isSetup else { throw DatabaseError.notSetUp }
            state.storeEpoch += 1
            defer { state.queues.removeAll() }
            return Array(state.queues.values)
        }
        // Pending operations resume their continuation with `storeCleared`; running ones finish.
        for queue in queues {
            queue.cancelAllOperations()
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
    // MARK: Internal
    //-------------------

    struct State {
        var isSetup = false
        var storeEpoch = 0
        var queues: [Label: OperationQueue] = [:]
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
        context.userInfo[DatabaseReference.userInfoKey] = DatabaseReference(self)
    }

    private func destroyAndRecreateStore() throws {
        let coordinator = persistentContainer.persistentStoreCoordinator
        guard let storeURL = coordinator.persistentStores.first?.url ?? persistentContainer.persistentStoreDescriptions.first?.url else {
            throw DatabaseError.storeUnavailable
        }
        try coordinator.destroyPersistentStore(at: storeURL, type: .sqlite)
        let options: [String: Any] = [
            NSMigratePersistentStoresAutomaticallyOption: true,
            NSInferMappingModelAutomaticallyOption: true
        ]
        _ = try coordinator.addPersistentStore(type: .sqlite, at: storeURL, options: options)
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
