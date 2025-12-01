import Foundation

final class PathAccumulator {
    private var pathBuffer: UnsafeMutablePointer<CChar>
    private var pathCapacity: Int
    private var pathLength: Int = 0
    private var nameBuffer: UnsafeMutablePointer<CChar>
    private var nameCapacity: Int
    private var nameLength: Int = 0
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

    @inline(__always)
    func push(name: UnsafeRawPointer, nameLen: Int) {
        segmentStack.append(pathLength)
        ensurePathCapacity(pathLength + 1 + nameLen + 1)

        if pathLength > 0 && pathBuffer[pathLength - 1] != 0x2F {
            pathBuffer[pathLength] = 0x2F
            pathLength += 1
        }

        memcpy(pathBuffer.advanced(by: pathLength), name, nameLen)
        pathLength += nameLen
        pathBuffer[pathLength] = 0
    }

    @inline(__always)
    func pop() {
        if let prevLen = segmentStack.popLast() {
            pathLength = prevLen
            pathBuffer[pathLength] = 0
        }
    }

    @inline(__always)
    func currentPath() -> (UnsafePointer<CChar>, Int) {
        return (UnsafePointer(pathBuffer), pathLength)
    }

    @inline(__always)
    func buildChildPath(name: UnsafeRawPointer, nameLen: Int) -> String {
        if nameLen + pathLength + 2 > nameCapacity {
            let newCapacity = max(nameCapacity * 2, nameLen + pathLength + 256)
            let newBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: newCapacity)
            nameBuffer.deallocate()
            nameBuffer = newBuffer
            nameCapacity = newCapacity
        }

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

    @inline(__always)
    func currentPathString() -> String {
        return String(cString: pathBuffer)
    }

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

    @inline(__always)
    static func nameString(from ptr: UnsafeRawPointer, length: Int) -> String {
        return String(decoding: UnsafeRawBufferPointer(start: ptr, count: length), as: UTF8.self)
    }
}
