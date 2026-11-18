import Foundation
import Synchronization

/// A queued database task that resumes its continuation exactly once.
///
/// `BlockOperation` never runs its block when cancelled before starting, which would leave the
/// awaiting continuation hanging. This operation decides atomically between running `work` and
/// `abandon`: a cancellation that arrives before `main()` abandons, one that arrives after is
/// ignored and the work completes.
final class DatabaseOperation: Operation, @unchecked Sendable {

    private enum Phase {
        case pending, running, abandoned
    }

    private let phase = Mutex(Phase.pending)
    private let work: @Sendable () -> Void
    private let abandon: @Sendable () -> Void

    /// - Parameter work: Runs the task and resumes its continuation.
    /// - Parameter abandon: Resumes the continuation with `DatabaseError.storeCleared`.
    init(work: @escaping @Sendable () -> Void, abandon: @escaping @Sendable () -> Void) {
        self.work = work
        self.abandon = abandon
    }

    override func main() {
        let runs = phase.withLock { phase -> Bool in
            guard phase == .pending else { return false }
            phase = .running
            return true
        }
        if runs {
            work()
        }
    }

    override func cancel() {
        super.cancel()
        let abandons = phase.withLock { phase -> Bool in
            guard phase == .pending else { return false }
            phase = .abandoned
            return true
        }
        if abandons {
            abandon()
        }
    }
}
