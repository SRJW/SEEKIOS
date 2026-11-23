import Foundation
import Security

/// Ensures Application Support exists on fresh iOS installs and resolves `/var` vs `/private/var`.
enum AppDirectories {
    static var applicationSupport: URL {
        if let url = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            return url
        }
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    static func ensureParentDirectory(for fileURL: URL) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}

extension URL {
    /// Canonical filesystem path resolving symlinks (`/var` -> `/private/var`) and lexical `..`.
    var canonicalFileURL: URL {
        resolvingSymlinksInPath().standardizedFileURL
    }

    var canonicalPath: String {
        canonicalFileURL.path
    }

    func isContained(in directory: URL) -> Bool {
        let rootPath = directory.canonicalPath
        let targetPath = canonicalPath
        return targetPath == rootPath || targetPath.hasPrefix(rootPath + "/")
    }
}

/// Password storage. Works with free-account sideloading (no extra entitlements needed).
enum Keychain {
    static let soulseekService = "colon3.soulseek"

    @discardableResult
    static func save(_ value: String, account: String, service: String = soulseekService) -> Bool {
        guard !account.isEmpty else { return false }
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus != errSecItemNotFound {
            SecItemDelete(query as CFDictionary)
        }
        var insert = query
        insert[kSecValueData] = data
        insert[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        if addStatus != errSecSuccess {
            Diagnostics.shared.log("Keychain save failed (status \(addStatus))", category: "security")
            return false
        }
        return true
    }

    static func load(account: String, service: String = soulseekService) -> String? {
        guard !account.isEmpty else { return nil }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String, service: String = soulseekService) {
        guard !account.isEmpty else { return }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum Formatting {
    @MainActor
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }

    static func speed(_ bytesPerSecond: UInt32) -> String {
        bytes(UInt64(bytesPerSecond)) + "/s"
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "" }
        let clamped = min(bytesPerSecond, Double(UInt64.max / 2))
        return bytes(UInt64(clamped)) + "/s"
    }

    static func eta(remainingBytes: UInt64, bytesPerSecond: Double) -> String? {
        guard remainingBytes > 0, bytesPerSecond.isFinite, bytesPerSecond >= 256 else { return nil }
        let seconds = Double(remainingBytes) / bytesPerSecond
        guard seconds.isFinite, seconds >= 1, seconds < 86_400 * 7 else { return nil }
        let total = Int(seconds.rounded())
        if total >= 3600 {
            return "\(total / 3600)h \((total % 3600) / 60)m"
        }
        if total >= 60 {
            return "\(total / 60)m \(total % 60)s"
        }
        return "\(total)s"
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds <= Double(Int.max / 2) else { return "--:--" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "1 hr 12 min" / "42 minutes".
    static func longDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds <= Double(Int.max / 2) else { return "0 minutes" }
        let total = Int(seconds / 60)
        return total >= 60 ? "\(total / 60) hr \(total % 60) min" : "\(total) minute\(total == 1 ? "" : "s")"
    }

    /// "3.2 h" / "45 min" for listening totals.
    static func hours(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds <= Double(Int.max / 2) else { return "0 min" }
        if seconds >= 3600 { return String(format: "%.1f h", seconds / 3600) }
        return "\(Int(seconds / 60)) min"
    }

    static func sampleRate(_ hertz: Double) -> String {
        guard hertz.isFinite, hertz > 0, hertz <= Double(UInt32.max) else { return "–" }
        return kilohertz(UInt32(hertz.rounded())) + " kHz"
    }

    static func kilohertz(_ hertz: UInt32) -> String {
        let value = Double(hertz) / 1000
        return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// How completed downloads are organized inside the chosen download folder (Nicotine+-style).
enum DownloadFolderStructure: String, CaseIterable, Identifiable {
    case album = "album"
    case userAndAlbum = "userAndAlbum"
    case flat = "flat"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .album: return "Album Folder"
        case .userAndAlbum: return "User / Album"
        case .flat: return "Flat (No Subfolders)"
        }
    }

    var example: String {
        switch self {
        case .album: return "Downloads/Album/01 Track.flac"
        case .userAndAlbum: return "Downloads/peer/Album/01 Track.flac"
        case .flat: return "Downloads/01 Track.flac"
        }
    }
}

/// User-facing switches, stored in UserDefaults so views can bind with @AppStorage.
enum AppSettings {
    static let artworkLookupKey = "artworkLookup"
    static let lyricsLookupKey = "lyricsLookup"
    static let backgroundTransfersKey = "backgroundTransfers"
    static let transferActivityKey = "transferLiveActivity"
    static let showMissingKey = "showMissingSongs"
    static let musicBrainzKey = "musicBrainzLookup"
    /// Defaults to off.
    static let bitPerfectKey = "bitPerfect"
    static let seedingKey = "seedingMode"
    /// Sharing & privacy on iPhone: opt-in by default to protect battery, cellular data, and privacy.
    static let sharingEnabledKey = "slsk.sharingEnabled"
    static let shareOnWiFiOnlyKey = "slsk.shareOnWiFiOnly"
    /// Download folder organization & iOS Library integration.
    static let keepAudioInLibraryKey = "slsk.keepAudioInLibrary"
    static let downloadFolderStructureKey = "slsk.downloadFolderStructure"
    /// Transfer & Soulseek tuning (Nicotine+-style controls).
    static let maxConcurrentDownloadsKey = "slsk.maxConcurrentDownloads"
    static let maxConcurrentUploadsKey = "slsk.maxConcurrentUploads"
    static let maxQueuedPerPeerKey = "slsk.maxQueuedPerPeer"
    static let distributedSearchKey = "slsk.distributedSearch"

    static var artworkLookupEnabled: Bool { flag(artworkLookupKey) }
    static var lyricsLookupEnabled: Bool { flag(lyricsLookupKey) }
    static var sharingEnabled: Bool { UserDefaults.standard.bool(forKey: sharingEnabledKey) }
    static var shareOnWiFiOnly: Bool { flag(shareOnWiFiOnlyKey) }
    static var keepAudioInLibrary: Bool { flag(keepAudioInLibraryKey) }
    static var seedingEnabled: Bool { UserDefaults.standard.bool(forKey: seedingKey) }
    static var distributedSearchEnabled: Bool { flag(distributedSearchKey) }

    static var downloadFolderStructure: DownloadFolderStructure {
        guard let raw = UserDefaults.standard.string(forKey: downloadFolderStructureKey),
              let value = DownloadFolderStructure(rawValue: raw) else {
            return .album
        }
        return value
    }

    static var maxConcurrentDownloads: Int {
        let value = UserDefaults.standard.integer(forKey: maxConcurrentDownloadsKey)
        return value > 0 ? min(max(value, 1), 16) : 4
    }

    static var maxConcurrentUploads: Int {
        let value = UserDefaults.standard.integer(forKey: maxConcurrentUploadsKey)
        return value > 0 ? min(max(value, 1), 8) : 2
    }

    static var maxQueuedPerPeer: Int {
        let value = UserDefaults.standard.integer(forKey: maxQueuedPerPeerKey)
        return value > 0 ? min(max(value, 1), 50) : 10
    }

    /// Most switches default to on.
    static func flag(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

enum HTTP {
    static var userAgent: String {
        "Seekios/\(Bundle.appVersion) (https://github.com/SRJW/SEEKIOS)"
    }
}
