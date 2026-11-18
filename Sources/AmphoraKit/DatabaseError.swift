import Foundation

/// The errors a `Database` reports on its own.
public enum DatabaseError: Error, Equatable, Sendable {

    /// `setup()` hasn't run, or failed with `LoadFailurePolicy.propagate`.
    case notSetUp

    /// The store was destroyed and recreated (`clear()`) after the task was queued: the task
    /// is stale and its work no longer applies.
    case storeCleared

    /// No store is loaded: it failed to open or to be recreated.
    case storeUnavailable

    /// `clear()` waited for the running tasks longer than its timeout. The store is intact; the
    /// tasks queued before the call stay cancelled.
    case clearTimedOut

    /// `fetch(id:)` found no object with the identifier.
    case notFound(entity: String, id: String)
}
