import Foundation
import CoreServices

// MARK: - File System Monitoring

/// Monitors file system changes using FSEvents
class FileSystemMonitor {
    private var eventStream: FSEventStreamRef?
    private var isMonitoring = false
    private let eventQueue = DispatchQueue(label: "com.diskmanager.fsevents", qos: .background)

    /// File system change event
    struct FileSystemChange {
        let path: String
        let eventId: FSEventStreamEventId
        let flags: FSEventStreamEventFlags

        var isCreated: Bool {
            return flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0
        }

        var isRemoved: Bool {
            return flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0
        }

        var isModified: Bool {
            return flags & UInt32(kFSEventStreamEventFlagItemModified) != 0
        }

        var isRenamed: Bool {
            return flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0
        }

        var isDirectory: Bool {
            return flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
        }
    }

    /// Start monitoring paths for changes
    func startMonitoring(paths: [String], latency: CFTimeInterval = 1.0, onChange: @escaping (FileSystemChange) -> Void) {
        stopMonitoring()

        let pathsCFArray = paths as CFArray

        // Create context to pass callback
        let contextInfo = Unmanaged.passUnretained(self).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: contextInfo,
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        // Store the callback
        self.changeCallback = onChange

        // Create event stream
        eventStream = FSEventStreamCreate(
            nil,
            fsEventCallback,
            &context,
            pathsCFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagWatchRoot |
                kFSEventStreamCreateFlagIgnoreSelf
            )
        )

        guard let stream = eventStream else {
            print("Failed to create FSEvents stream")
            return
        }

        // Schedule on background queue
        FSEventStreamSetDispatchQueue(stream, eventQueue)

        // Start monitoring
        FSEventStreamStart(stream)
        isMonitoring = true

        print("Started monitoring paths: \(paths)")
    }

    /// Stop monitoring
    func stopMonitoring() {
        guard let stream = eventStream else { return }

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)

        eventStream = nil
        isMonitoring = false
        changeCallback = nil

        print("Stopped file system monitoring")
    }

    /// Process batch of events
    func processBatchedEvents(_ events: [FileSystemChange]) {
        // Group events by directory for efficient processing
        var eventsByDirectory: [String: [FileSystemChange]] = [:]

        for event in events {
            let dirPath = URL(fileURLWithPath: event.path).deletingLastPathComponent().path
            eventsByDirectory[dirPath, default: []].append(event)
        }

        // Process each directory's changes
        for (directory, changes) in eventsByDirectory {
            print("Directory \(directory) has \(changes.count) changes")
            // Could trigger partial rescan here if needed
        }
    }

    internal var changeCallback: ((FileSystemChange) -> Void)?

    deinit {
        stopMonitoring()
    }
}

// MARK: - FSEvents Callback

private func fsEventCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }

    let monitor = Unmanaged<FileSystemMonitor>.fromOpaque(info).takeUnretainedValue()

    let pathsArray = eventPaths.bindMemory(to: UnsafePointer<CChar>?.self, capacity: numEvents)

    for i in 0..<numEvents {
        guard let pathCString = pathsArray[i] else { continue }

        let path = String(cString: pathCString)
        let flags = eventFlags[i]
        let eventId = eventIds[i]

        let change = FileSystemMonitor.FileSystemChange(
            path: path,
            eventId: eventId,
            flags: flags
        )

        monitor.changeCallback?(change)
    }
}