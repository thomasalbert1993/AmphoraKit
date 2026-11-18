import CoreData
import Foundation
import Synchronization
import Testing
@testable import AmphoraKit
import AmphoraKitTestSupport

@MainActor
struct BackgroundTaskTests {

    @Test("a task queued behind a blocked one is abandoned by clear and its continuation resumes")
    func abandonedTaskResumes() async throws {
        let (database, logger) = try makeDatabase()
        let started = Gate(), release = Gate()
        let blocked = Task.detached {
            try await database.enqueueBackgroundTask(label: "L") { _ in
                started.open()
                release.wait()
            }
        }
        #expect(started.wait())
        let pending = Task.detached {
            try await database.enqueueBackgroundTask(label: "L") { _ in "ran" }
        }
        try? await Task.sleep(for: .milliseconds(50))

        #expect(throws: DatabaseError.clearTimedOut) { try database.clear(timeout: .milliseconds(100)) }

        // The regression this guards against: a cancelled-before-start operation never resuming.
        let outcome = await withTimeout(seconds: 2) { try await pending.value }
        #expect(throws: DatabaseError.storeCleared) { try outcome.get() }
        #expect(logger.entries.contains { $0.level == .info && $0.message.contains("skipped") })

        release.open()
        try await blocked.value
    }

    @Test("tasks of one label run in order")
    func serialPerLabel() async throws {
        let (database, _) = try makeDatabase()
        let order = Mutex<[Int]>([])
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<10 {
                group.addTask {
                    try await database.enqueueBackgroundTask(label: "serial") { _ in
                        order.withLock { $0.append(index) }
                        usleep(2_000)
                    }
                }
                // Enqueue in order: the group starts its children concurrently.
                try await Task.sleep(for: .milliseconds(5))
            }
            try await group.waitForAll()
        }
        #expect(order.withLock { $0 } == Array(0..<10))
    }

    @Test("priority reorders the queued tasks, never the running one")
    func priority() async throws {
        let (database, _) = try makeDatabase()
        let started = Gate(), release = Gate()
        let order = Mutex<[String]>([])
        let first = Task.detached {
            try await database.enqueueBackgroundTask(label: "P") { _ in
                started.open()
                release.wait()
                order.withLock { $0.append("running") }
            }
        }
        #expect(started.wait())
        let low = Task.detached {
            try await database.enqueueBackgroundTask(label: "P", priority: .low) { _ in order.withLock { $0.append("low") } }
        }
        try? await Task.sleep(for: .milliseconds(50))
        let high = Task.detached {
            try await database.enqueueBackgroundTask(label: "P", priority: .veryHigh) { _ in order.withLock { $0.append("high") } }
        }
        try? await Task.sleep(for: .milliseconds(50))
        release.open()
        try await first.value
        try await low.value
        try await high.value
        #expect(order.withLock { $0 } == ["running", "high", "low"])
    }

    @Test("tasks of different labels run concurrently")
    func concurrentLabels() async throws {
        let (database, _) = try makeDatabase()
        let aStarted = Gate(), bStarted = Gate()
        let overlapped = Mutex((a: false, b: false))
        async let a: Void = database.enqueueBackgroundTask(label: "a") { _ in
            aStarted.open()
            overlapped.withLock { $0.a = bStarted.wait(seconds: 2) }
        }
        async let b: Void = database.enqueueBackgroundTask(label: "b") { _ in
            bStarted.open()
            overlapped.withLock { $0.b = aStarted.wait(seconds: 2) }
        }
        _ = try await (a, b)
        let result = overlapped.withLock { $0 }
        #expect(result.a && result.b)
    }

    @Test("every task gets a fresh context tagged with its database")
    func freshContexts() async throws {
        let (database, _) = try makeDatabase()
        let first = try await database.enqueueBackgroundTask { context in
            #expect(context.database === database)
            return ObjectIdentifier(context.nsContext)
        }
        let second = try await database.enqueueBackgroundTask { context in ObjectIdentifier(context.nsContext) }
        #expect(first != second)
        #expect(database.viewContext.database === database)
    }

    @Test("enqueueBackgroundTaskAndSave saves, enqueueBackgroundTask does not")
    func saving() async throws {
        let (database, _) = try makeDatabase()
        try await database.enqueueBackgroundTask { context in
            let item = TestItem(context: context.nsContext)
            item.id = "unsaved"; item.name = "unsaved"; item.createdAt = .now
        }
        #expect(try await database.itemCount() == 0)
        try await database.seedItems(["saved"])
        #expect(try await database.itemCount() == 1)
    }

    @Test("a failing task propagates its error and logs it")
    func failure() async throws {
        struct Boom: Error { }
        let (database, logger) = try makeDatabase()
        await #expect(throws: Boom.self) {
            try await database.enqueueBackgroundTaskAndSave { _ in throw Boom() }
        }
        #expect(logger.errors.contains { $0.message.contains("background task failed") })
        #expect(throws: Boom.self) { try database.perform { _ in throw Boom() } }
    }

    @Test("an idle queue is pruned")
    func pruning() async throws {
        let (database, _) = try makeDatabase()
        try await database.enqueueBackgroundTask(label: "once") { _ in }
        try await awaitCondition { database.state.withLock { $0.queues["once"] == nil } }
    }
}

/// Runs an operation with a deadline, so that a hanging continuation fails the test.
func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async -> Result<T, any Error> {
    await withTaskGroup(of: Result<T, any Error>.self) { group in
        group.addTask { await Result { try await operation() } }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return .failure(ConditionTimeoutError(timeout: .seconds(seconds)))
        }
        let first = await group.next()!
        group.cancelAll()
        return first
    }
}

extension Result where Failure == any Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
