import CoreData

/// Live results of a fetch request on the view context, with coalesced change notifications.
///
/// A burst of changes (a sync, a batch) becomes a leading call, emitted at once, followed by a
/// single trailing call at the end of `coalescingInterval`: the UI reacts instantly to isolated
/// changes without redundant work when many merges arrive in quick succession. An interval of `0`
/// emits synchronously on every change.
///
/// When the database is cleared, the controller refetches synchronously, inside `clear()`, so it
/// never holds objects of a destroyed store.
///
/// A controller serves a collection, a predicate, or a value computed from several objects. A
/// view displaying one object observes that object instead: `NSManagedObject` publishes on every
/// change of its row, background merges included.
///
@MainActor
public final class FetchController<T: DatabaseObject>: NSObject, NSFetchedResultsControllerDelegate {

    /// The fetch request.
    public let request: NSFetchRequest<T>

    /// When `true`, the controller loads no object in memory and only reports that something changed.
    public let notifyChangesOnly: Bool

    /// The current objects, zombies excluded; empty when `notifyChangesOnly`.
    public var results: [T] {
        guard !notifyChangesOnly else { return [] }
        return (fetchedResultsController.fetchedObjects ?? []).removingZombies()
    }

    /// Creates a controller on the database's view context and performs the first fetch.
    ///
    /// - Parameter coalescingInterval: The window in seconds within which changes are coalesced,
    ///   `0` to emit synchronously.
    public init(_ request: NSFetchRequest<T>, in database: Database<T.Schema>, notifyChangesOnly: Bool = false, coalescingInterval: TimeInterval = 0.1) {
        let request = notifyChangesOnly ? (request.copy() as! NSFetchRequest<T>) : request
        if notifyChangesOnly {
            request.returnsObjectsAsFaults = true
            request.fetchBatchSize = 0
        }
        self.request = request
        self.notifyChangesOnly = notifyChangesOnly
        self.coalescingInterval = coalescingInterval
        self.fetchedResultsController = NSFetchedResultsController(
            fetchRequest: request,
            managedObjectContext: database.persistentContainer.viewContext,
            sectionNameKeyPath: nil,
            cacheName: nil
        )
        super.init()

        fetchedResultsController.delegate = self
        try? fetchedResultsController.performFetch()

        // Delivered synchronously: `clear()` posts from the main actor, and the stale objects must
        // be dropped before the next save runs its change processing on them.
        clearObservation = NotificationCenter.default.addObserver(
            forName: Database<T.Schema>.didClearNotification,
            object: database,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refetch()
            }
        }
    }

    /// Creates a controller for the objects matching every query, sorted.
    public convenience init(matching queries: [T.Query] = [], sortedBy sorts: [T.Sort] = [], in database: Database<T.Schema>, notifyChangesOnly: Bool = false, coalescingInterval: TimeInterval = 0.1) {
        self.init(T.baseFetchRequest(matching: queries, sortedBy: sorts), in: database, notifyChangesOnly: notifyChangesOnly, coalescingInterval: coalescingInterval)
    }

    /// Creates a controller for the objects matching the query, sorted.
    public convenience init(matching query: T.Query, sortedBy sorts: [T.Sort] = [], in database: Database<T.Schema>, notifyChangesOnly: Bool = false, coalescingInterval: TimeInterval = 0.1) {
        self.init(matching: [query], sortedBy: sorts, in: database, notifyChangesOnly: notifyChangesOnly, coalescingInterval: coalescingInterval)
    }

    deinit {
        if let clearObservation {
            NotificationCenter.default.removeObserver(clearObservation)
        }
    }

    /// Sets the handler called with the results when they change. The initial fetch doesn't call it.
    public func onChange(_ handler: @escaping @MainActor ([T]) -> Void) {
        changeHandler = handler
    }

    /// Re-runs the fetch and notifies the handler with the fresh results, now.
    ///
    /// An `NSFetchedResultsController` only re-evaluates its predicate for the objects of its own
    /// entity that changed: a request filtering on a related object's attribute keeps stale results
    /// when that related object changes. Observers of the related entity call this to realign.
    public func refetch() {
        try? fetchedResultsController.performFetch()
        pendingEmission?.cancel()
        emitChange()
    }


    //-------------------
    // MARK: Private
    //-------------------

    private let fetchedResultsController: NSFetchedResultsController<T>
    private let coalescingInterval: TimeInterval
    private var changeHandler: (@MainActor ([T]) -> Void)?
    private var pendingEmission: Task<Void, Never>?
    private var lastEmitDate: Date?
    nonisolated(unsafe) private var clearObservation: (any NSObjectProtocol)?

    fileprivate func scheduleChangeNotification() {
        guard coalescingInterval > 0 else {
            emitChange()
            return
        }
        let now = Date()
        if let lastEmitDate, now.timeIntervalSince(lastEmitDate) < coalescingInterval {
            // Within the window: (re)schedule a single trailing emission.
            pendingEmission?.cancel()
            let remaining = coalescingInterval - now.timeIntervalSince(lastEmitDate)
            pendingEmission = Task { [weak self] in
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled else { return }
                self?.emitChange()
            }
        } else {
            emitChange()
        }
    }

    private func emitChange() {
        pendingEmission = nil
        lastEmitDate = .now
        changeHandler?(results)
    }


    //--------------------------------------------
    // MARK: <NSFetchedResultsControllerDelegate>
    //--------------------------------------------

    /// Called on the view context's queue, the main queue.
    nonisolated public func controllerDidChangeContent(_ controller: NSFetchedResultsController<any NSFetchRequestResult>) {
        MainActor.assumeIsolated {
            scheduleChangeNotification()
        }
    }
}
