import CoreServices
import Foundation
import Synchronization

enum FSEventsChangeJournal {

    struct Changes {
        var changedDirectories: [String] = []
        var subtreesToRescan: [String] = []

        var totalCount: Int { changedDirectories.count + subtreesToRescan.count }
    }

    private static let maxUsefulChanges = 40_000

    private final class Collector: @unchecked Sendable {
        var changes = Changes()
        var unreliable = false
        let rootPrefix: String
        // Stored per-instance: referencing outer statics from the C callback crashes the Swift 6.3 frontend.
        let earlyBailChangeCount = maxUsefulChanges * 4

        private struct Waiter {
            var continuation: CheckedContinuation<Bool, Never>?
            var result: Bool?
        }
        private let waiter = Mutex(Waiter())

        init(rootPrefix: String) {
            self.rootPrefix = rootPrefix
        }

        func finish(completed: Bool) {
            let continuation = waiter.withLock { state -> CheckedContinuation<Bool, Never>? in
                guard state.result == nil else { return nil }
                state.result = completed
                defer { state.continuation = nil }
                return state.continuation
            }
            continuation?.resume(returning: completed)
        }

        var isFinished: Bool {
            waiter.withLock { $0.result != nil }
        }

        func install(_ continuation: CheckedContinuation<Bool, Never>) {
            let immediate = waiter.withLock { state -> Bool? in
                if let result = state.result { return result }
                state.continuation = continuation
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }

    static func changes(
        since eventID: UInt64, under rootPath: String, timeout: TimeInterval
    ) async -> Changes? {
        let collector = Collector(rootPrefix: rootPath.directoryPrefix)

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(collector).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, eventFlags, _ in
            guard let info else { return }
            let collector = Unmanaged<Collector>.fromOpaque(info).takeUnretainedValue()
            guard !collector.isFinished else { return }
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths)
                .takeUnretainedValue() as? [String] ?? []

            for index in 0..<eventCount {
                let flags = eventFlags[index]

                if flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 {
                    collector.finish(completed: true)
                    return
                }
                if flags & UInt32(
                    kFSEventStreamEventFlagEventIdsWrapped
                        | kFSEventStreamEventFlagUserDropped
                        | kFSEventStreamEventFlagKernelDropped
                        | kFSEventStreamEventFlagRootChanged
                ) != 0 {
                    collector.unreliable = true
                    continue
                }

                guard index < paths.count else { continue }
                let path = paths[index]
                guard path.hasPrefix(collector.rootPrefix)
                        || path + "/" == collector.rootPrefix else { continue }

                let normalized = path.hasSuffix("/") && path.count > 1
                    ? String(path.dropLast()) : path
                if flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                    collector.changes.subtreesToRescan.append(normalized)
                } else {
                    collector.changes.changedDirectories.append(normalized)
                }
            }
            if collector.changes.totalCount > collector.earlyBailChangeCount {
                collector.finish(completed: false)
            }
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [rootPath] as CFArray,
            eventID,
            0.05,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            return nil
        }

        let queue = DispatchQueue(label: "OpenDisk.FSEventsChangeJournal", qos: .userInitiated)
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }

        let timeoutItem = DispatchWorkItem { collector.finish(completed: false) }
        let completed = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                collector.install(continuation)
                queue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
            }
        } onCancel: {
            collector.finish(completed: false)
        }
        timeoutItem.cancel()

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)

        // Barrier: a callback already running when the outcome latched may still be mid-append.
        let (accumulated, unreliable) = queue.sync {
            (collector.changes, collector.unreliable)
        }

        guard completed, !unreliable,
              accumulated.totalCount <= maxUsefulChanges else {
            return nil
        }
        var changes = accumulated
        changes.changedDirectories = Array(Set(changes.changedDirectories)).sorted {
            $0.components(separatedBy: "/").count < $1.components(separatedBy: "/").count
        }
        changes.subtreesToRescan = Array(Set(changes.subtreesToRescan))
        return changes
    }

    static var currentEventID: UInt64 {
        FSEventsGetCurrentEventId()
    }
}
