import AppKit
import AVKit
import SwiftUI

struct PreviewMediaRenderer: NSViewRepresentable {
    let url: URL
    let revision: String
    let state: PreviewReaderState
    func makeNSView(context: Context) -> PreviewMediaHost { PreviewMediaHost() }
    func updateNSView(_ view: PreviewMediaHost, context: Context) {
        view.update(url: url, revision: revision, state: state)
    }
    static func dismantleNSView(_ view: PreviewMediaHost, coordinator: ()) { view.tearDown() }
}

@MainActor
final class PreviewMediaHost: NSView {
    private let playerView = AVPlayerView()
    private let status = NSTextField(labelWithString: "")
    private var player: AVPlayer?
    private var state: PreviewReaderState?
    private var revisionKey = ""
    private var generation = 0
    private var itemObservation: NSKeyValueObservation?
    private var timeObserver: Any?

    override init(frame: NSRect) {
        super.init(frame: frame)
        playerView.controlsStyle = .floating
        playerView.videoGravity = .resizeAspect
        playerView.showsSharingServiceButton = false
        playerView.allowsPictureInPicturePlayback = false
        addSubview(playerView)
        status.font = .systemFont(ofSize: 13)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        status.isHidden = true
        addSubview(status)
        NotificationCenter.default.addObserver(self, selector: #selector(pause), name: NSApplication.didHideNotification, object: nil)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    func update(url: URL, revision: String, state: PreviewReaderState) {
        let replacing = self.state !== state
        let key = url.path + "\n" + revision
        guard replacing || key != revisionKey else { return }
        releasePlayer()
        self.state = state
        revisionKey = key
        generation += 1
        let currentGeneration = generation
        status.isHidden = true
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        self.player = player
        playerView.player = player
        itemObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            let ready = item.status == .readyToPlay
            let failed = item.status == .failed
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                if ready, let seconds = self.state?.mediaTime, seconds > 0, seconds.isFinite {
                    let duration = self.player?.currentItem?.duration.seconds ?? .nan
                    let target = duration.isFinite && duration > 0 ? min(seconds, duration) : seconds
                    self.player?.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }
                if failed {
                    self.player?.pause()
                    self.status.stringValue = Chrome.localized("Unable to preview media")
                    self.status.isHidden = false
                }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 2, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration, time.seconds.isFinite else { return }
                self.state?.mediaTime = max(0, time.seconds)
            }
        }
        // The user starts playback using the native controls. File selection and
        // revision reloads never play audio or video automatically.
    }

    override func layout() {
        super.layout()
        playerView.frame = bounds
        status.frame = NSRect(x: 8, y: bounds.midY - 12, width: max(0, bounds.width - 16), height: 24)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didMiniaturizeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(pause), name: NSWindow.didMiniaturizeNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        } else { pause() }
    }
    override func viewDidHide() { super.viewDidHide(); pause() }
    @objc private func occlusionChanged() { if window?.occlusionState.contains(.visible) != true { pause() } }
    @objc private func pause() { player?.pause(); savePosition() }

    private func savePosition() {
        guard let seconds = player?.currentTime().seconds, seconds.isFinite else { return }
        state?.mediaTime = max(0, seconds)
    }
    private func releasePlayer() {
        pause()
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        itemObservation?.invalidate()
        itemObservation = nil
        playerView.player = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
    func tearDown() {
        generation += 1
        releasePlayer()
        state = nil
        NotificationCenter.default.removeObserver(self)
    }
}
