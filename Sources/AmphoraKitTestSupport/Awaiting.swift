import Foundation

/// The error `awaitCondition(timeout:_:)` throws when the condition never held.
public struct ConditionTimeoutError: Error, CustomStringConvertible, Sendable {

    public let timeout: Duration

    public init(timeout: Duration) {
        self.timeout = timeout
    }

    public var description: String {
        "The condition did not hold within \(timeout)"
    }
}

/// Polls a condition on the main actor every 10 ms until it holds.
///
/// - Throws: `ConditionTimeoutError` when the timeout elapses first.
@MainActor
public func awaitCondition(timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else {
            throw ConditionTimeoutError(timeout: timeout)
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Runs the main run loop once per iteration, so that work dispatched to the main queue, such
/// as the view context merging a background save, gets processed.
@MainActor
public func spinMainRunLoop(times: Int = 1) {
    for _ in 0..<times {
        RunLoop.main.run(until: Date())
    }
}
