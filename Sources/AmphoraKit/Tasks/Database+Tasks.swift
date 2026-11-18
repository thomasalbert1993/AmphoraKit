import CoreData

extension Database {

    //-------------------
    // MARK: Background
    //-------------------

    /// Runs a task on the serial queue of a label, on a fresh background context, and saves the
    /// context when it has changes.
    ///
    /// - Parameter label: The queue. Tasks sharing a label run one after the other, tasks of
    ///   different labels concurrently. `nil` for the default queue.
    /// - Parameter priority: Lets a task jump ahead of the queued, not yet started, tasks of its
    ///   label. The running task is never preempted.
    /// - Parameter task: The work, given the context.
    ///
    /// - Throws: `DatabaseError.storeCleared` when the store was cleared after the task was
    ///   queued, `notSetUp`, `storeUnavailable`, or whatever the task or the save throws.
    @discardableResult
    public func enqueueBackgroundTaskAndSave<T: Sendable>(
        label: Label? = nil,
        priority: Operation.QueuePriority = .normal,
        _ task: @escaping @Sendable (DatabaseContext<Schema>) throws -> T
    ) async throws -> T {
        try await enqueue(label: label, priority: priority, save: true, task)
    }

    /// Runs a task on the serial queue of a label, on a fresh background context, without saving.
    /// See `enqueueBackgroundTaskAndSave(label:priority:_:)`.
    public func enqueueBackgroundTask<T: Sendable>(
        label: Label? = nil,
        priority: Operation.QueuePriority = .normal,
        _ task: @escaping @Sendable (DatabaseContext<Schema>) throws -> T
    ) async throws -> T {
        try await enqueue(label: label, priority: priority, save: false, task)
    }


    //-------------------
    // MARK: Synchronous
    //-------------------

    /// Runs a task synchronously on a fresh background context and returns its value.
    public func perform<T>(_ task: @Sendable (DatabaseContext<Schema>) throws -> T) throws -> T {
        do {
            return try run(task, queuedAt: nil, save: false)
        }
        catch {
            log(error, for: "task")
            throw error
        }
    }

    /// Runs a task synchronously on a fresh background context and saves it when it has changes.
    public func performAndSave(_ task: @Sendable (DatabaseContext<Schema>) throws -> Void) throws {
        do {
            try run(task, queuedAt: nil, save: true)
        }
        catch {
            log(error, for: "task")
            throw error
        }
    }


    //-------------------
    // MARK: Private
    //-------------------

    private func enqueue<T: Sendable>(
        label: Label?,
        priority: Operation.QueuePriority,
        save: Bool,
        _ task: @escaping @Sendable (DatabaseContext<Schema>) throws -> T
    ) async throws -> T {
        let label = label ?? Self.defaultLabel
        return try await withCheckedThrowingContinuation { continuation in
            // The epoch capture and the enqueue happen under the same lock as `clear()`'s bump
            // and sweep: an operation is either swept now, or queued for the new store.
            state.withLock { state in
                let epoch = state.storeEpoch
                let operation = DatabaseOperation(
                    work: { [self] in
                        do {
                            continuation.resume(returning: try run(task, queuedAt: epoch, save: save))
                        }
                        catch {
                            log(error, for: "background task")
                            continuation.resume(throwing: error)
                        }
                    },
                    abandon: { [self] in
                        log(DatabaseError.storeCleared, for: "background task")
                        continuation.resume(throwing: DatabaseError.storeCleared)
                    }
                )
                operation.queuePriority = priority
                operation.completionBlock = { [self] in
                    pruneQueueIfIdle(label)
                }
                state.queue(for: label).addOperation(operation)
            }
        }
    }

    private func run<T>(_ task: @Sendable (DatabaseContext<Schema>) throws -> T, queuedAt epoch: Int?, save: Bool) throws -> T {
        try withOpenStore(queuedAt: epoch) {
            let context = newBackgroundContext()
            return try context.nsContext.performAndWait {
                let value = try task(context)
                if save && context.nsContext.hasChanges {
                    try context.nsContext.save()
                }
                return value
            }
        }
    }

    private func pruneQueueIfIdle(_ label: Label) {
        state.withLock { state in
            if let queue = state.queues[label], queue.operationCount == 0 {
                state.queues[label] = nil
            }
        }
    }
}

extension Database.State {

    /// The serial queue of a label, created on first use.
    mutating func queue(for label: Database.Label) -> OperationQueue {
        if let queue = queues[label] {
            return queue
        }
        let queue = OperationQueue()
        queue.name = "AmphoraKit.\(label)"
        queue.maxConcurrentOperationCount = 1
        queues[label] = queue
        return queue
    }
}
