import ActivityKit
import Combine
import Foundation
import SoulseekKit
import UserNotifications

/// Mantiene descargas en segundo plano, envía notificaciones al terminar y gestiona el Auto-Retry
@MainActor
final class TransferMonitor {
    private let soulseek: SoulseekModel
    private let player: Player
    private weak var stats: StatsStore?
    private let keeper = BackgroundKeeper()
    private var subscriptions = Set<AnyCancellable>()
    private var heartbeat: Timer?
    private var lastReconnect = Date.distantPast

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
        let activeDownloads = downloads.filter { $0.isActive && !$0.isArtwork }
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

        notifyNewlyCompletedDownloads(downloads)
        handleAutoRetry(downloads)
    }

    private func handleAutoRetry(_ downloads: [DownloadItem]) {
        for item in downloads where !item.isArtwork {
            switch item.state {
            case .failed:
                let id = item.id
                let attempts = retryCounts[id, default: 0]
                if attempts < 3 && pendingRetryTimers[id] == nil {
                    // Programa reintento automático tras 2 minutos (120 segundos)
                    pendingRetryTimers[id] = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 120_000_000_000)
                        guard let self = self else { return }
                        self.retryCounts[id] = attempts + 1
                        self.pendingRetryTimers.removeValue(forKey: id)
                        self.soulseek.retry(item)
                    }
                }
            case .completed:
                retryCounts.removeValue(forKey: item.id)
                pendingRetryTimers[id]?.cancel()
                pendingRetryTimers.removeValue(forKey: item.id)
            default:
                break
            }
        }
    }

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
