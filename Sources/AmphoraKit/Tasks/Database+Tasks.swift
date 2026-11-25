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


    /// Runs a task now on a fresh background context, outside the label queues: concurrently
    /// with every other task, queued or not. Meant for reads — writes belong to a label, so that
    /// they stay in order.
    ///
    /// `clear()` doesn't abandon it but waits for it, like for a running task; one started after
    /// `clear()` was called throws `DatabaseError.storeCleared`.
    ///
    /// - Throws: `DatabaseError.storeCleared`, `notSetUp`, `storeUnavailable`, or whatever the
    ///   task throws.
    public func performInBackground<T: Sendable>(
        qos: DispatchQoS.QoSClass = .userInitiated,
        _ task: @escaping @Sendable (DatabaseContext<Schema>) throws -> T
    ) async throws -> T {
        let epoch = currentStoreEpoch
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: qos).async { [self] in
                do {
                    continuation.resume(returning: try run(task, queuedAt: epoch, save: false))
                }
                catch {
                    log(error, for: "background task")
                    continuation.resume(throwing: error)
                }
            }
        }
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
                let operationID = ObjectIdentifier(operation)
                operation.completionBlock = { [self] in
                    self.state.withLock { _ = $0.operations.removeValue(forKey: operationID) }
                    configuration.queues.pruneIfIdle(label)
                }
                state.operations[operationID] = operation
                configuration.queues.add(operation, label: label)
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
}
