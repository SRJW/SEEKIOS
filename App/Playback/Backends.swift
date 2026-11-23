import AVFoundation
import Foundation

@MainActor
protocol PlaybackBackend: AnyObject {
    /// Called when the current file plays to the end.
    var onFinish: (() -> Void)? { get set }
    /// Called if playback fails or stops unexpectedly.
    var onPlaybackStateChanged: ((Bool) -> Void)? { get set }
    var duration: Double { get }
    var currentTime: Double { get }
    var isPlaying: Bool { get }
    func load(_ url: URL) throws
    func play()
    func pause()
    func seek(to seconds: Double)
    func stop()
}

/// Stereo playback through AVAudioEngine so the EQ can sit in the signal path.
///
/// Bit-perfect mode: the EQ is bypassed, every gain stays at unity, and before each song the
/// audio session asks the output for the file's own sample rate. With a USB DAC that accepts the
/// rate, iOS switches the hardware and nothing gets resampled; the only conversions left are
/// integer ↔ float, which are lossless for 16- and 24-bit audio.
@MainActor
final class EngineBackend: PlaybackBackend {
    var onFinish: (() -> Void)?
    var onPlaybackStateChanged: ((Bool) -> Void)?
    /// Called after the output's sample rate or route changed, so the UI can update.
    var onOutputChange: (() -> Void)?
    private(set) var isPlaying = false
    var bitPerfect = false {
        didSet {
            guard bitPerfect != oldValue else { return }
            if bitPerfect, let rate = file?.processingFormat.sampleRate, rate > 0 {
                matchHardwareRate(rate)
            } else if !bitPerfect {
                restoreDefaultRate()
            }
        }
    }

    private var engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    let eq = AVAudioUnitEQ(numberOfBands: Equalizer.maxBands)

    private var file: AVAudioFile?
    private var connectedFormat: AVAudioFormat?
    private var segmentStart: AVAudioFramePosition = 0
    private var generation = 0
    private var lastTime: Double = 0
    private var isRebuilding = false
    private var lastRequestedRate: Double = 0
    nonisolated(unsafe) private var configObserver: NSObjectProtocol?

    init() {
        attachGraph()
    }

    deinit {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
    }

    var duration: Double {
        guard let file, file.processingFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    var fileSampleRate: Double { file?.processingFormat.sampleRate ?? 0 }

    var currentTime: Double {
        guard let file, file.processingFormat.sampleRate > 0 else { return 0 }
        guard isPlaying, let nodeTime = node.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return lastTime }
        let seconds = Double(segmentStart + playerTime.sampleTime) / file.processingFormat.sampleRate
        lastTime = min(max(seconds, 0), duration)
        return lastTime
    }

    func load(_ url: URL) throws {
        let newFile = try AVAudioFile(forReading: url)
        guard newFile.processingFormat.sampleRate > 0, newFile.length > 0 else {
            throw NSError(domain: "EngineBackend", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid or empty audio file"])
        }
        stopNode()
        file = newFile
        let format = newFile.processingFormat
        if bitPerfect { matchHardwareRate(format.sampleRate) }
        if connectedFormat?.sampleRate != format.sampleRate || connectedFormat?.channelCount != format.channelCount {
            connect(format)
        }
        lastTime = 0
        schedule(fromFrame: 0)
    }

    func play() {
        guard let file, file.length > 0 else { return }
        if segmentStart >= file.length {
            schedule(fromFrame: 0)
        }
        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            node.play()
            isPlaying = true
        } catch {
            isPlaying = false
            onPlaybackStateChanged?(false)
        }
    }

    func pause() {
        lastTime = currentTime
        node.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        guard let file, file.processingFormat.sampleRate > 0 else { return }
        let wasPlaying = isPlaying
        let clamped = min(max(seconds.isFinite ? seconds : 0, 0), duration)
        stopNode()
        lastTime = clamped
        let targetFrame = min(AVAudioFramePosition(clamped * file.processingFormat.sampleRate), file.length)
        schedule(fromFrame: targetFrame, fireFinishIfAtEnd: wasPlaying)
        if wasPlaying && targetFrame < file.length { play() }
    }

    func stop() {
        stopNode()
        file = nil
        lastTime = 0
        engine.pause()
    }

    func rebuildAfterMediaServicesReset() {
        let wasPlaying = isPlaying
        let position = currentTime
        stopNode()
        rebuildEngine()
        if file != nil {
            let clamped = min(max(position, 0), duration)
            lastTime = clamped
            if let file, file.processingFormat.sampleRate > 0 {
                schedule(fromFrame: AVAudioFramePosition(clamped * file.processingFormat.sampleRate))
            }
            if wasPlaying { play() }
        }
    }

    // MARK: Graph

    private func attachGraph() {
        engine.attach(node)
        engine.attach(eq)
        node.volume = 1
        engine.mainMixerNode.outputVolume = 1
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recoverFromConfigurationChange() }
        }
    }

    /// Safely stops/disconnects before mutating node bus formats (prevents Obj-C NSException).
    private func connect(_ format: AVAudioFormat) {
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }
        engine.disconnectNodeOutput(node)
        engine.disconnectNodeOutput(eq)
        engine.connect(node, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        connectedFormat = format
    }

    private func rebuildEngine() {
        isRebuilding = true
        defer { isRebuilding = false }
        engine.stop()
        engine.detach(node)
        engine.detach(eq)
        engine = AVAudioEngine()
        connectedFormat = nil
        attachGraph()
        if let format = file?.processingFormat { connect(format) }
    }

    private var isWiredOutput: Bool {
        let port = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType
        return port.map { [.usbAudio, .headphones, .lineOut, .HDMI].contains($0) } ?? false
    }

    @discardableResult
    private func matchHardwareRate(_ rate: Double) -> Bool {
        let session = AVAudioSession.sharedInstance()
        guard isWiredOutput else { return false }
        try? session.setActive(true)
        guard abs(session.sampleRate - rate) > 1 else { return false }
        lastRequestedRate = rate
        try? session.setPreferredSampleRate(rate)
        let wasPlaying = isPlaying
        let position = currentTime
        stopNode()
        rebuildEngine()
        if let file, file.processingFormat.sampleRate > 0 {
            let clamped = min(max(position, 0), duration)
            lastTime = clamped
            schedule(fromFrame: AVAudioFramePosition(clamped * file.processingFormat.sampleRate))
            if wasPlaying { play() }
        }
        onOutputChange?()
        return true
    }

    private func restoreDefaultRate() {
        let session = AVAudioSession.sharedInstance()
        guard abs(session.sampleRate - 48_000) > 1 else { return }
        lastRequestedRate = 48_000
        try? session.setPreferredSampleRate(48_000)
    }

    private func stopNode() {
        generation += 1
        node.stop()
        isPlaying = false
    }

    /// Chunks segments > UInt32.max frames (long hi-res / .m4b files) and avoids infinite 0-frame loops.
    private func schedule(fromFrame frame: AVAudioFramePosition, fireFinishIfAtEnd: Bool = true) {
        guard let file else { return }
        generation += 1
        let token = generation
        segmentStart = frame
        let remaining = file.length - frame
        guard remaining > 0 else {
            guard fireFinishIfAtEnd else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.isPlaying = false
                self.onFinish?()
            }
            return
        }

        let maxChunk = AVAudioFramePosition(UInt32.max)
        let chunkFrames = min(remaining, maxChunk)
        let nextFrame = frame + chunkFrames
        let isFinalChunk = nextFrame >= file.length

        node.scheduleSegment(file, startingFrame: frame, frameCount: AVAudioFrameCount(chunkFrames), at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                if isFinalChunk {
                    self.isPlaying = false
                    self.onFinish?()
                } else {
                    self.schedule(fromFrame: nextFrame, fireFinishIfAtEnd: true)
                    self.play()
                }
            }
        }
    }

    private func recoverFromConfigurationChange() {
        guard !isRebuilding else { return }
        defer { onOutputChange?() }
        guard let file, file.processingFormat.sampleRate > 0 else {
            rebuildEngine()
            return
        }
        let wasPlaying = isPlaying
        let position = currentTime
        // Don't auto-blast audio on built-in speaker if headphones were just unplugged.
        let outputType = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType
        let shouldResume = wasPlaying && outputType != .builtInSpeaker && outputType != .builtInReceiver
        stopNode()
        if bitPerfect && isWiredOutput, abs(AVAudioSession.sharedInstance().sampleRate - file.processingFormat.sampleRate) > 1 {
            try? AVAudioSession.sharedInstance().setPreferredSampleRate(file.processingFormat.sampleRate)
        }
        rebuildEngine()
        let clamped = min(max(position, 0), duration)
        lastTime = clamped
        schedule(fromFrame: AVAudioFramePosition(clamped * file.processingFormat.sampleRate))
        if shouldResume {
            play()
        } else if wasPlaying {
            onPlaybackStateChanged?(false)
        }
    }
}

/// AVPlayer for multichannel / Dolby Atmos files, so iOS can render them spatially
/// (with head tracking on AirPods). No EQ here.
@MainActor
final class AVPlayerBackend: PlaybackBackend {
    var onFinish: (() -> Void)?
    var onPlaybackStateChanged: ((Bool) -> Void)?
    private let player = AVPlayer()
    nonisolated(unsafe) private var endObserver: NSObjectProtocol?
    nonisolated(unsafe) private var failObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var pendingSeekTarget: Double?

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
    }

    var isPlaying: Bool {
        player.timeControlStatus == .playing || player.rate > 0
    }

    var duration: Double {
        guard let duration = player.currentItem?.duration, duration.isNumeric, duration.seconds.isFinite else { return 0 }
        return max(0, duration.seconds)
    }

    var currentTime: Double {
        if let pendingSeekTarget { return pendingSeekTarget }
        let time = player.currentTime()
        return (time.isNumeric && time.seconds.isFinite) ? max(0, time.seconds) : 0
    }

    func load(_ url: URL) throws {
        clearObservers()
        pendingSeekTarget = nil
        let item = AVPlayerItem(url: url)
        item.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onFinish?() }
        }
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onPlaybackStateChanged?(false) }
        }
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            if observed.status == .failed {
                Task { @MainActor in self?.onPlaybackStateChanged?(false) }
            }
        }
        player.replaceCurrentItem(with: item)
    }

    func play() { player.play() }
    func pause() { player.pause() }

    func seek(to seconds: Double) {
        let clamped = max(0, seconds.isFinite ? seconds : 0)
        pendingSeekTarget = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.pendingSeekTarget = nil }
        }
    }

    func stop() {
        player.pause()
        clearObservers()
        pendingSeekTarget = nil
        player.replaceCurrentItem(with: nil)
    }

    private func clearObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        endObserver = nil
        failObserver = nil
    }
}
