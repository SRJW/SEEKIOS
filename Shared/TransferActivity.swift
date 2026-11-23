import ActivityKit
import Foundation

/// Live Activity for Soulseek transfers, shown in the Dynamic Island and on the Lock Screen while
/// downloads, uploads, or Seeding Mode run. Compiled into both the app and the widget.
struct TransferActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var downloading: Int
        var uploading: Int
        var queued: Int
        /// Overall progress of the active transfers, 0...1.
        var fraction: Double
        var bytesPerSecond: Double
        /// The file currently moving, if any.
        var currentFile: String
        var finished: Bool
        /// Songs shared while Seeding Mode keeps the app up; 0 when not seeding.
        var seeding: Int = 0
        /// Bytes uploaded since the app started.
        var sessionUploaded: Double = 0

        var clampedFraction: Double {
            guard fraction.isFinite else { return 0 }
            return min(max(fraction, 0), 1)
        }

        /// Nothing moving, just staying online to share.
        var isIdleSeeding: Bool { seeding > 0 && downloading == 0 && uploading == 0 && queued == 0 && !finished }

        var title: String {
            if finished { return "Transfers finished" }
            if isIdleSeeding { return "Seeding \(seeding) song\(seeding == 1 ? "" : "s")" }
            var parts: [String] = []
            if downloading > 0 { parts.append("\(downloading) down") }
            if uploading > 0 { parts.append("\(uploading) up") }
            if parts.isEmpty, queued > 0 { return "\(queued) waiting in queue\(queued == 1 ? "" : "s")" }
            return parts.isEmpty ? "Transfers" : parts.joined(separator: " · ")
        }

        var percentText: String {
            "\(Int((clampedFraction * 100).rounded()))%"
        }

        /// Compact island text: progress while transferring, total sent while seeding.
        var compactText: String {
            guard isIdleSeeding else { return percentText }
            guard sessionUploaded.isFinite, sessionUploaded > 0 else { return "On" }
            let clamped = min(sessionUploaded, Double(Int64.max / 2))
            return "↑" + ByteCountFormatter.string(fromByteCount: Int64(clamped), countStyle: .file)
        }

        var speedText: String {
            guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "" }
            let clamped = min(bytesPerSecond, Double(Int64.max / 2))
            return ByteCountFormatter.string(fromByteCount: Int64(clamped), countStyle: .file) + "/s"
        }

        var symbol: String {
            if finished { return "checkmark.circle.fill" }
            if isIdleSeeding { return "leaf.circle.fill" }
            if downloading > 0 && uploading > 0 { return "arrow.up.arrow.down.circle.fill" }
            return uploading > 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
        }
    }

    /// The app's accent colour at the time the activity started.
    var accentHex: String
}
