import ActivityKit
import Combine
import Foundation
import SoulseekKit
import UserNotifications

/// Mantiene descargas en segundo plano, muestra únicamente el widget Live Activity y gestiona el Auto-Retry
@MainActor
final class TransferMonitor {
    private let soulseek: SoulseekModel
    private let player: Player
    private weak var stats: StatsStore?
    private let keeper = BackgroundKeeper()
    private var subscriptions = Set<AnyCancellable>()
    private var heartbeat: Timer?
    private var lastReconnect = Date.distantPast

    /// Estado del widget Live Activity en Pantalla de Bloqueo / Dynamic Island
    private var activity: Activity<TransferActivityAttributes>?
    private var lastSampleReceived: UInt64 = 0
    private var lastSampleTime = Date()
    private var currentSpeedBytesPerSec: Double = 0

    private var notifiedCompletedIDs = Set<DownloadID>()
    private var initializedCompleted = false

    /// Control de Reintentos Automáticos (Auto-Retry)
    private var retryCounts: [DownloadID: Int] = [:]
    private var pendingRetryTimers: [DownloadID: Task<Void, Never>] = [:]

    init(soulseek: SoulseekModel, player: Player, stats: StatsStore) {
        self.soulseek = soulseek
        self.player = player
        self.stats = stats

        requestNotificationPermission()

        // Limpia cualquier notificación antigua y actividades huérfanas al iniciar
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["seekios.transfer.progress"])
        for stale in Activity<TransferActivityAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }

        for item in soulseek.downloads {
            if case .completed = item.state {
                notifiedCompletedIDs.insert(item.id)
            }
        }
        initializedCompleted = true

        soulseek.$downloads
            .combineLatest(soulseek.$uploads, player.$isPlaying)
            .throttle(for: .seconds(1.0), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _, _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            .store(in: &subscriptions)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            .store(in: &subscriptions)

        heartbeat = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var isSeeding: Bool { AppSettings.seedingEnabled }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func refresh() {
        update(downloads: soulseek.downloads, uploads: soulseek.uploads, isPlaying: player.isPlaying)
    }

    private func update(downloads: [DownloadItem], uploads: [UploadItem], isPlaying: Bool) {
        let visible = downloads.filter { !$0.isArtwork }
        let activeDownloads = visible.filter { $0.isActive }
        let sending = uploads.filter { $0.state == .transferring }
        let busy = !activeDownloads.isEmpty || !sending.isEmpty
        let seeding = isSeeding && soulseek.hasCredentials

        if seeding, !soulseek.isLoggedIn, Date().timeIntervalSince(lastReconnect) > 60 {
            lastReconnect = Date()
            soulseek.reconnectIfNeeded()
        }

        let wantsKeeper = (busy && AppSettings.flag(AppSettings.backgroundTransfersKey)) || seeding
        if wantsKeeper, !isPlaying {
            keeper.start()
        } else {
            keeper.stop()
        }

        updateLiveActivity(
            activeDownloads: activeDownloads,
            sending: sending,
            seeding: seeding
        )
        notifyNewlyCompletedDownloads(downloads)
        handleAutoRetry(downloads)
    }

    // MARK: - Widget Live Activity (Único cartel en Pantalla de Bloqueo y Dynamic Island)

    private func updateLiveActivity(
        activeDownloads: [DownloadItem],
        sending: [UploadItem],
        seeding: Bool
    ) {
        let showActivitySetting = AppSettings.flag(AppSettings.transferActivityKey)
        let hasActiveTransfers = !activeDownloads.isEmpty || !sending.isEmpty

        guard hasActiveTransfers && showActivitySetting && ActivityAuthorizationInfo().areActivitiesEnabled else {
            lastSampleReceived = 0
            currentSpeedBytesPerSec = 0
            if let currentActivity = activity {
                self.activity = nil
                Task { await currentActivity.end(nil, dismissalPolicy: .immediate) }
            }
            return
        }

        let transferringCount = activeDownloads.filter {
            switch $0.state {
            case .starting, .transferring: return true
            default: return false
            }
        }.count
        let queuedCount = max(0, activeDownloads.count - transferringCount)

        let totalSize = activeDownloads.reduce(UInt64(0)) { $0 + $1.size }
        let totalReceived = activeDownloads.reduce(UInt64(0)) { $0 + min($1.received, $1.size) }
        let fraction = totalSize > 0 ? min(1.0, Double(totalReceived) / Double(totalSize)) : 0.0

        let now = Date()
        let elapsed = now.timeIntervalSince(lastSampleTime)
        if elapsed >= 0.8 {
            if totalReceived >= lastSampleReceived && lastSampleReceived > 0 {
                let delta = Double(totalReceived - lastSampleReceived)
                currentSpeedBytesPerSec = max(0, delta / elapsed)
            } else {
                currentSpeedBytesPerSec = 0
            }
            lastSampleReceived = totalReceived
            lastSampleTime = now
        }

        let state = TransferActivityAttributes.ContentState(
            downloading: max(transferringCount, activeDownloads.isEmpty ? 0 : 1),
            uploading: sending.count,
            queued: queuedCount,
            fraction: fraction,
            bytesPerSecond: currentSpeedBytesPerSec,
            currentFile: activeDownloads.first?.filename ?? sending.first?.filename ?? "Transferring…",
            finished: false,
            seeding: seeding ? 1 : 0
        )

        if let currentActivity = activity {
            Task {
                await currentActivity.update(ActivityContent(state: state, staleDate: nil))
            }
        } else {
            let accentHex = UserDefaults.standard.string(forKey: AccentPalette.storageKey) ?? AccentPalette.defaultHex
            do {
                activity = try Activity.request(
                    attributes: TransferActivityAttributes(accentHex: accentHex),
                    content: ActivityContent(state: state, staleDate: nil),
                    pushType: nil
                )
            } catch {}
        }
    }

    // MARK: - Auto-Retry Inteligente

    private func handleAutoRetry(_ downloads: [DownloadItem]) {
        for item in downloads where !item.isArtwork {
            let itemID = item.id
            switch item.state {
            case .failed:
                let attempts = retryCounts[itemID, default: 0]
                if attempts < 3 && pendingRetryTimers[itemID] == nil {
                    pendingRetryTimers[itemID] = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 120_000_000_000)
                        guard let self = self else { return }
                        self.retryCounts[itemID] = attempts + 1
                        self.pendingRetryTimers.removeValue(forKey: itemID)
                        self.soulseek.retry(item)
                    }
                }
            case .completed:
                retryCounts.removeValue(forKey: itemID)
                pendingRetryTimers[itemID]?.cancel()
                pendingRetryTimers.removeValue(forKey: itemID)
            default:
                break
            }
        }
    }

    // MARK: - Aviso Final al Completar Descarga

    private func notifyNewlyCompletedDownloads(_ downloads: [DownloadItem]) {
        guard initializedCompleted else { return }
        var newlyFinished: [DownloadItem] = []

        for item in downloads where !item.isArtwork {
            if case .completed = item.state {
                if !notifiedCompletedIDs.contains(item.id) {
                    notifiedCompletedIDs.insert(item.id)
                    newlyFinished.append(item)
                }
            } else {
                notifiedCompletedIDs.remove(item.id)
            }
        }

        guard !newlyFinished.isEmpty else { return }

        let content = UNMutableNotificationContent()
        if newlyFinished.count == 1, let first = newlyFinished.first {
            content.title = "Download Complete"
            content.body = "\(first.filename) (\(Formatting.bytes(first.size)))"
        } else if let first = newlyFinished.first {
            content.title = "\(newlyFinished.count) Downloads Complete"
            content.body = "\(first.filename) and \(newlyFinished.count - 1) more finished."
        }
        content.sound = .default

        let req = UNNotificationRequest(
            identifier: "seekios.done.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }
}
