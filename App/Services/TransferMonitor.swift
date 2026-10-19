import ActivityKit
import Combine
import Foundation
import SoulseekKit
import UserNotifications

/// Mantiene las transferencias activas en segundo plano y envía una notificación únicamente cuando finalizan.
@MainActor
final class TransferMonitor {
    private let soulseek: SoulseekModel
    private let player: Player
    private weak var stats: StatsStore?
    private let keeper = BackgroundKeeper()
    private var activity: Activity<TransferActivityAttributes>?
    private var subscriptions = Set<AnyCancellable>()
    private var heartbeat: Timer?
    private var lastReconnect = Date.distantPast

    private var lastBytes: UInt64 = 0
    private var lastSample = Date()
    private var speed: Double = 0

    /// Registro de descargas ya notificadas para avisar solo cuando cada archivo finaliza
    private var notifiedCompletedIDs = Set<DownloadID>()
    private var initializedCompleted = false

    private struct Progress { var done: UInt64; var size: UInt64 }
    private var downloadBatch: [DownloadID: Progress] = [:]
    private var uploadBatch: [DownloadID: Progress] = [:]

    init(soulseek: SoulseekModel, player: Player, stats: StatsStore) {
        self.soulseek = soulseek
        self.player = player
        self.stats = stats

        requestNotificationPermission()

        // Limpia cualquier notificación de progreso vieja o Live Activity previa
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["seekios.transfer.progress"])
        for stale in Activity<TransferActivityAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }

        // Registra las que ya estaban completadas en el historial al abrir la app para no re-notificarlas
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

        // Verifica si alguna descarga acaba de finalizar y envía la notificación
        notifyNewlyCompletedDownloads(downloads)
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
                // Si se reintenta una descarga, permite volver a notificar cuando termine
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
