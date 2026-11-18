import Foundation

/// Where a `Database` reports what it does and what fails.
///
/// Implement it over your logging stack; without a logger the database stays silent.
public protocol DatabaseLogging: Sendable {

    /// An informational message: a skipped stale task, a store recreated.
    func info(_ message: String)

    /// A failure, with the underlying error when there is one.
    func error(_ message: String, _ error: (any Error)?)
}

extension DatabaseLogging {

    func error(_ message: String) {
        error(message, nil)
    }
}
