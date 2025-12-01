import Foundation
import Darwin

@inline(__always)
func atomicOr(_ ptr: UnsafeMutablePointer<Int64>, _ bits: Int64) {
    var oldValue = ptr.pointee
    while !OSAtomicCompareAndSwap64(oldValue, oldValue | bits, ptr) {
        oldValue = ptr.pointee
    }
}

enum ScanFilterData {
    static let firmlinkNameBytes: [[UInt8]] = {
        ["Users", "Applications", "Library", "System", "private", "usr", "bin", "sbin", "opt", "Volumes", "cores"]
            .map { Array($0.utf8) }
    }()

    static let excludedPrefixData: [(UnsafePointer<CChar>, Int)] = {
        let prefixes = ["/dev", "/net", "/home", "/private/var/vm", "/proc"]
        return prefixes.map { str -> (UnsafePointer<CChar>, Int) in
            let len = str.utf8.count
            let ptr = UnsafeMutablePointer<CChar>.allocate(capacity: len + 1)
            _ = str.withCString { memcpy(ptr, $0, len + 1) }
            return (UnsafePointer(ptr), len)
        }
    }()
}
