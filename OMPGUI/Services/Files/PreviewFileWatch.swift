import Darwin
import Foundation

/// Only the selected tab owns a watch. Two vnode sources cover in-place writes
/// and directory-entry replacement without a polling timer or a recursive scan.
@MainActor
final class PreviewFileWatch {
    private let url: URL
    private let onChange: @MainActor () -> Void
    private var directorySource: (any DispatchSourceFileSystemObject)?
    private var fileSource: (any DispatchSourceFileSystemObject)?
    private var directoryIdentity: PreviewFileMetadata?
    private var watchedDirectory: URL?
    private var observedFile: PreviewFileMetadata?
    private var lastReported: PreviewFileMetadata?
    private var pending: Task<Void, Never>?
    private var pendingStarted: ContinuousClock.Instant?
    private var needsInitialRefresh = false
    private var stopped = false

    init(url: URL, expectedRevision: String? = nil, onChange: @escaping @MainActor () -> Void) {
        self.url = url.standardizedFileURL
        self.onChange = onChange
        guard url.isFileURL else { stopped = true; return }
        lastReported = PreviewFileMetadata.read(url)
        renewObservations()
        // A prepared file can be replaced between its background read and
        // installing these sources. Compare after both watches are active so
        // the new file cannot silently become the baseline for old pixels.
        if let expectedRevision, PreviewFileMetadata.read(url)?.revision != expectedRevision {
            needsInitialRefresh = true
            noteChange()
        }
    }

    isolated deinit { stop() }

    func stop() {
        guard !stopped else { return }
        stopped = true
        pending?.cancel()
        pending = nil
        pendingStarted = nil
        needsInitialRefresh = false
        fileSource?.cancel()
        directorySource?.cancel()
        fileSource = nil
        directorySource = nil
        observedFile = nil
        directoryIdentity = nil
        watchedDirectory = nil
    }

    private func noteChange() {
        guard !stopped else { return }
        let now = ContinuousClock.now
        let started = pendingStarted ?? now
        pendingStarted = started
        // Continuous log writes or a busy sibling must not postpone refresh
        // forever. A burst settles after 180 ms; a continuous one yields a
        // snapshot at least every 600 ms without polling the filesystem.
        let deadline = min(now + .milliseconds(180), started + .milliseconds(600))
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            guard let self, !stopped, !Task.isCancelled else { return }
            pending = nil
            pendingStarted = nil
            let current = PreviewFileMetadata.read(url)
            renewObservations()
            // A directory source also reports writes to unrelated siblings. No
            // reload or image decode is spent on those unchanged-file events.
            if needsInitialRefresh || current != lastReported {
                needsInitialRefresh = false
                lastReported = current
                onChange()
            }
        }
    }

    private func renewObservations() {
        guard !stopped else { return }
        let directory = nearestExistingDirectory(url.deletingLastPathComponent())
        let stamp = directory.flatMap(PreviewFileMetadata.read)
        if watchedDirectory != directory || directoryIdentity?.inode != stamp?.inode || directoryIdentity?.device != stamp?.device || directorySource == nil {
            directorySource?.cancel()
            directorySource = nil
            watchedDirectory = directory
            directoryIdentity = stamp
            if let directory { directorySource = source(for: directory) }
        }
        let current = PreviewFileMetadata.read(url)
        if observedFile?.inode != current?.inode || observedFile?.device != current?.device || fileSource == nil {
            fileSource?.cancel()
            fileSource = nil
            observedFile = current
            if current != nil { fileSource = source(for: url) }
        }
    }

    private func source(for url: URL) -> (any DispatchSourceFileSystemObject)? {
        let descriptor = url.path.withCString { Darwin.open($0, O_EVTONLY | O_CLOEXEC) }
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .attrib, .link, .rename, .delete, .revoke], queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.noteChange() }
        }
        // The descriptor belongs to its source until cancellation finishes. It
        // is never closed while an event handler could still use the vnode.
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        return source
    }

    private func nearestExistingDirectory(_ initial: URL) -> URL? {
        var candidate = initial
        while true {
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &directory), directory.boolValue { return candidate }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { return nil }
            candidate = parent
        }
    }
}
