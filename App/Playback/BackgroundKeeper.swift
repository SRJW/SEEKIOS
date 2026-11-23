import AVFoundation
import Foundation

/// Keeps the sideloaded app alive in the background while Soulseek transfers or Seeding Mode run
/// and no music is playing, by looping an in-memory silent WAV. Session category/activation is owned
/// by `AudioSessionCoordinator` so Lock Screen controls stay intact.
@MainActor
final class BackgroundKeeper {
    private var silence: AVAudioPlayer?
    private(set) var isRunning = false

    var isActivelyPlaying: Bool {
        silence?.isPlaying ?? false
    }

    func start(forceRestart: Bool = false) {
        if isRunning && !forceRestart && isActivelyPlaying { return }
        if silence == nil {
            silence = try? AVAudioPlayer(data: Self.silentWAV())
            silence?.numberOfLoops = -1
            silence?.volume = 0
            silence?.prepareToPlay()
        }
        isRunning = silence?.play() ?? false
    }

    func stop() {
        guard isRunning || isActivelyPlaying else { return }
        silence?.stop()
        isRunning = false
    }

    func resetAfterMediaServicesReset() {
        silence?.stop()
        silence = nil
        isRunning = false
    }

    /// One second of 8 kHz, 16-bit mono silence as an in-memory WAV file.
    private static func silentWAV() -> Data {
        let sampleRate: UInt32 = 8000
        let dataSize: UInt32 = sampleRate * 2
        var data = Data()
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append("RIFF"); append32(36 + dataSize); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(sampleRate); append32(sampleRate * 2); append16(2); append16(16)
        append("data"); append32(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }
}
