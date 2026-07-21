import CoreServices
import Foundation
import Synchronization

/// Replays the volume's persistent FSEvents journal to learn which
/// directories changed since a recorded event ID.
///
/// macOS journals directory-level changes per volume (surviving reboots),
/// so a scanner that saved its tree and the event ID it started from can
/// re-read only the directories that changed since — instead of walking
/// millions of unchanged ones.
enum FSEventsChangeJournal {

    struct Changes {
        /// Directories whose direct contents changed (shallow re-read).
        var changedDirectories: [String] = []
        /// Paths whose entire subtree must be rescanned (the journal
        /// coalesced events).
        var subtreesToRescan: [String] = []

        var totalCount: Int { changedDirectories.count + subtreesToRescan.count }
    }

    /// Above this many changed directories a full scan is faster than
    /// splicing.
    private static let maxUsefulChanges = 40_000
    /// Historical replay is local journal reading; if it stalls, give up
    /// and full-scan — the incremental path must never cost more than the
    /// scan it replaces.
    private static let replayTimeout: TimeInterval = 10

    /// Accumulates journal events. `changes`/`unreliable`/`rootPrefix` are
    /// mutated only on the FSEvents callback queue and read on the resuming
    /// task after `FSEventStreamStop`, ordered after the last write by the
    /// continuation resume — the same synchronization the old
    /// `DispatchSemaphore` relied on. The `waiter` mutex makes completion
    /// resume the awaiting continuation exactly once. Hence @unchecked
    /// Sendable.
    ///
    /// The C FSEvents callback reaches this object through the stream's
    /// `info` pointer (never a Swift capture), so it can be a context-free C
    /// function pointer: everything it needs is an instance member here, and
    /// all result post-processing happens after the await, not in the
    /// callback.
    private final class Collector: @unchecked Sendable {
        var changes = Changes()
        var unreliable = false
        let rootPrefix: String

        private struct Waiter {
            var continuation: CheckedContinuation<Bool, Never>?
            var result: Bool?
        }
        private let waiter = Mutex(Waiter())

        init(rootPrefix: String) {
            self.rootPrefix = rootPrefix
        }

        /// Latch the outcome and resume the parked waiter. The first caller
        /// wins; the loser of the HistoryDone-vs-timeout-vs-cancellation race
        /// (and any later event) is a no-op — exactly-once resume.
        func finish(completed: Bool) {
            let continuation = waiter.withLock { state -> CheckedContinuation<Bool, Never>? in
                guard state.result == nil else { return nil }
                state.result = completed
                defer { state.continuation = nil }
                return state.continuation
            }
            continuation?.resume(returning: completed)
        }

        /// Park the awaiting continuation, or resume it at once if completion
        /// already fired before the awaiting side arrived.
        func install(_ continuation: CheckedContinuation<Bool, Never>) {
            let immediate = waiter.withLock { state -> Bool? in
                if let result = state.result { return result }
                state.continuation = continuation
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }

    /// Collects every change under `rootPath` since `eventID`, or nil when
    /// the journal cannot answer reliably (ID wrapped or purged, events
    /// dropped, too many changes, replay too slow, task cancelled) — callers
    /// then run a full scan.
    ///
    /// The wait for HistoryDone is a pure Swift-concurrency suspension: no
    /// thread is blocked. The FSEvents callback still runs on a dedicated
    /// serial dispatch queue, so accumulation never touches the cooperative
    /// pool.
    static func changes(since eventID: UInt64, under rootPath: String) async -> Changes? {
        let collector = Collector(rootPrefix: rootPath.directoryPrefix)

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(collector).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        // Context-free C function pointer: it only touches the Collector it
        // fetches from `info`, never a captured Swift value.
        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, eventFlags, _ in
            guard let info else { return }
            let collector = Unmanaged<Collector>.fromOpaque(info).takeUnretainedValue()
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
                // Keep events inside the scan root (mount points below the
                // root are cut by the scanners themselves). rootPrefix ends
                // in "/", so hasPrefix also covers exact equality.
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
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [rootPath] as CFArray,
            eventID,
            0.05,
            // UseCFTypes delivers event paths as a CFArray of CFStrings
            // (the callback relies on that shape).
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            return nil
        }

        // User-initiated QoS matches the awaiting task, so the callback (and
        // the timeout it schedules) never wait behind lower-priority work.
        let queue = DispatchQueue(label: "OpenDisk.FSEventsChangeJournal", qos: .userInitiated)
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }

        // Suspend (no thread blocked) until HistoryDone, the replay timeout,
        // or task cancellation — whichever fires first. The timeout runs on
        // the same serial queue as the callback, so the two never overlap;
        // the Collector latch makes the resume exactly-once regardless.
        let timeout = DispatchWorkItem { collector.finish(completed: false) }
        let completed = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                collector.install(continuation)
                queue.asyncAfter(deadline: .now() + replayTimeout, execute: timeout)
            }
        } onCancel: {
            collector.finish(completed: false)
        }
        timeout.cancel() // no-op if it already ran; avoids a late no-op fire

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)

        guard completed, !collector.unreliable,
              collector.changes.totalCount <= maxUsefulChanges else {
            return nil
        }
        // Dedup, and order parents before children so a new directory is
        // adopted by its ancestor before its own event is processed.
        var changes = collector.changes
        changes.changedDirectories = Array(Set(changes.changedDirectories)).sorted {
            $0.components(separatedBy: "/").count < $1.components(separatedBy: "/").count
        }
        changes.subtreesToRescan = Array(Set(changes.subtreesToRescan))
        return changes
    }

    /// The event ID marking "now"; capture before a scan starts so any
    /// change during the scan replays next time.
    static var currentEventID: UInt64 {
        FSEventsGetCurrentEventId()
    }
}
