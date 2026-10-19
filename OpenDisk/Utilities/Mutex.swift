import Foundation

/// Lock-protected value with the same API as `Synchronization.Mutex`,
/// which is only available on macOS 15+. Lets the app run on macOS 14.
final class Mutex<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
