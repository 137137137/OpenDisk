import Foundation
import Darwin

// MARK: - Lock-Free Atomic OR Helper

/// Atomically ORs a bit into an Int64 using compare-and-swap loop.
/// This is lock-free and safe for concurrent access from multiple threads.
@inline(__always)
func atomicOr(_ ptr: UnsafeMutablePointer<Int64>, _ bits: Int64) {
    var oldValue = ptr.pointee
    while !OSAtomicCompareAndSwap64(oldValue, oldValue | bits, ptr) {
        oldValue = ptr.pointee
    }
}

// MARK: - Static Lookup Data

/// Pre-computed firmlink name bytes for fast comparison without String allocation.
/// Used by HighPerformanceScanEngine for zero-copy filtering.
enum ScanFilterData {
    static let firmlinkNameBytes: [[UInt8]] = {
        ["Users", "Applications", "Library", "System", "private", "usr", "bin", "sbin", "opt", "Volumes", "cores"]
            .map { Array($0.utf8) }
    }()

    /// Static exclusion prefixes as C strings for memcmp.
    static let excludedPrefixData: [(UnsafePointer<CChar>, Int)] = {
        let prefixes = ["/dev", "/net", "/home", "/private/var/vm", "/Volumes", "/proc"]
        return prefixes.map { str -> (UnsafePointer<CChar>, Int) in
            let len = str.utf8.count
            let ptr = UnsafeMutablePointer<CChar>.allocate(capacity: len + 1)
            _ = str.withCString { memcpy(ptr, $0, len + 1) }
            return (UnsafePointer(ptr), len)
        }
    }()
}
