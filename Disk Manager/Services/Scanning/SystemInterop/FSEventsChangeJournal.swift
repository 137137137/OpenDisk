import CoreServices
import Foundation

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
    /// Historical replay is local journal reading; if it somehow stalls,
    /// give up and full-scan.
    private static let replayTimeout: TimeInterval = 20

    private final class Collector {
        var changes = Changes()
        var unreliable = false
        let rootPrefix: String
        let done = DispatchSemaphore(value: 0)

        init(rootPrefix: String) {
            self.rootPrefix = rootPrefix
        }
    }

    /// Collects every change under `rootPath` since `eventID`, or nil when
    /// the journal cannot answer reliably (ID wrapped or purged, events
    /// dropped, too many changes) — callers then run a full scan.
    static func changes(since eventID: UInt64, under rootPath: String) -> Changes? {
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let collector = Collector(rootPrefix: prefix)

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(collector).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, eventFlags, _ in
            guard let info else { return }
            let collector = Unmanaged<Collector>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths)
                .takeUnretainedValue() as? [String] ?? []

            for index in 0..<eventCount {
                let flags = eventFlags[index]

                if flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 {
                    collector.done.signal()
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
                // root are cut by the scanners themselves).
                guard path == collector.rootPrefix
                        || path.hasPrefix(collector.rootPrefix)
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

        let queue = DispatchQueue(label: "DiskManager.FSEventsChangeJournal")
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }

        let completed = collector.done.wait(timeout: .now() + replayTimeout) == .success
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)

        guard completed, !collector.unreliable,
              collector.changes.totalCount <= maxUsefulChanges else {
            return nil
        }
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
