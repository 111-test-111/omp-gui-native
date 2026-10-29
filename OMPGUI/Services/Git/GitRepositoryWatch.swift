import CoreServices
import Foundation

/// Visible Git browsing owns this recursive, event-driven observation. It never
/// walks directories, starts Git or installs a polling timer on its own.
@MainActor
final class GitRepositoryWatch {
    private let engine: Engine
    private(set) var isAvailable: Bool
    private var active = true

    init(location: GitRepositoryLocation, onChange: @escaping @MainActor () -> Void) {
        engine = Engine(location: location)
        isAvailable = false
        isAvailable = engine.start { [weak self] in
            guard self?.active == true else { return }
            onChange()
        }
    }

    func stop() {
        active = false
        engine.stop()
    }

    isolated deinit { stop() }

    private final class Engine: @unchecked Sendable {
        private let queue = DispatchQueue(label: "dev.ompgui.git-browser-watch", qos: .utility)
        private let paths: [String]
        private let ignoredPrefixes: [String]
        private var stream: FSEventStreamRef?
        private var pending: DispatchWorkItem?
        private var firstEvent: DispatchTime?
        private var revision: UInt64 = 0

        init(location: GitRepositoryLocation) {
            func real(_ url: URL) -> String {
                url.path.withCString { realpath($0, nil).map { pointer in
                    defer { free(pointer) }
                    return String(cString: pointer)
                } } ?? url.path
            }
            let common = real(location.commonDirectory)
            paths = Array(Set([real(location.root), real(location.gitDirectory), common, real(location.indexFile.deletingLastPathComponent())]))
            ignoredPrefixes = [common + "/objects/", common + "/logs/", common + "/refs/tivano/", common + "/refs/omp/"]
        }

        func start(notify: @escaping @MainActor @Sendable () -> Void) -> Bool {
            queue.sync {
                var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                                   retain: nil, release: nil, copyDescription: nil)
                let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
                let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
                    guard let info else { return }
                    let engine = Unmanaged<Engine>.fromOpaque(info).takeUnretainedValue()
                    let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as? [String] ?? []
                    let lost = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                        | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
                    let mustRefresh = (0..<count).contains { flags[$0] & lost != 0 }
                    engine.receive(Array(paths.prefix(count)), force: mustRefresh)
                }
                guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15, flags) else { return false }
                self.notify = notify
                self.stream = stream
                FSEventStreamSetDispatchQueue(stream, queue)
                guard FSEventStreamStart(stream) else {
                    FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
                    self.stream = nil
                    return false
                }
                return true
            }
        }

        private var notify: (@MainActor @Sendable () -> Void)?

        private func receive(_ changed: [String], force: Bool) {
            guard stream != nil, force || changed.contains(where: { path in !ignoredPrefixes.contains(where: path.hasPrefix) }) else { return }
            let now = DispatchTime.now()
            let started = firstEvent ?? now
            firstEvent = started
            pending?.cancel()
            revision &+= 1
            let expected = revision
            let item = DispatchWorkItem { [weak self] in
                guard let self, stream != nil, revision == expected, let notify else { return }
                pending = nil
                firstEvent = nil
                Task { @MainActor in notify() }
            }
            pending = item
            let deadline = min(now.uptimeNanoseconds + 180_000_000, started.uptimeNanoseconds + 700_000_000)
            queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline), execute: item)
        }

        func stop() {
            queue.sync {
                revision &+= 1
                pending?.cancel(); pending = nil; firstEvent = nil; notify = nil
                guard let stream else { return }
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
        }
    }
}
