import ActivityKit
import Combine
import Foundation
import SoulseekKit
import UserNotifications

/// Mantiene descargas en segundo plano, muestra la barra de progreso en Live Activity / Notificaciones y gestiona el Auto-Retry
@MainActor
final class TransferMonitor {
    private let soulseek: SoulseekModel
    private let player: Player
    private weak var stats: StatsStore?
    private let keeper = BackgroundKeeper()
    private var subscriptions = Set<AnyCancellable>()
    private var heartbeat: Timer?
    private var lastReconnect = Date.distantPast

    /// Estado de la barra de progreso en Pantalla de Bloqueo / Dynamic Island y Notificaciones
    private var activity: Activity<TransferActivityAttributes>?
    private var lastProgressNotificationText: String = ""
    private var lastProgressNotificationDate = Date.distantPast

    private var notifiedCompletedIDs = Set<DownloadID>()
    private var initializedCompleted = false

    /// Control de Reintentos Automáticos (Auto-Retry)
    private var retryCounts: [DownloadID: Int] = [:]
    private var pendingRetryTimers: [DownloadID: Task<Void, Never>] = [:]

    private let progressNotificationID = "seekios.transfer.progress"

    init(soulseek: SoulseekModel, player: Player, stats: StatsStore) {
        self.soulseek = soulseek
        self.player = player
        self.stats = stats

        requestNotificationPermission()

        // Limpia actividades huérfanas de sesiones anteriores al iniciar la app
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [progressNotificationID])
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

        updateLiveActivityAndProgressNotification(activeDownloads: activeDownloads, sending: sending, seeding: seeding)
        notifyNewlyCompletedDownloads(downloads)
        handleAutoRetry(downloads)
    }

    // MARK: - Barra de progreso en Live Activity (Pantalla de Bloqueo / Dynamic Island) y Centro de Notificaciones

    private func updateLiveActivityAndProgressNotification(
        activeDownloads: [DownloadItem],
        sending: [UploadItem],
        seeding: Bool
    ) {
        let showActivitySetting = AppSettings.flag(AppSettings.transferActivityKey)
        let hasActiveTransfers = !activeDownloads.isEmpty || !sending.isEmpty

        guard hasActiveTransfers else {
            // Si ya no hay descargas ni subidas en curso, cierra la barra de progreso
            if let currentActivity = activity {
                self.activity = nil
                Task { await currentActivity.end(nil, dismissalPolicy: .immediate) }
            }
            if !lastProgressNotificationText.isEmpty {
                lastProgressNotificationText = ""
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [progressNotificationID])
            }
            return
        }

        let totalSize = activeDownloads.reduce(UInt64(0)) { $0 + $1.size }
        let totalReceived = activeDownloads.reduce(UInt64(0)) { $0 + min($1.received, $1.size) }
        let fraction = totalSize > 0 ? min(1.0, Double(totalReceived) / Double(totalSize)) : 0.0
        let percent = Int((fraction * 100).rounded())

        let state = TransferActivityAttributes.ContentState(
            downloading: activeDownloads.count,
            uploading: sending.count,
            progress: fraction,
            receivedBytes: Int64(totalReceived),
            totalBytes: Int64(totalSize),
            currentTitle: activeDownloads.first?.filename ?? sending.first?.filename ?? "Transferring…",
            seeding: seeding
        )

        // 1. Actualiza o inicia el widget Live Activity con barra de progreso real en Pantalla de Bloqueo y Dynamic Island
        if showActivitySetting && ActivityAuthorizationInfo().areActivitiesEnabled {
            if let currentActivity = activity {
                Task {
                    await currentActivity.update(ActivityContent(state: state, staleDate: nil))
                }
            } else {
                do {
                    activity = try Activity.request(
                        attributes: TransferActivityAttributes(),
                        content: ActivityContent(state: state, staleDate: nil),
                        pushType: nil
                    )
                } catch {
                    // Si el dispositivo o certificado no soporta Live Activities, continúa con la notificación estándar
                }
            }
        } else if let currentActivity = activity {
            self.activity = nil
            Task { await currentActivity.end(nil, dismissalPolicy: .immediate) }
        }

        // 2. Actualiza la notificación de progreso con barra visual en el Centro de Notificaciones
        updateProgressBannerNotification(
            activeDownloads: activeDownloads,
            sending: sending,
            percent: percent,
            received: totalReceived,
            total: totalSize
        )
    }

    private func updateProgressBannerNotification(
        activeDownloads: [DownloadItem],
        sending: [UploadItem],
        percent: Int,
        received: UInt64,
        total: UInt64
    ) {
        // Evita saturar el centro de notificaciones actualizando máximo cada 2 segundos
        guard Date().timeIntervalSince(lastProgressNotificationDate) >= 2.0 else { return }

        let filledBlocks = min(10, max(0, percent / 10))
        let bar = String(repeating: "━", count: filledBlocks) + String(repeating: "─", count: 10 - filledBlocks)

        let title: String
        let body: String

        if !activeDownloads.isEmpty {
            if activeDownloads.count == 1, let first = activeDownloads.first {
                title = "Downloading · \(percent)%"
                body = "\(bar)  \(Formatting.bytes(received)) / \(Formatting.bytes(total))\n\(first.filename)"
            } else {
                title = "Downloading \(activeDownloads.count) files · \(percent)%"
                body = "\(bar)  \(Formatting.bytes(received)) / \(Formatting.bytes(total))"
            }
        } else {
            title = "Uploading \(sending.count) file\(sending.count == 1 ? "" : "s")"
            body = sending.first?.filename ?? ""
        }

        let summaryKey = "\(title)|\(percent)"
        guard summaryKey != lastProgressNotificationText else { return }
        lastProgressNotificationText = summaryKey
        lastProgressNotificationDate = Date()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil // Silenciosa para no sonar en cada cambio de porcentaje
        content.interruptionLevel = .passive

        let request = UNNotificationRequest(
            identifier: progressNotificationID,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
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
