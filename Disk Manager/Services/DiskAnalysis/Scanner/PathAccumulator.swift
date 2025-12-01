import Foundation

// MARK: - Zero-Copy Path Accumulator

/// Builds paths using a single contiguous buffer with zero String allocation in hot loop.
/// Only creates Swift Strings at the very end when building HyperScanItems.
/// This eliminates the massive overhead of String interpolation for every file.
///
/// ## Thread Safety
/// This class is NOT thread-safe and should be used on a single thread only.
/// Each scanning task should have its own PathAccumulator instance.
///
/// ## Performance
/// - Zero-copy path building using C strings
/// - Deferred String creation (only when needed)
/// - Stack-based segment tracking for push/pop operations
/// - Automatic buffer growth when needed
final class PathAccumulator {
    // Main path buffer - grows as needed
    private var pathBuffer: UnsafeMutablePointer<CChar>
    private var pathCapacity: Int
    private var pathLength: Int = 0

    // Name accumulation buffer for deferred String creation
    private var nameBuffer: UnsafeMutablePointer<CChar>
    private var nameCapacity: Int
    private var nameLength: Int = 0

    // Stack of path segment lengths for push/pop
    private var segmentStack: [Int] = []

    init(initialCapacity: Int = 8192) {
        self.pathCapacity = initialCapacity
        self.pathBuffer = .allocate(capacity: initialCapacity)
        self.nameCapacity = 4096
        self.nameBuffer = .allocate(capacity: 4096)
        segmentStack.reserveCapacity(64)
    }

    deinit {
        pathBuffer.deallocate()
        nameBuffer.deallocate()
    }

    /// Initialize with root path (call once at start of scan)
    @inline(__always)
    func setRoot(_ path: String) {
        path.withCString { cstr in
            let len = strlen(cstr)
            ensurePathCapacity(Int(len) + 1)
            memcpy(pathBuffer, cstr, len)
            pathLength = Int(len)
            pathBuffer[pathLength] = 0
        }
        segmentStack.removeAll(keepingCapacity: true)
    }

    /// Push a path segment (used when entering a directory)
    @inline(__always)
    func push(name: UnsafeRawPointer, nameLen: Int) {
        segmentStack.append(pathLength)

        // Ensure capacity for "/" + name + null
        ensurePathCapacity(pathLength + 1 + nameLen + 1)

        // Add separator if not root
        if pathLength > 0 && pathBuffer[pathLength - 1] != 0x2F {
            pathBuffer[pathLength] = 0x2F // '/'
            pathLength += 1
        }

        // Copy name
        memcpy(pathBuffer.advanced(by: pathLength), name, nameLen)
        pathLength += nameLen
        pathBuffer[pathLength] = 0
    }

    /// Pop back to parent directory
    @inline(__always)
    func pop() {
        if let prevLen = segmentStack.popLast() {
            pathLength = prevLen
            pathBuffer[pathLength] = 0
        }
    }

    /// Get current path as C string pointer and length (zero-copy)
    @inline(__always)
    func currentPath() -> (UnsafePointer<CChar>, Int) {
        return (UnsafePointer(pathBuffer), pathLength)
    }

    /// Build a child path WITHOUT modifying the accumulator state (for files)
    /// Returns the path as a Swift String - this is the ONLY place we allocate Strings
    @inline(__always)
    func buildChildPath(name: UnsafeRawPointer, nameLen: Int) -> String {
        // Ensure name buffer capacity
        if nameLen + pathLength + 2 > nameCapacity {
            let newCapacity = max(nameCapacity * 2, nameLen + pathLength + 256)
            let newBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: newCapacity)
            nameBuffer.deallocate()
            nameBuffer = newBuffer
            nameCapacity = newCapacity
        }

        // Build path in name buffer: currentPath + "/" + name
        var pos = 0
        memcpy(nameBuffer, pathBuffer, pathLength)
        pos = pathLength

        if pos > 0 && nameBuffer[pos - 1] != 0x2F {
            nameBuffer[pos] = 0x2F
            pos += 1
        }

        memcpy(nameBuffer.advanced(by: pos), name, nameLen)
        pos += nameLen
        nameBuffer[pos] = 0

        return String(cString: nameBuffer)
    }

    /// Get current path as Swift String
    @inline(__always)
    func currentPathString() -> String {
        return String(cString: pathBuffer)
    }

    /// Ensure path buffer has enough capacity
    @inline(__always)
    private func ensurePathCapacity(_ needed: Int) {
        if needed > pathCapacity {
            let newCapacity = max(pathCapacity * 2, needed + 1024)
            let newBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: newCapacity)
            memcpy(newBuffer, pathBuffer, pathLength)
            pathBuffer.deallocate()
            pathBuffer = newBuffer
            pathCapacity = newCapacity
        }
    }

    /// Create a name String from raw bytes (deferred allocation)
    @inline(__always)
    static func nameString(from ptr: UnsafeRawPointer, length: Int) -> String {
        return String(decoding: UnsafeRawBufferPointer(start: ptr, count: length), as: UTF8.self)
    }
}
