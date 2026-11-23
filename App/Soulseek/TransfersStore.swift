import Foundation
import SoulseekKit

/// Persisted download history record (stored in Application Support/downloads-history.json).
struct SavedHistoryItem: Codable {
    let username: String
    let path: String
    let size: UInt64
    let received: UInt64?
    let isCompleted: Bool
    let isPaused: Bool?
    let urlPath: String?
    let libraryURLPath: String?
}

struct DownloadItem: Identifiable, Equatable {
    let id: DownloadID
    let filename: String
    let folderPath: String
    let leafFolder: String
    let fileExtension: String
    var state: DownloadState
    var received: UInt64
    var size: UInt64
    var bytesPerSecond: Double
    /// Original URL inside Documents/Music when audio is also copied to a custom export folder.
    var libraryURL: URL?

    init(
        id: DownloadID,
        state: DownloadState,
        received: UInt64,
        size: UInt64,
        bytesPerSecond: Double = 0,
        libraryURL: URL? = nil
    ) {
        self.id = id
        let shared = SharedFile(path: id.path, size: size)
        self.filename = shared.filename
        self.folderPath = shared.folder
        self.leafFolder = shared.folderName.isEmpty ? id.username : shared.folderName
        self.fileExtension = shared.fileExtension.lowercased()
        self.state = state
        self.received = received
        self.size = size
        self.bytesPerSecond = bytesPerSecond
        self.libraryURL = libraryURL
    }

    var isArtwork: Bool { false }

    var progress: Double {
        size > 0 ? min(1, Double(received) / Double(size)) : 0
    }

    var remainingBytes: UInt64 {
        size > received ? size - received : 0
    }

    var etaText: String? {
        guard state == .transferring else { return nil }
        return Formatting.eta(remainingBytes: remainingBytes, bytesPerSecond: bytesPerSecond)
    }

    var isActive: Bool {
        switch state {
        case .requesting, .queued, .starting, .transferring: return true
        case .paused, .completed, .failed: return false
        }
    }

    var isTransferring: Bool {
        switch state {
        case .starting, .transferring: return true
        default: return false
        }
    }

    var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    var isCompleted: Bool {
        if case .completed = state { return true }
        return false
    }
}

struct UploadItem: Identifiable, Equatable {
    let id: DownloadID
    let filename: String
    var state: UploadState
    var sent: UInt64
    var size: UInt64
    var bytesPerSecond: Double

    init(id: DownloadID, state: UploadState, sent: UInt64, size: UInt64, bytesPerSecond: Double = 0) {
        self.id = id
        self.filename = SharedFile(path: id.path, size: size).filename
        self.state = state
        self.sent = sent
        self.size = size
        self.bytesPerSecond = bytesPerSecond
    }

    var progress: Double { size > 0 ? min(1, Double(sent) / Double(size)) : 0 }
    var isActive: Bool { state == .queued || state == .transferring }
}

/// Dedicated observable store for transfers so 0.4s download progress ticks never invalidate
/// SearchView, LibraryView, StatsView, SettingsView, or ContentView.
@MainActor
final class TransfersStore: ObservableObject {
    @Published private(set) var downloads: [DownloadItem] = []
    @Published private(set) var uploads: [UploadItem] = []
    @Published private(set) var activeDownloadCount: Int = 0
    @Published private(set) var activeUploadCount: Int = 0
    @Published private(set) var totalDownloadSpeed: Double = 0
    @Published private(set) var totalUploadSpeed: Double = 0

    private var indexByID: [DownloadID: Int] = [:]
    private let saveQueue = DispatchQueue(label: "seekios.transfers-history")
    private var pendingSaveTask: Task<Void, Never>?
    private let historyURL = AppDirectories.applicationSupport.appendingPathComponent("downloads-history.json")
    private let legacyDefaultsKey = "downloads_history_v2"

    var visibleDownloads: [DownloadItem] { downloads }

    func state(of file: SharedFile, from username: String) -> DownloadState? {
        let id = DownloadID(username: username, path: file.path)
        guard let idx = indexByID[id], downloads.indices.contains(idx) else { return nil }
        return downloads[idx].state
    }

    func item(for id: DownloadID) -> DownloadItem? {
        guard let idx = indexByID[id], downloads.indices.contains(idx) else { return nil }
        return downloads[idx]
    }

    func loadHistory(client: SoulseekClient) {
        var decoded: [SavedHistoryItem]?
        if let data = try? Data(contentsOf: historyURL) {
            decoded = try? JSONDecoder().decode([SavedHistoryItem].self, from: data)
        } else if let legacy = UserDefaults.standard.data(forKey: legacyDefaultsKey) {
            decoded = try? JSONDecoder().decode([SavedHistoryItem].self, from: legacy)
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        }
        guard let history = decoded else { return }

        downloads = history.map { saved in
            let id = DownloadID(username: saved.username, path: saved.path)
            if saved.isCompleted, let urlPath = saved.urlPath {
                return DownloadItem(
                    id: id,
                    state: .completed(URL(fileURLWithPath: urlPath)),
                    received: saved.size,
                    size: saved.size,
                    libraryURL: saved.libraryURLPath.map { URL(fileURLWithPath: $0) }
                )
            } else {
                let onDisk = client.partialBytesOnDisk(username: saved.username, path: saved.path)
                let rec = max(onDisk, saved.received ?? 0)
                let clamped = saved.size > 0 ? min(rec, saved.size) : rec
                client.restoreInterruptedDownload(username: saved.username, path: saved.path, size: saved.size)
                return DownloadItem(
                    id: id,
                    state: .paused,
                    received: clamped,
                    size: saved.size
                )
            }
        }
        rebuildIndexAndSummaries()
        scheduleSave(immediate: true)
    }

    func applyDownloadUpdate(
        _ update: DownloadUpdate,
        finalState: DownloadState,
        libraryURL: URL? = nil
    ) {
        let stateChanged: Bool
        if let idx = indexByID[update.id], downloads.indices.contains(idx) {
            stateChanged = downloads[idx].state != finalState
            downloads[idx].state = finalState
            downloads[idx].received = update.received
            downloads[idx].size = update.size
            downloads[idx].bytesPerSecond = update.bytesPerSecond
            if let libraryURL { downloads[idx].libraryURL = libraryURL }
        } else {
            stateChanged = true
            downloads.insert(
                DownloadItem(
                    id: update.id,
                    state: finalState,
                    received: update.received,
                    size: update.size,
                    bytesPerSecond: update.bytesPerSecond,
                    libraryURL: libraryURL
                ),
                at: 0
            )
            rebuildIndex()
        }
        recomputeSummaries()
        // Persist immediately on state transitions, or debounced (5s) during active byte transfer.
        scheduleSave(immediate: stateChanged)
    }

    func applyUploadUpdate(_ update: UploadUpdate) {
        if let idx = uploads.firstIndex(where: { $0.id == update.id }) {
            uploads[idx].state = update.state
            uploads[idx].sent = update.sent
            uploads[idx].size = update.size
            uploads[idx].bytesPerSecond = update.bytesPerSecond
        } else {
            uploads.insert(
                UploadItem(
                    id: update.id,
                    state: update.state,
                    sent: update.sent,
                    size: update.size,
                    bytesPerSecond: update.bytesPerSecond
                ),
                at: 0
            )
            if uploads.count > 100 { uploads.removeLast(uploads.count - 100) }
        }
        recomputeSummaries()
    }

    func removeDownloads(_ ids: Set<DownloadID>) {
        guard !ids.isEmpty else { return }
        downloads.removeAll { ids.contains($0.id) }
        rebuildIndexAndSummaries()
        scheduleSave(immediate: true)
    }

    func clearFinishedUploads() {
        uploads.removeAll { !$0.isActive }
        recomputeSummaries()
    }

    func removeUpload(_ id: DownloadID) {
        uploads.removeAll { $0.id == id }
        recomputeSummaries()
    }

    private func rebuildIndex() {
        indexByID.removeAll(keepingCapacity: true)
        for (idx, item) in downloads.enumerated() {
            indexByID[item.id] = idx
        }
    }

    private func rebuildIndexAndSummaries() {
        rebuildIndex()
        recomputeSummaries()
    }

    private func recomputeSummaries() {
        var activeDown = 0
        var downSpeed: Double = 0
        for item in downloads {
            if item.isActive { activeDown += 1 }
            if item.state == .transferring { downSpeed += item.bytesPerSecond }
        }
        var activeUp = 0
        var upSpeed: Double = 0
        for item in uploads {
            if item.isActive { activeUp += 1 }
            if item.state == .transferring { upSpeed += item.bytesPerSecond }
        }
        if activeDownloadCount != activeDown { activeDownloadCount = activeDown }
        if activeUploadCount != activeUp { activeUploadCount = activeUp }
        totalDownloadSpeed = downSpeed
        totalUploadSpeed = upSpeed
    }

    private func scheduleSave(immediate: Bool) {
        if immediate {
            pendingSaveTask?.cancel()
            pendingSaveTask = nil
            persistNow()
            return
        }
        guard pendingSaveTask == nil else { return }
        pendingSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingSaveTask = nil
            self.persistNow()
        }
    }

    func persistNow() {
        let snapshot: [SavedHistoryItem] = downloads.map { item in
            switch item.state {
            case let .completed(url):
                return SavedHistoryItem(
                    username: item.id.username,
                    path: item.id.path,
                    size: item.size,
                    received: item.size,
                    isCompleted: true,
                    isPaused: false,
                    urlPath: url.path,
                    libraryURLPath: item.libraryURL?.path
                )
            case .paused:
                return SavedHistoryItem(
                    username: item.id.username,
                    path: item.id.path,
                    size: item.size,
                    received: item.received,
                    isCompleted: false,
                    isPaused: true,
                    urlPath: nil,
                    libraryURLPath: nil
                )
            default:
                return SavedHistoryItem(
                    username: item.id.username,
                    path: item.id.path,
                    size: item.size,
                    received: item.received,
                    isCompleted: false,
                    isPaused: false,
                    urlPath: nil,
                    libraryURLPath: nil
                )
            }
        }
        let targetURL = historyURL
        saveQueue.async {
            AppDirectories.ensureParentDirectory(for: targetURL)
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: targetURL, options: .atomic)
            }
        }
    }
}
