import ActivityKit
import Combine
import Foundation
import SoulseekKit
import UIKit
import UserNotifications

/// Keeps Soulseek transfers alive in the background (sideloading), updates Live Activity,
/// posts completion notifications, and runs safe auto-retry on failed transfers.
@MainActor
final class TransferMonitor {
    private let soulseek: SoulseekModel
    private let transfers: TransfersStore
    private let library: LibraryStore
    private let player: Player
    private weak var stats: StatsStore?
    private var subscriptions = Set<AnyCancellable>()
    private var heartbeat: Timer?
    private var lastReconnect = Date.distantPast

    /// Live Activity state (Lock Screen / Dynamic Island)
    private var activity: Activity<TransferActivityAttributes>?
    private var lastPublishedState: TransferActivityAttributes.ContentState?
    private var liveActivityTask: Task<Void, Never>?

    private var notifiedCompletedIDs = Set<DownloadID>()
    private var requestedNotificationPermission = false

    /// Auto-Retry state (only for `.failed` downloads, never `.paused` or `.completed`)
    private var retryCounts: [DownloadID: Int] = [:]
    private var pendingRetryTimers: [DownloadID: Task<Void, Never>] = [:]

    init(soulseek: SoulseekModel, library: LibraryStore, player: Player, stats: StatsStore) {
        self.soulseek = soulseek
        self.transfers = soulseek.transfers
        self.library = library
        self.player = player
        self.stats = stats

        // Clean stale activities from prior runs.
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["seekios.transfer.progress"])
        for stale in Activity<TransferActivityAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }

        for item in transfers.downloads where item.isCompleted {
            notifiedCompletedIDs.insert(item.id)
        }

        // Immediate keep-alive response when playback state or active transfer counts change (no 1s lag).
        transfers.$activeDownloadCount
            .combineLatest(transfers.$activeUploadCount, player.$isPlaying)
            .sink { [weak self] _, _, _ in
                self?.syncBackgroundKeeper()
            }
            .store(in: &subscriptions)

        // Throttled 1s refresh for Live Activity, notifications, and auto-retry.
        transfers.$downloads
            .combineLatest(transfers.$uploads, player.$isPlaying)
            .throttle(for: .seconds(1.0), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _, _, _ in
                self?.refresh()
            }
            .store(in: &subscriptions)

        heartbeat = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        heartbeat?.invalidate()
        for task in pendingRetryTimers.values { task.cancel() }
        liveActivityTask?.cancel()
    }

    var isSeeding: Bool { AppSettings.seedingEnabled && soulseek.isEffectivelySharing }

    private func requestNotificationPermissionIfNeeded() {
        guard !requestedNotificationPermission else { return }
        requestedNotificationPermission = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func refresh() {
        syncBackgroundKeeper()
        update(downloads: transfers.downloads, uploads: transfers.uploads)
    }

    private func syncBackgroundKeeper() {
        let busy = transfers.activeDownloadCount > 0 || transfers.activeUploadCount > 0
        let seeding = isSeeding && soulseek.hasCredentials
        let wantsKeeper = (busy && AppSettings.flag(AppSettings.backgroundTransfersKey)) || seeding
        AudioSessionCoordinator.shared.setBackgroundKeepAliveNeeded(wantsKeeper)
    }

    private func update(downloads: [DownloadItem], uploads: [UploadItem]) {
        let activeDownloads = downloads.filter(\.isActive)
        let sending = uploads.filter { $0.state == .transferring }
        let seeding = isSeeding && soulseek.hasCredentials

        if !activeDownloads.isEmpty {
            requestNotificationPermissionIfNeeded()
        }

        if seeding, !soulseek.isLoggedIn, Date().timeIntervalSince(lastReconnect) > 60 {
            lastReconnect = Date()
            soulseek.reconnectIfNeeded()
        }

        updateLiveActivity(
            activeDownloads: activeDownloads,
            sending: sending,
            seeding: seeding
        )
        notifyNewlyCompletedDownloads(downloads)
        handleAutoRetry(downloads)
    }

    // MARK: - Live Activity (Lock Screen & Dynamic Island)

    private func updateLiveActivity(
        activeDownloads: [DownloadItem],
        sending: [UploadItem],
        seeding: Bool
    ) {
        let showActivitySetting = AppSettings.flag(AppSettings.transferActivityKey)
        let hasActiveTransfers = !activeDownloads.isEmpty || !sending.isEmpty
        let shouldShow = (hasActiveTransfers || seeding) && showActivitySetting && ActivityAuthorizationInfo().areActivitiesEnabled

        guard shouldShow else {
            lastPublishedState = nil
            if let currentActivity = activity {
                self.activity = nil
                liveActivityTask?.cancel()
                liveActivityTask = Task {
                    await currentActivity.end(nil, dismissalPolicy: .immediate)
                }
            }
            return
        }

        let transferringDownloads = activeDownloads.filter(\.isTransferring)
        let queuedCount = max(0, activeDownloads.count - transferringDownloads.count)

        let downTotal = activeDownloads.reduce(UInt64(0)) { $0 + $1.size }
        let downDone = activeDownloads.reduce(UInt64(0)) { $0 + min($1.received, $1.size) }
        let upTotal = sending.reduce(UInt64(0)) { $0 + $1.size }
        let upDone = sending.reduce(UInt64(0)) { $0 + min($1.sent, $1.size) }

        let combinedTotal = downTotal + upTotal
        let combinedDone = downDone + upDone
        let fraction = combinedTotal > 0 ? min(1.0, Double(combinedDone) / Double(combinedTotal)) : 0.0

        let speed = transfers.totalDownloadSpeed + transfers.totalUploadSpeed
        let currentFile = transferringDownloads.first?.filename
            ?? sending.first?.filename
            ?? activeDownloads.first?.filename
            ?? ""

        let state = TransferActivityAttributes.ContentState(
            downloading: transferringDownloads.count,
            uploading: sending.count,
            queued: queuedCount,
            fraction: fraction,
            bytesPerSecond: speed,
            currentFile: currentFile,
            finished: false,
            seeding: seeding ? max(library.tracks.count, 1) : 0,
            sessionUploaded: Double(stats?.sessionUploadedBytes ?? 0)
        )

        if state == lastPublishedState && activity != nil {
            return
        }

        if let currentActivity = activity {
            lastPublishedState = state
            liveActivityTask?.cancel()
            liveActivityTask = Task {
                await currentActivity.update(ActivityContent(state: state, staleDate: nil))
            }
        } else if UIApplication.shared.applicationState == .active {
            let accentHex = UserDefaults.standard.string(forKey: AccentPalette.storageKey) ?? AccentPalette.defaultHex
            do {
                activity = try Activity.request(
                    attributes: TransferActivityAttributes(accentHex: accentHex),
                    content: ActivityContent(state: state, staleDate: nil),
                    pushType: nil
                )
                lastPublishedState = state
            } catch {
                Diagnostics.shared.log("Live Activity request failed: \(error.localizedDescription)", category: "transfers")
            }
        }
    }

    // MARK: - Safe Auto-Retry (only `.failed`, respects cancellation & deletion)

    private func handleAutoRetry(_ downloads: [DownloadItem]) {
        let currentIDs = Set(downloads.map(\.id))

        // Cancel & prune timers for removed downloads so deleted items are never resurrected.
        for (id, task) in pendingRetryTimers where !currentIDs.contains(id) {
            task.cancel()
            pendingRetryTimers.removeValue(forKey: id)
        }
        retryCounts = retryCounts.filter { currentIDs.contains($0.key) }
        notifiedCompletedIDs = notifiedCompletedIDs.intersection(currentIDs)

        for item in downloads {
            let itemID = item.id
            switch item.state {
            case .failed:
                let attempts = retryCounts[itemID, default: 0]
                if attempts < 3 && pendingRetryTimers[itemID] == nil {
                    // Exponential backoff: 45s, 90s, 180s
                    let delaySeconds: UInt64 = 45 * UInt64(1 << attempts)
                    pendingRetryTimers[itemID] = Task { [weak self] in
                        do {
                            try await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
                        } catch {
                            return
                        }
                        guard let self, !Task.isCancelled else { return }
                        self.pendingRetryTimers.removeValue(forKey: itemID)
                        // Verify item STILL exists and is STILL `.failed` before retrying.
                        guard let latest = self.transfers.item(for: itemID), latest.isFailed else { return }
                        self.retryCounts[itemID] = attempts + 1
                        self.soulseek.retry(latest)
                    }
                }
            case .completed:
                retryCounts.removeValue(forKey: itemID)
                pendingRetryTimers.removeValue(forKey: itemID)?.cancel()
            case .paused, .requesting, .queued, .starting, .transferring:
                pendingRetryTimers.removeValue(forKey: itemID)?.cancel()
            }
        }
    }

    // MARK: - Completion Notification

    private func notifyNewlyCompletedDownloads(_ downloads: [DownloadItem]) {
        var newlyFinished: [DownloadItem] = []
        for item in downloads {
            if item.isCompleted {
                if notifiedCompletedIDs.insert(item.id).inserted {
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
