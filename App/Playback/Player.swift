import AVFoundation
import Combine
import MediaPlayer
import QuartzCore
import SwiftUI
import UIKit

enum RepeatMode: CaseIterable {
    case off, all, one
}

/// Stable wrapper for queue items so SwiftUI `ForEach` / `.onMove` / `.onDelete` never corrupt
/// row identity even when duplicate tracks exist in the queue.
struct QueueEntry: Identifiable, Hashable {
    let id: UUID
    let track: Track

    init(id: UUID = UUID(), track: Track) {
        self.id = id
        self.track = track
    }
}

/// Playback position, split out of Player so its 5-per-second updates only redraw the views
/// that show it (progress bar, lyrics) instead of everything observing the player.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var position: Double = 0
}

@MainActor
final class Player: ObservableObject {
    @Published private(set) var entries: [QueueEntry] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    let clock: PlaybackClock
    var position: Double { clock.position }
    @Published private(set) var duration: Double = 0
    @Published private(set) var artwork: UIImage?
    @Published private(set) var isSpatialPlayback = false
    @Published private(set) var shuffle = false
    @Published var repeatMode: RepeatMode = .off
    /// Bit-perfect mode for USB DACs (see EngineBackend). Saved in Settings.
    @Published var bitPerfect: Bool {
        didSet {
            UserDefaults.standard.set(bitPerfect, forKey: AppSettings.bitPerfectKey)
            engine.bitPerfect = bitPerfect
            applyEqualizer()
            refreshOutputInfo()
        }
    }
    @Published private(set) var output = OutputInfo()
    let stateChanged = PassthroughSubject<Void, Never>()

    var queue: [Track] { entries.map(\.track) }
    var current: Track? { entries.indices.contains(index) ? entries[index].track : nil }
    var upNextEntries: ArraySlice<QueueEntry> { entries.indices.contains(index) ? entries[(index + 1)...] : [] }
    var upNext: [Track] { upNextEntries.map(\.track) }

    let equalizer: Equalizer
    weak var library: LibraryStore?
    weak var stats: StatsStore?

    private let engine: EngineBackend
    private let avPlayer: AVPlayerBackend
    private var backend: PlaybackBackend?
    private var unshuffledEntries: [QueueEntry] = []
    private var timer: Timer?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    // Real monotonic listening time tracking (survives iOS background Timer throttling).
    private var listened: Double = 0
    private var pendingStatsSeconds: Double = 0
    private var lastTickMediaTime: CFTimeInterval?
    private var countedPlay = false
    private var wasPlayingBeforeInterruption = false

    init(equalizer: Equalizer) {
        self.equalizer = equalizer
        clock = PlaybackClock()
        engine = EngineBackend()
        avPlayer = AVPlayerBackend()
        bitPerfect = UserDefaults.standard.bool(forKey: AppSettings.bitPerfectKey)
        engine.bitPerfect = bitPerfect

        equalizer.onChange = { [weak self] in self?.applyEqualizer() }
        applyEqualizer()
        engine.onOutputChange = { [weak self] in self?.refreshOutputInfo() }

        AudioSessionCoordinator.shared.onMediaServicesReset = { [weak self] in
            self?.engine.rebuildAfterMediaServicesReset()
            self?.applyEqualizer()
            self?.refreshOutputInfo()
        }

        for backend in [engine, avPlayer] as [PlaybackBackend] {
            backend.onFinish = { [weak self] in self?.trackFinished() }
            backend.onPlaybackStateChanged = { [weak self] playing in
                guard let self, self.backend === backend else { return }
                if self.isPlaying != playing {
                    self.flushListeningTime()
                    self.isPlaying = playing
                    self.lastTickMediaTime = playing ? CACurrentMediaTime() : nil
                    AudioSessionCoordinator.shared.updatePlaybackState(isPlaying: playing, hasTrack: self.current != nil)
                    self.updateNowPlaying()
                }
            }
        }
        configureRemoteCommands()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let info = note.userInfo
            MainActor.assumeIsolated { self?.handleInterruption(info) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pause() }
                self?.refreshOutputInfo()
            }
        })
    }

    deinit {
        timer?.invalidate()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: Queue

    func play(_ tracks: [Track], startAt startIndex: Int = 0, shuffled: Bool = false) {
        guard tracks.indices.contains(startIndex) else { return }
        flushListeningTime()
        let wrapped = tracks.map { QueueEntry(track: $0) }
        if shuffled {
            var rest = wrapped
            let first = rest.remove(at: Int.random(in: 0..<rest.count))
            unshuffledEntries = wrapped
            entries = [first] + rest.shuffled()
            shuffle = true
        } else {
            unshuffledEntries = wrapped
            entries = wrapped
            shuffle = false
        }
        index = shuffled ? 0 : startIndex
        loadCurrent(autoplay: true)
    }

    func playNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        if entries.isEmpty { return play(tracks) }
        let wrapped = tracks.map { QueueEntry(track: $0) }
        entries.insert(contentsOf: wrapped, at: index + 1)
        if let currentEntry = entries.indices.contains(index) ? entries[index] : nil,
           let unshuffledPos = unshuffledEntries.firstIndex(where: { $0.id == currentEntry.id }) {
            unshuffledEntries.insert(contentsOf: wrapped, at: unshuffledPos + 1)
        } else {
            unshuffledEntries += wrapped
        }
    }

    func addToQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        if entries.isEmpty { return play(tracks) }
        let wrapped = tracks.map { QueueEntry(track: $0) }
        entries += wrapped
        unshuffledEntries += wrapped
    }

    func jump(to queueIndex: Int) {
        guard entries.indices.contains(queueIndex) else { return }
        flushListeningTime()
        index = queueIndex
        loadCurrent(autoplay: true)
    }

    func removeFromQueue(at offsets: IndexSet) {
        // Offsets are relative to `upNextEntries`; filter bounds BEFORE removing.
        let validAbsolute = IndexSet(offsets.map { $0 + index + 1 }.filter { entries.indices.contains($0) })
        guard !validAbsolute.isEmpty else { return }
        let removedIDs = Set(validAbsolute.map { entries[$0].id })
        entries.remove(atOffsets: validAbsolute)
        unshuffledEntries.removeAll { removedIDs.contains($0.id) }
    }

    func moveInQueue(from offsets: IndexSet, to destination: Int) {
        guard entries.indices.contains(index) else { return }
        var upcoming = Array(upNextEntries)
        upcoming.move(fromOffsets: offsets, toOffset: destination)
        entries = Array(entries[...index]) + upcoming
        if !shuffle {
            unshuffledEntries = entries
        }
    }

    func toggleShuffle() {
        guard entries.indices.contains(index) else {
            shuffle.toggle()
            return
        }
        let currentEntry = entries[index]
        if shuffle {
            entries = unshuffledEntries
            index = entries.firstIndex(where: { $0.id == currentEntry.id }) ?? 0
            shuffle = false
        } else {
            unshuffledEntries = entries
            var rest = entries
            rest.remove(at: index)
            entries = [currentEntry] + rest.shuffled()
            index = 0
            shuffle = true
        }
    }

    func cycleRepeat() {
        let all = RepeatMode.allCases
        repeatMode = all[(all.firstIndex(of: repeatMode)! + 1) % all.count]
    }

    /// Deleted files must leave the queue so playback never hits a missing URL.
    func remove(_ tracks: [Track]) {
        let doomed = Set(tracks.map(\.id))
        let wasCurrent = current.map { doomed.contains($0.id) } ?? false
        let before = entries[..<min(index, entries.count)].filter { doomed.contains($0.track.id) }.count
        entries.removeAll { doomed.contains($0.track.id) }
        unshuffledEntries.removeAll { doomed.contains($0.track.id) }
        index = max(0, index - before)
        if entries.isEmpty {
            stop()
        } else if wasCurrent {
            index = min(index, entries.count - 1)
            loadCurrent(autoplay: isPlaying)
        }
    }

    // MARK: Transport

    func togglePlayPause() {
        if isPlaying { pause() } else { resume() }
    }

    func resume() {
        guard let backend, current != nil else { return }
        AudioSessionCoordinator.shared.updatePlaybackState(isPlaying: true, hasTrack: true)
        backend.play()
        isPlaying = backend.isPlaying
        lastTickMediaTime = isPlaying ? CACurrentMediaTime() : nil
        if isPlaying { startTimer() }
        updateNowPlaying()
        refreshOutputInfo()
    }

    func pause() {
        flushListeningTime()
        backend?.pause()
        isPlaying = false
        lastTickMediaTime = nil
        clock.position = backend?.currentTime ?? position
        AudioSessionCoordinator.shared.updatePlaybackState(isPlaying: false, hasTrack: current != nil)
        updateNowPlaying()
    }

    func next() {
        flushListeningTime()
        if index + 1 < entries.count {
            index += 1
            loadCurrent(autoplay: true)
        } else if repeatMode == .all, !entries.isEmpty {
            index = 0
            loadCurrent(autoplay: true)
        } else {
            pause()
            seek(to: 0)
        }
    }

    func previous() {
        let livePosition = backend?.currentTime ?? position
        if livePosition > 3 || index == 0 {
            seek(to: 0)
        } else {
            flushListeningTime()
            index -= 1
            loadCurrent(autoplay: isPlaying)
        }
    }

    func seek(to seconds: Double) {
        let clamped = min(max(seconds.isFinite ? seconds : 0, 0), max(duration, 0))
        backend?.seek(to: clamped)
        clock.position = clamped
        updateNowPlaying()
    }

    func stop() {
        flushListeningTime()
        backend?.stop()
        backend = nil
        entries = []
        unshuffledEntries = []
        index = 0
        isPlaying = false
        lastTickMediaTime = nil
        clock.position = 0
        duration = 0
        artwork = nil
        timer?.invalidate()
        timer = nil
        AudioSessionCoordinator.shared.updatePlaybackState(isPlaying: false, hasTrack: false)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        stateChanged.send()
    }

    var artworkSource: ArtworkSource? {
        guard let current else { return nil }
        return library?.artwork(for: current) ?? .track(current)
    }

    // MARK: Internals

    private func loadCurrent(autoplay: Bool) {
        guard let track = current else { return }
        backend?.stop()

        var chosen: PlaybackBackend = track.isSpatial ? avPlayer : engine
        do {
            try chosen.load(track.url)
        } catch {
            chosen = avPlayer
            try? chosen.load(track.url)
        }
        backend = chosen
        isSpatialPlayback = track.isSpatial && chosen === avPlayer
        clock.position = 0
        duration = chosen.duration > 0 ? chosen.duration : track.duration
        listened = 0
        pendingStatsSeconds = 0
        lastTickMediaTime = nil
        countedPlay = false
        artwork = nil
        refreshOutputInfo()

        if autoplay {
            resume()
        } else {
            isPlaying = false
            AudioSessionCoordinator.shared.updatePlaybackState(isPlaying: false, hasTrack: true)
            updateNowPlaying()
        }

        reloadArtwork()
    }

    /// Reloads the current cover (after a new one was downloaded or picked).
    func reloadArtwork() {
        guard let id = current?.id, let source = artworkSource else { return }
        Task { [weak self] in
            let image = await ArtworkStore.shared.image(for: source, maxPixel: 1200)
            guard let self, self.current?.id == id, image !== self.artwork else { return }
            self.artwork = image
            self.updateNowPlaying()
        }
    }

    private func applyEqualizer() {
        if bitPerfect {
            engine.eq.bypass = true
            engine.eq.globalGain = 0
        } else {
            equalizer.configure(engine.eq)
        }
    }

    /// What the hardware is doing right now, for the Now Playing badge and Settings.
    func refreshOutputInfo() {
        let session = AVAudioSession.sharedInstance()
        let port = session.currentRoute.outputs.first
        let fileRate = backend === engine ? engine.fileSampleRate : 0
        let info = OutputInfo(routeName: port?.portName ?? "",
                              routeKind: OutputInfo.Kind(port?.portType),
                              hardwareRate: session.sampleRate,
                              fileRate: fileRate,
                              usingEngine: backend === engine)
        if info != output { output = info }
    }

    private func trackFinished() {
        flushListeningTime()
        if repeatMode == .one {
            // Reset listening counters so repeated listens count properly in Stats.
            listened = 0
            pendingStatsSeconds = 0
            countedPlay = false
            seek(to: 0)
            resume()
        } else {
            next()
        }
    }

    private func startTimer() {
        guard timer == nil || timer?.isValid == false else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let backend else { return }
        if isPlaying {
            // Sync with real backend playback so failed files never count fake listening time.
            guard backend.isPlaying else {
                lastTickMediaTime = nil
                return
            }
            let now = CACurrentMediaTime()
            let delta: Double
            if let last = lastTickMediaTime {
                delta = min(max(now - last, 0), 30)
            } else {
                delta = 0.2
            }
            lastTickMediaTime = now

            clock.position = backend.currentTime
            listened += delta
            pendingStatsSeconds += delta

            if let track = current {
                if pendingStatsSeconds >= 2.0 {
                    let album = library?.album(containing: track)?.title ?? track.album
                    stats?.addListening(track, album: album, seconds: pendingStatsSeconds)
                    pendingStatsSeconds = 0
                }
                if !countedPlay, listened >= min(30, max(duration, 1) * 0.5) {
                    countedPlay = true
                    let album = library?.album(containing: track)?.title ?? track.album
                    stats?.recordPlay(track, album: album)
                }
            }
            if duration <= 0, backend.duration > 0 { duration = backend.duration }
        } else if timer != nil {
            timer?.invalidate()
            timer = nil
        }
    }

    private func flushListeningTime() {
        if let last = lastTickMediaTime, isPlaying, backend?.isPlaying == true {
            let extra = min(max(CACurrentMediaTime() - last, 0), 30)
            listened += extra
            pendingStatsSeconds += extra
            lastTickMediaTime = CACurrentMediaTime()
        }
        guard pendingStatsSeconds > 0, let track = current else {
            pendingStatsSeconds = 0
            return
        }
        let album = library?.album(containing: track)?.title ?? track.album
        stats?.addListening(track, album: album, seconds: pendingStatsSeconds)
        pendingStatsSeconds = 0
        if !countedPlay, listened >= min(30, max(duration, 1) * 0.5) {
            countedPlay = true
            stats?.recordPlay(track, album: album)
        }
    }

    private func handleInterruption(_ info: [AnyHashable: Any]?) {
        guard let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            if isPlaying {
                flushListeningTime()
                backend?.pause()
                isPlaying = false
                lastTickMediaTime = nil
                updateNowPlaying()
            }
        case .ended:
            let optionsRaw = info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
            if wasPlayingBeforeInterruption && shouldResume {
                resume()
            }
            wasPlayingBeforeInterruption = false
        @unknown default:
            break
        }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        func runSync(_ action: @escaping @MainActor (Player) -> MPRemoteCommandHandlerStatus) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
            return { [weak self] _ in
                guard let self else { return .commandFailed }
                if Thread.isMainThread {
                    return MainActor.assumeIsolated { action(self) }
                } else {
                    return DispatchQueue.main.sync {
                        MainActor.assumeIsolated { action(self) }
                    }
                }
            }
        }
        center.playCommand.addTarget(handler: runSync { player in
            guard player.current != nil else { return .noActionableNowPlayingItem }
            player.resume()
            return .success
        })
        center.pauseCommand.addTarget(handler: runSync { player in
            player.pause()
            return .success
        })
        center.togglePlayPauseCommand.addTarget(handler: runSync { player in
            guard player.current != nil else { return .noActionableNowPlayingItem }
            player.togglePlayPause()
            return .success
        })
        center.nextTrackCommand.addTarget(handler: runSync { player in
            guard player.current != nil else { return .noActionableNowPlayingItem }
            player.next()
            return .success
        })
        center.previousTrackCommand.addTarget(handler: runSync { player in
            guard player.current != nil else { return .noActionableNowPlayingItem }
            player.previous()
            return .success
        })
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let target = event.positionTime
            if Thread.isMainThread {
                return MainActor.assumeIsolated {
                    self.seek(to: target)
                    return .success
                }
            } else {
                return DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        self.seek(to: target)
                        return .success
                    }
                }
            }
        }
    }

    private func updateNowPlaying() {
        guard let track = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            stateChanged.send()
            return
        }
        let elapsed = backend?.currentTime ?? position
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let album = library?.album(containing: track)?.title ?? track.album {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if let image = artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        stateChanged.send()
    }
}

/// The current audio output, and whether playback reaches it untouched.
struct OutputInfo: Equatable {
    enum Kind: Equatable {
        case wired, bluetooth, airPlay, builtIn, other

        init(_ port: AVAudioSession.Port?) {
            guard let port else {
                self = .other
                return
            }
            if [.usbAudio, .headphones, .lineOut, .HDMI].contains(port) {
                self = .wired
            } else if [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP].contains(port) {
                self = .bluetooth
            } else if port == .airPlay {
                self = .airPlay
            } else if port == .builtInSpeaker || port == .builtInReceiver {
                self = .builtIn
            } else {
                self = .other
            }
        }
    }

    var routeName = ""
    var routeKind = Kind.other
    var hardwareRate: Double = 0
    var fileRate: Double = 0
    var usingEngine = false

    var ratesMatch: Bool { fileRate > 0 && abs(fileRate - hardwareRate) < 1 }

    /// Bit-perfect is only possible over a wired digital output with matching rates.
    func isBitPerfect(enabled: Bool) -> Bool {
        enabled && usingEngine && routeKind == .wired && ratesMatch
    }

    /// Why it isn't, in a few words.
    func blocker(enabled: Bool) -> String? {
        guard enabled else { return nil }
        if !usingEngine { return "Spatial audio file" }
        switch routeKind {
        case .bluetooth: return "Bluetooth re-encodes audio"
        case .airPlay: return "AirPlay resamples audio"
        case .builtIn: return "Built-in speaker"
        case .other: return "Non-wired output"
        case .wired: break
        }
        if fileRate > 0, !ratesMatch {
            return "Resampled \(Formatting.sampleRate(fileRate)) → \(Formatting.sampleRate(hardwareRate))"
        }
        return nil
    }
}
