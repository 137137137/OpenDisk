import Synchronization

/// Reference wrapper for a `Mutex`-guarded value.
///
/// `Mutex` itself is a non-copyable struct, so a shared guarded value —
/// one captured by several escaping worker closures — needs a reference
/// type around it. Keep critical sections short; workers hold this lock
/// only to push results, never across syscalls.
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) {
        mutex = Mutex(value)
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try mutex.withLock(body)
    }
}
