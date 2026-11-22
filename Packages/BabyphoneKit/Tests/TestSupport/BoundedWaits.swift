import BabyphoneCore
import Foundation

// Every wait in the tests goes through this file and has a deadline. A test that
// waits for something that never comes must fail in seconds, not hold the run.

/// A value protected by a lock, for state shared between a test and the code it drives.
public final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) { self.value = value }

    public func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    public var current: Value { withLock { $0 } }
}

/// Polls `condition` until it holds. Returns false if `timeout` passes first.
public func eventually(within timeout: Duration = .seconds(10), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// Runs `operation` and returns its result, or nil if it has not finished within `timeout`.
/// The caller never waits longer, whatever the operation does.
public func value<Value: Sendable>(
    within timeout: Duration = .seconds(10),
    of operation: @escaping @Sendable () async -> Value
) async -> Value? {
    let result = Locked<Value?>(nil)
    let task = Task {
        let value = await operation()
        result.withLock { $0 = value }
    }
    _ = await eventually(within: timeout) { result.withLock { $0 != nil } }
    task.cancel()
    return result.current
}

/// Whether `operation` finishes within `timeout`.
public func finishes(
    within timeout: Duration = .seconds(10),
    _ operation: @escaping @Sendable () async -> Void
) async -> Bool {
    await value(within: timeout) {
        await operation()
        return true
    } ?? false
}

/// The next element of `stream`, or nil if none arrives within `timeout`.
public func next<Element: Sendable>(of stream: AsyncStream<Element>, within timeout: Duration = .seconds(10)) async -> Element? {
    await value(within: timeout) {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    } ?? nil
}

/// Collects the values of an async stream so a test can wait for a particular one.
public final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let values = Locked([Value]())
    private let task: Task<Void, Never>

    public init(_ stream: AsyncStream<Value>) {
        let values = values
        task = Task {
            for await value in stream {
                values.withLock { $0.append(value) }
            }
        }
    }

    deinit { task.cancel() }

    public var all: [Value] { values.current }

    /// Waits until a value satisfying `predicate` has been seen. Returns false on timeout.
    public func waitFor(timeout: Duration = .seconds(10), _ predicate: @Sendable (Value) -> Bool) async -> Bool {
        await eventually(within: timeout) { all.contains(where: predicate) }
    }

    /// Waits until `count` values satisfying `predicate` have been seen. Returns false on timeout.
    public func waitForCount(_ count: Int, timeout: Duration = .seconds(10), _ predicate: @Sendable (Value) -> Bool) async -> Bool {
        await eventually(within: timeout) { all.filter(predicate).count >= count }
    }

    /// Waits until the most recent value satisfies `predicate`. Returns false on timeout.
    public func waitForLatest(timeout: Duration = .seconds(10), _ predicate: @Sendable (Value) -> Bool) async -> Bool {
        await eventually(within: timeout) { all.last.map(predicate) ?? false }
    }
}

/// A rendezvous provider that keeps records in memory.
public final class MemoryRendezvous: RendezvousProvider, @unchecked Sendable {
    public let records = Locked([String: Data]())
    public let publishCount = Locked(0)
    private let status = Locked(RendezvousAvailability.available)

    public init() {}

    public var currentAvailability: RendezvousAvailability {
        get { status.current }
        set { status.withLock { $0 = newValue } }
    }

    public func availability() async -> RendezvousAvailability { currentAvailability }

    public func publish(_ record: Data, to slot: RendezvousSlot) async throws {
        records.withLock { $0[slot.name] = record }
        publishCount.withLock { $0 += 1 }
    }

    public func fetch(_ slot: RendezvousSlot) async throws -> Data? {
        records.current[slot.name]
    }
}
