import os.lock

/// A value guarded by an unfair lock, shareable across escaping worker
/// closures.
///
/// Backed by `OSAllocatedUnfairLock`, the cheapest blocking primitive on
/// Darwin (same class as `Mutex`). Keep critical sections short; scan
/// workers hold these locks only to push results, never across syscalls.
///
/// - Important: Thread-safety: access to `value` only ever happens inside
///   `withLock`, which serializes all readers and writers.
final class Locked<Value>: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    init(_ value: Value) {
        lock = OSAllocatedUnfairLock(uncheckedState: value)
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLockUnchecked(body)
    }
}
