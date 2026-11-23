import Foundation
import UIKit

/// Listening and sharing statistics, kept on the phone only (stats.json in Application Support).
/// Listening time is counted while audio actually plays, so seeking doesn't inflate it.
@MainActor
final class StatsStore: ObservableObject {
    struct TrackStat: Codable, Sendable {
        var plays: Int
        var seconds: Double
        var lastPlayed: Date?
        /// Copied in so stats survive the file being deleted or renamed.
        var title: String
        var artist: String
        var album: String?
        var albumArtist: String?
    }

    struct Totals: Codable, Sendable {
        var downloadedBytes: UInt64 = 0
        var downloadedFiles = 0
        var uploadedBytes: UInt64 = 0
        var uploadedFiles = 0
        var peers: Set<String> = []
        var since = Date()
    }

    private struct Stored: Codable, Sendable {
        var tracks: [String: TrackStat] = [:]
        /// "yyyy-MM-dd" → seconds listened that day.
        var days: [String: Double] = [:]
        var totals = Totals()
    }

    struct Ranked: Identifiable {
        let id: String
        let name: String
        let detail: String
        let plays: Int
        let seconds: Double
    }

    struct DayTotal: Identifiable {
        let date: Date
        let minutes: Double
        var id: Date { date }
    }

    /// Bumped on saves so open stats screens refresh (not on every listening tick).
    @Published private(set) var revision = 0
    /// Since the app launched; shown while seeding.
    @Published private(set) var sessionUploadedBytes: UInt64 = 0
    @Published private(set) var sessionUploadedFiles = 0
    @Published private(set) var sessionDownloadedBytes: UInt64 = 0

    private var stored = Stored()
    private var pendingSaveTask: Task<Void, Never>?
    private let saveQueue = DispatchQueue(label: "seekios.stats")
    private let fileURL = AppDirectories.applicationSupport.appendingPathComponent("stats.json")
    private var cachedDayStart = Date.distantPast
    private var cachedDayKey = ""

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = decoded
        }
    }

    // MARK: Recording

    func addListening(_ track: Track, album: String?, seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        update(track, album: album) { $0.seconds += seconds }
        stored.days[todayKey(), default: 0] += seconds
        scheduleSave()
    }

    func recordPlay(_ track: Track, album: String?) {
        update(track, album: album) {
            $0.plays += 1
            $0.lastPlayed = Date()
        }
        scheduleSave()
        revision += 1
    }

    func recordDownload(bytes: UInt64, from username: String) {
        stored.totals.downloadedBytes += bytes
        stored.totals.downloadedFiles += 1
        sessionDownloadedBytes += bytes
        scheduleSave()
    }

    func recordUpload(bytes: UInt64, to username: String) {
        stored.totals.uploadedBytes += bytes
        stored.totals.uploadedFiles += 1
        if stored.totals.peers.count < 5_000 {
            stored.totals.peers.insert(username)
        }
        sessionUploadedBytes += bytes
        sessionUploadedFiles += 1
        scheduleSave()
    }

    func reset() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        stored = Stored()
        sessionUploadedBytes = 0
        sessionUploadedFiles = 0
        sessionDownloadedBytes = 0
        save()
    }

    private func todayKey() -> String {
        let now = Date()
        let dayStart = Calendar.current.startOfDay(for: now)
        if dayStart != cachedDayStart || cachedDayKey.isEmpty {
            cachedDayStart = dayStart
            cachedDayKey = Self.dayFormatter.string(from: dayStart)
        }
        return cachedDayKey
    }

    private func update(_ track: Track, album: String?, _ change: (inout TrackStat) -> Void) {
        var stat = stored.tracks[track.id]
            ?? TrackStat(plays: 0, seconds: 0, lastPlayed: nil, title: track.title, artist: track.artist,
                         album: album, albumArtist: track.albumArtist)
        stat.title = track.title
        stat.artist = track.artist
        stat.album = album ?? stat.album
        stat.albumArtist = track.albumArtist ?? stat.albumArtist
        change(&stat)
        stored.tracks[track.id] = stat
    }

    // MARK: Reading

    var totals: Totals { stored.totals }
    var totalSeconds: Double { stored.tracks.values.reduce(0) { $0 + $1.seconds } }
    var totalPlays: Int { stored.tracks.values.reduce(0) { $0 + $1.plays } }
    var distinctSongs: Int { stored.tracks.values.filter { $0.plays > 0 }.count }

    func plays(of track: Track) -> Int { stored.tracks[track.id]?.plays ?? 0 }

    func mostPlayed(limit: Int, in library: LibraryStore) -> [Track] {
        let ranked = stored.tracks
            .filter { $0.value.plays > 0 }
            .sorted { ($0.value.plays, $0.value.seconds) > ($1.value.plays, $1.value.seconds) }
        return Array(ranked.lazy.compactMap { library.track(id: $0.key) }.prefix(limit))
    }

    func topSongs(limit: Int) -> [Ranked] {
        stored.tracks
            .filter { $0.value.plays > 0 }
            .sorted { ($0.value.plays, $0.value.seconds) > ($1.value.plays, $1.value.seconds) }
            .prefix(limit)
            .map { id, stat in
                Ranked(id: id, name: stat.title, detail: stat.artist, plays: stat.plays, seconds: stat.seconds)
            }
    }

    func topArtists(limit: Int) -> [Ranked] {
        var plays: [String: Int] = [:]
        var seconds: [String: Double] = [:]
        for stat in stored.tracks.values {
            plays[stat.artist, default: 0] += stat.plays
            seconds[stat.artist, default: 0] += stat.seconds
        }
        return seconds.keys
            .sorted { (seconds[$0] ?? 0) > (seconds[$1] ?? 0) }
            .prefix(limit)
            .map { Ranked(id: "artist:\($0)", name: $0, detail: "", plays: plays[$0] ?? 0, seconds: seconds[$0] ?? 0) }
    }

    func topAlbums(limit: Int) -> [Ranked] {
        struct Key: Hashable { let album: String; let artist: String }
        var plays: [Key: Int] = [:]
        var seconds: [Key: Double] = [:]
        for stat in stored.tracks.values {
            guard let album = stat.album, !album.isEmpty else { continue }
            let owner = stat.albumArtist ?? stat.artist
            let key = Key(album: album, artist: owner)
            plays[key, default: 0] += stat.plays
            seconds[key, default: 0] += stat.seconds
        }
        return seconds.keys
            .sorted { (seconds[$0] ?? 0) > (seconds[$1] ?? 0) }
            .prefix(limit)
            .map { Ranked(id: "album:\($0.artist)|\($0.album)", name: $0.album, detail: $0.artist, plays: plays[$0] ?? 0, seconds: seconds[$0] ?? 0) }
    }

    /// Listening per day for the last `count` days, oldest first, including zero days.
    func lastDays(_ count: Int) -> [DayTotal] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<count).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return DayTotal(date: day, minutes: (stored.days[Self.dayFormatter.string(from: day)] ?? 0) / 60)
        }
    }

    func seconds(inLast days: Int) -> Double {
        lastDays(days).reduce(0) { $0 + $1.minutes * 60 }
    }

    // MARK: Saving

    private func scheduleSave() {
        guard pendingSaveTask == nil else { return }
        pendingSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 20_000_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingSaveTask = nil
            self.save()
        }
    }

    /// Also called when the app goes to the background; protected with a UIKit background task assertion.
    func save() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        revision += 1
        let snapshot = stored
        let url = fileURL

        var bgTaskID: UIBackgroundTaskIdentifier = .invalid
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "SeekiosStatsSave") {
            UIApplication.shared.endBackgroundTask(bgTaskID)
            bgTaskID = .invalid
        }

        saveQueue.async {
            defer {
                if bgTaskID != .invalid {
                    let ended = bgTaskID
                    DispatchQueue.main.async {
                        UIApplication.shared.endBackgroundTask(ended)
                    }
                }
            }
            AppDirectories.ensureParentDirectory(for: url)
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
