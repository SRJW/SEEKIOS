import AVFoundation
import Foundation

/// Single owner of `AVAudioSession` configuration across music playback and sideloaded background
/// transfer keep-alive, preventing Lock Screen remote controls from disappearing when pausing music
/// and recovering reliably after calls, Siri, or media-server resets.
@MainActor
final class AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()

    private let keeper = BackgroundKeeper()
    private var isMusicPlaying = false
    private var hasLoadedTrack = false
    private var needsBackgroundKeepAlive = false
    private var observers: [NSObjectProtocol] = []

    var onMediaServicesReset: (() -> Void)?

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                guard let self, let typeRaw,
                      let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
                if type == .ended {
                    self.reconcile(forceRestartKeeper: true)
                }
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.keeper.resetAfterMediaServicesReset()
                self.configureSession(forMusic: self.hasLoadedTrack)
                self.reconcile(forceRestartKeeper: true)
                self.onMediaServicesReset?()
            }
        })
    }

    func updatePlaybackState(isPlaying: Bool, hasTrack: Bool) {
        isMusicPlaying = isPlaying
        hasLoadedTrack = hasTrack
        if isPlaying {
            keeper.stop()
            configureSession(forMusic: true)
        } else {
            reconcile(forceRestartKeeper: false)
        }
    }

    func setBackgroundKeepAliveNeeded(_ needed: Bool) {
        guard needsBackgroundKeepAlive != needed else {
            // If needed, ensure silence hasn't silently stopped after an OS interruption.
            if needed && !isMusicPlaying && !keeper.isActivelyPlaying {
                reconcile(forceRestartKeeper: true)
            }
            return
        }
        needsBackgroundKeepAlive = needed
        reconcile(forceRestartKeeper: false)
    }

    private func reconcile(forceRestartKeeper: Bool) {
        if needsBackgroundKeepAlive && !isMusicPlaying {
            // Preserve .longFormAudio when a song is loaded/paused so Lock Screen Play still works!
            configureSession(forMusic: hasLoadedTrack)
            keeper.start(forceRestart: forceRestartKeeper)
        } else {
            keeper.stop()
            if !isMusicPlaying && !hasLoadedTrack {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    private func configureSession(forMusic: Bool) {
        let session = AVAudioSession.sharedInstance()
        if forMusic {
            try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try? session.setSupportsMultichannelContent(true)
        } else {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        try? session.setActive(true)
    }
}
