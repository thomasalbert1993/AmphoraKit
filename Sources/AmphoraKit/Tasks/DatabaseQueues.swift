import Foundation
import Synchronization

/// The serial queues of background tasks, by label.
///
/// Each database gets its own registry by default. Databases given the same instance share their
/// labels: a task of one never runs alongside a task of the other on the same label, which keeps
/// writes to related stores in order.
///
/// ```swift
/// let queues = DatabaseQueues()
/// let main = Database<MainSchema>(configuration: .init(name: "Main", queues: queues))
/// let assets = Database<AssetsSchema>(configuration: .init(name: "Assets", queues: queues))
/// ```
public final class DatabaseQueues: Sendable {

    private let queues = Mutex<[String: OperationQueue]>([:])

    public init() {}


    //-------------------
    // MARK: Internal
    //-------------------

    /// Adds an operation to the serial queue of a label, created on first use.
    func add(_ operation: Operation, label: String) {
        queues.withLock { queues in
            let queue: OperationQueue
            if let existing = queues[label] {
                queue = existing
            }
            else {
                queue = OperationQueue()
                queue.name = "AmphoraKit.\(label)"
                queue.maxConcurrentOperationCount = 1
                queues[label] = queue
            }
            queue.addOperation(operation)
        }
    }

    /// Drops the queue of a label once it has no operation left.
    func pruneIfIdle(_ label: String) {
        queues.withLock { queues in
            if let queue = queues[label], queue.operationCount == 0 {
                queues[label] = nil
            }
        }
    }

    /// The labels that currently have a queue.
    var labels: Set<String> {
        queues.withLock { Set($0.keys) }
    }
}
