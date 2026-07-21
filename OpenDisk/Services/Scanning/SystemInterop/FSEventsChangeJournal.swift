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

    /// Accumulates journal events. Its fields are unlocked because they are
    /// only ever touched on the FSEvents callback queue — including the one
    /// read (`buildResult`) that turns them into a result, which happens in
    /// the HistoryDone branch of the callback, on that same queue.
    private final class Collector {
        var changes = Changes()
        var unreliable = false
        let rootPrefix: String

        init(rootPrefix: String) {
            self.rootPrefix = rootPrefix
        }
    }

    /// FSEventStreamRef is an opaque pointer (non-Sendable); this box lets
    /// the teardown hop onto the FSEvents queue under strict concurrency
    /// without capturing a bare pointer in a `@Sendable` block.
    private struct StreamBox: @unchecked Sendable {
        let stream: FSEventStreamRef
    }

    /// Outcome of publishing the started stream + continuation. When a
    /// finish already won the race, it carries the result that finish
    /// computed so the start path resumes with it (nil for cancellation,
    /// the real Changes for a HistoryDone that beat registration).
    private enum RegisterOutcome {
        case registered
        case alreadyFinished(Changes?)
    }

    /// Owns the one-shot completion of a replay: resumes the awaiting
    /// continuation exactly once and tears the FSEvents stream down exactly
    /// once, no matter which of HistoryDone, the timeout, or task
    /// cancellation gets there first. Those triggers race across different
    /// threads, so the decision is made under a mutex. `@unchecked Sendable`
    /// because it hands its own synchronization (the mutex guards the
    /// continuation/stream/flag/result; the Collector is queue-confined).
    private final class Replay: @unchecked Sendable {
        struct State {
            var continuation: CheckedContinuation<Changes?, Never>?
            var stream: FSEventStreamRef?
            var finished = false
            /// The result the winning finish computed. Read by `register`
            /// only when `finished` is already true (so finish has run and
            /// set it) — this is how a HistoryDone that arrives before the
            /// continuation is registered still delivers its real result.
            var result: Changes?
        }

        let collector: Collector
        let queue: DispatchQueue
        private let state = Mutex(State())

        init(collector: Collector, queue: DispatchQueue) {
            self.collector = collector
            self.queue = queue
        }

        /// Registers the started stream and its continuation. When a finish
        /// already won the race before we could register, returns
        /// `.alreadyFinished(result)` carrying the result that finish
        /// stashed — the caller then owns teardown + resume(result) itself.
        func register(
            continuation: CheckedContinuation<Changes?, Never>,
            stream: FSEventStreamRef
        ) -> RegisterOutcome {
            state.withLock { s in
                if s.finished { return .alreadyFinished(s.result) }
                s.continuation = continuation
                s.stream = stream
                return .registered
            }
        }

        /// Resume with `result` and tear down, exactly once. `result` is nil
        /// for every incomplete path (timeout, cancellation); the HistoryDone
        /// path passes the finished `Changes?` (itself possibly nil when the
        /// journal was unreliable or oversized).
        ///
        /// The result is stashed under the lock the moment `finished`
        /// latches — even before checking for a continuation — so a
        /// HistoryDone that wins the race before `register` publishes the
        /// continuation is not lost: `register` observes `finished` and
        /// resumes with this stashed result.
        ///
        /// Teardown is scheduled *before* the resume so the teardown block's
        /// strong `self` capture is in place — keeping the Collector alive
        /// for the C callback's unretained pointer — before the awaiting
        /// frame can drop its reference.
        func finish(with result: Changes?) {
            let won: (CheckedContinuation<Changes?, Never>, FSEventStreamRef?)? =
                state.withLock { s in
                    guard !s.finished else { return nil }
                    s.finished = true
                    // Stash before the continuation guard so a finish that
                    // wins before `register` runs still hands its result to
                    // `register` (rather than silently becoming nil).
                    s.result = result
                    // Cancellation — or a HistoryDone that beat register —
                    // can win before `register` stored anything; the flag
                    // and result still latch, and `register` will observe
                    // them and do the resume + teardown on the start path.
                    guard let continuation = s.continuation else { return nil }
                    let stream = s.stream
                    s.continuation = nil
                    s.stream = nil
                    return (continuation, stream)
                }
            guard let (continuation, stream) = won else { return }
            teardown(stream)
            continuation.resume(returning: result)
        }

        /// Stop/Invalidate/Release on the FSEvents queue, so it never races a
        /// callback still in flight and no callback fires after Stop. Called
        /// only by the single finish winner (or the start path when register
        /// reports a finish already won), hence exactly once.
        func teardown(_ stream: FSEventStreamRef?) {
            guard let stream else { return }
            let box = StreamBox(stream: stream)
            queue.async { [self] in
                FSEventStreamStop(box.stream)
                FSEventStreamInvalidate(box.stream)
                FSEventStreamRelease(box.stream)
                // Keep the Collector alive for any callback still queued
                // ahead of this block; after Stop none can follow.
                withExtendedLifetime(self) {}
            }
        }
    }

    /// Applies the reliability, size, dedup, and parents-before-children
    /// ordering rules to what the callback accumulated. Called on the
    /// FSEvents queue when HistoryDone arrives, so reading the Collector is
    /// race-free.
    private static func buildResult(from collector: Collector) -> Changes? {
        guard !collector.unreliable,
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

    /// Collects every change under `rootPath` since `eventID`, or nil when
    /// the journal cannot answer reliably (ID wrapped or purged, events
    /// dropped, too many changes, replay too slow) — callers then run a
    /// full scan.
    ///
    /// The wait for HistoryDone is a pure Swift-concurrency suspension: no
    /// thread is blocked. The FSEvents callback still runs on a dedicated
    /// serial dispatch queue, so accumulation never touches the cooperative
    /// pool.
    static func changes(since eventID: UInt64, under rootPath: String) async -> Changes? {
        let collector = Collector(rootPrefix: rootPath.directoryPrefix)
        // Its own queue, at user-initiated QoS to match the caller's, so the
        // callback (and the timeout it schedules) never wait behind lower-
        // priority work.
        let queue = DispatchQueue(label: "OpenDisk.FSEventsChangeJournal", qos: .userInitiated)
        let replay = Replay(collector: collector, queue: queue)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Changes?, Never>) in
                var context = FSEventStreamContext(
                    version: 0,
                    info: Unmanaged.passUnretained(replay).toOpaque(),
                    retain: nil, release: nil, copyDescription: nil
                )

                let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, eventFlags, _ in
                    guard let info else { return }
                    let replay = Unmanaged<Replay>.fromOpaque(info).takeUnretainedValue()
                    let collector = replay.collector
                    let paths = Unmanaged<CFArray>.fromOpaque(eventPaths)
                        .takeUnretainedValue() as? [String] ?? []

                    for index in 0..<eventCount {
                        let flags = eventFlags[index]

                        if flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 {
                            // Read + process the accumulated events here on
                            // the callback queue, then hand the result to the
                            // one-shot finisher.
                            replay.finish(with: buildResult(from: collector))
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
                        // Keep events inside the scan root (mount points below
                        // the root are cut by the scanners themselves).
                        // rootPrefix ends in "/", so hasPrefix also covers
                        // exact equality.
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
                    // UseCFTypes delivers event paths as a CFArray of
                    // CFStrings (the callback relies on that shape).
                    FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
                ) else {
                    continuation.resume(returning: nil)
                    return
                }

                FSEventStreamSetDispatchQueue(stream, queue)
                guard FSEventStreamStart(stream) else {
                    // Never started, so no callback can fire: safe to tear
                    // down synchronously, exactly as before.
                    FSEventStreamInvalidate(stream)
                    FSEventStreamRelease(stream)
                    continuation.resume(returning: nil)
                    return
                }

                // Publish the continuation + stream. If a finish already won
                // the race (cancellation, or a HistoryDone delivered on the
                // queue before we got here), we own the resume + teardown
                // right here — resuming with the result finish stashed.
                switch replay.register(continuation: continuation, stream: stream) {
                case .alreadyFinished(let result):
                    replay.teardown(stream)
                    continuation.resume(returning: result)
                    return
                case .registered:
                    break
                }

                // Non-blocking timeout: if HistoryDone never arrives, give up
                // and full-scan. Scheduled on the callback queue so it can
                // never tear the stream down mid-batch and needs no extra
                // synchronization with the accumulating callback. First one
                // through `finish` wins; a late timer is a harmless no-op.
                queue.asyncAfter(deadline: .now() + replayTimeout) {
                    replay.finish(with: nil)
                }
            }
        } onCancel: {
            replay.finish(with: nil)
        }
    }

    /// The event ID marking "now"; capture before a scan starts so any
    /// change during the scan replays next time.
    static var currentEventID: UInt64 {
        FSEventsGetCurrentEventId()
    }
}