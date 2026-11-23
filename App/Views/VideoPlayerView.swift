import AVFoundation
import AVKit
import SwiftUI
import UIKit

enum VideoFileSupport {
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "avi", "webm", "ts", "3gp"]

    static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    static func isVideoExtension(_ ext: String) -> Bool {
        videoExtensions.contains(ext.lowercased())
    }
}

struct VideoPlaybackItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// Built-in native iOS video player (AVPlayerViewController) with Picture-in-Picture, AirPlay,
/// playback speed controls, and a clean fallback for non-native containers like MKV/AVI.
struct VideoPlayerSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var player: Player

    @State private var avPlayer: AVPlayer?
    @State private var loadError: String?
    @State private var statusObservation: NSKeyValueObservation?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let loadError {
                VStack(spacing: 16) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 46))
                        .foregroundStyle(.secondary)
                    Text(url.lastPathComponent)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Text(loadError)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)

                    ShareLink(item: url) {
                        Label("Open in VLC / External Player…", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Close") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
            } else if let avPlayer {
                NativeVideoPlayerController(player: avPlayer)
                    .ignoresSafeArea()
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .overlay(alignment: .topLeading) {
            if loadError == nil {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.black.opacity(0.55))
                        .padding(16)
                }
                .accessibilityLabel("Close Video")
            }
        }
        .onAppear {
            startPlayback()
        }
        .onDisappear {
            stopPlayback()
        }
    }

    private func startPlayback() {
        // Pause Seekios music playback so audio sessions don't overlap.
        if player.isPlaying {
            player.pause()
        }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.allowsExternalPlayback = true

        statusObservation = item.observe(\.status, options: [.new, .initial]) { observed, _ in
            Task { @MainActor in
                switch observed.status {
                case .readyToPlay:
                    loadError = nil
                case .failed:
                    let ext = url.pathExtension.uppercased()
                    let detail = observed.error?.localizedDescription ?? "Unsupported video format."
                    loadError = "iOS cannot natively play this .\(ext) file (\(detail)). You can open it directly in VLC, Infuse, or another player."
                default:
                    break
                }
            }
        }

        avPlayer = newPlayer
        newPlayer.play()
    }

    private func stopPlayback() {
        statusObservation?.invalidate()
        statusObservation = nil
        avPlayer?.pause()
        avPlayer?.replaceCurrentItem(with: nil)
        avPlayer = nil
        AudioSessionCoordinator.shared.updatePlaybackState(
            isPlaying: player.isPlaying,
            hasTrack: player.current != nil
        )
    }
}

private struct NativeVideoPlayerController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.exitsFullScreenWhenPlaybackEnds = false
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
    }
}
