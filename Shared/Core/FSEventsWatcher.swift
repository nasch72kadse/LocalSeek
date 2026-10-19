import Foundation
import CoreServices

/// Beobachtet Quellordner via FSEvents und meldet geänderte Pfade. Die FSEvents-Latency
/// entprellt bereits auf Kernelebene (Bursts werden gebündelt); zusätzliche Entprellung
/// erfolgt im Aufrufer. Start/Stop laufen threadsicher auf einer eigenen Queue.
public final class FSEventsWatcher: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.localseek.fsevents")
    private let latency: CFTimeInterval
    private let onChange: @Sendable ([String]) -> Void
    private var stream: FSEventStreamRef?
    private var roots: [String] = []
    private let queueKey = DispatchSpecificKey<Bool>()

    public init(latency: CFTimeInterval = 0.5, onChange: @escaping @Sendable ([String]) -> Void) {
        self.latency = latency
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        if DispatchQueue.getSpecific(key: queueKey) == true { stopLocked() }
        else { queue.sync { stopLocked() } }
    }

    /// Startet die Beobachtung der angegebenen Wurzelpfade; ersetzt einen laufenden Stream.
    public func start(paths: [String]) {
        if DispatchQueue.getSpecific(key: queueKey) == true { startLocked(paths: paths) }
        else { queue.sync { startLocked(paths: paths) } }
    }

    private func startLocked(paths: [String]) {
        stopLocked()
        guard !paths.isEmpty else { return }
        roots = paths

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagUseCFTypes)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags) else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    public func stop() {
        if DispatchQueue.getSpecific(key: queueKey) == true { stopLocked() }
        else { queue.sync { stopLocked() } }
    }

    private func stopLocked() {
        roots = []
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
        guard let info else { return }
        let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
        guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
        let lostMask = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs |
            kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped |
            kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged)
        let lostEvents = (0..<count).contains { eventFlags[$0] & lostMask != 0 }
        watcher.onChange(lostEvents ? Array(Set(paths + watcher.roots)) : paths)
    }
}
