import Foundation
import SoulseekKit

/// A song the album should have but the library doesn't.
struct MissingTrack: Identifiable, Hashable {
    enum Source: Hashable {
        /// Seen in the peer's folder when the album was downloaded; downloadable directly.
        case soulseek(username: String, file: SharedFile)
        /// From the MusicBrainz tracklist; has to be searched for.
        case musicBrainz
    }

    let id: String
    let disc: Int
    let number: Int?
    let title: String
    let duration: Double?
    let source: Source
}

struct AlbumCompleteness: Equatable {
    var missing: [MissingTrack]
    var expectedCount: Int
    var sourceDescription: String
    /// How many songs the album had when this was worked out; a change triggers a recheck.
    var localCount: Int
}

/// Works out which songs an album is missing, from the Soulseek folder it came from or from
/// MusicBrainz. Results are cached per album.
@MainActor
final class AlbumCompletenessStore: ObservableObject {
    @Published private(set) var results: [String: AlbumCompleteness] = [:]
    @Published private(set) var hiddenAlbums: Set<String>
    @Published private(set) var loading: Set<String> = []

    private let listings = FolderListingStore()
    private static let titleRegexes: [NSRegularExpression] = [
        #"\([^)]*\)"#,
        #"\[[^\]]*\]"#,
        #"\b(feat|ft|featuring)\.?\s.*$"#,
        #"\s-\s.*(remaster|version|edit|mix).*$"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    private static let duplicateSuffixRegex = try! NSRegularExpression(pattern: #" \(\d+\)(?=\.[^.]+$)"#)

    init() {
        hiddenAlbums = Set(UserDefaults.standard.stringArray(forKey: "missing.hiddenAlbums") ?? [])
    }

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: AppSettings.showMissingKey) as? Bool ?? true }
    static var musicBrainzEnabled: Bool { UserDefaults.standard.object(forKey: AppSettings.musicBrainzKey) as? Bool ?? true }

    func isHidden(_ album: Album) -> Bool { hiddenAlbums.contains(album.id) }

    func setHidden(_ album: Album, _ hidden: Bool) {
        if hidden { hiddenAlbums.insert(album.id) } else { hiddenAlbums.remove(album.id) }
        UserDefaults.standard.set(Array(hiddenAlbums), forKey: "missing.hiddenAlbums")
    }

    /// Remember a peer's full folder listing when downloading from it.
    func recordListing(username: String, remoteFolder: String, files: [SharedFile]) {
        let prefix = remoteFolder.lowercased() + "\\"
        let audio = files.filter { file in
            guard LibraryStore.audioExtensions.contains(file.fileExtension) else { return false }
            let f = file.folder.lowercased()
            return f == remoteFolder.lowercased() || f.hasPrefix(prefix)
        }
        guard !audio.isEmpty else { return }
        let local = SoulseekClient.libraryFolderName(forRemoteFolder: SharedFile(path: remoteFolder + "\\x", size: 0).folderName)
        listings.save(FolderListing(username: username, remoteFolder: remoteFolder, files: audio), forLocalFolder: local)
    }

    func refresh(_ album: Album, force: Bool = false) {
        guard Self.isEnabled, !loading.contains(album.id) else { return }
        if !force, let existing = results[album.id], existing.localCount == album.tracks.count { return }
        loading.insert(album.id)

        // 1. The Soulseek folder it was downloaded from: exact and offline.
        if let listing = listings.listing(forLocalFolder: album.folder.lastPathComponent) {
            results[album.id] = Self.compare(album, expected: listing.expectedTracks(), source: "From \(listing.username)'s folder")
            loading.remove(album.id)
            return
        }

        // 2. MusicBrainz.
        guard Self.musicBrainzEnabled else {
            loading.remove(album.id)
            return
        }
        let mbid = album.tracks.compactMap(\.musicBrainzAlbumID).first(where: { UUID(uuidString: $0) != nil })
        let title = album.title, artist = album.artist, count = album.tracks.count
        let albumSnapshot = album
        Task { [weak self] in
            let tracklist = await MusicBrainz.shared.tracklist(
                albumID: albumSnapshot.id,
                releaseID: mbid,
                title: title,
                artist: artist,
                localCount: count,
                force: force
            )
            guard let self else { return }
            if let tracklist {
                self.results[albumSnapshot.id] = Self.compare(
                    albumSnapshot,
                    expected: tracklist.tracks,
                    source: "MusicBrainz: \(tracklist.title)"
                )
            } else {
                self.results[albumSnapshot.id] = AlbumCompleteness(
                    missing: [],
                    expectedCount: albumSnapshot.tracks.count,
                    sourceDescription: "",
                    localCount: albumSnapshot.tracks.count
                )
            }
            self.loading.remove(albumSnapshot.id)
        }
    }

    private static func compare(_ album: Album, expected: [ExpectedTrack], source: String) -> AlbumCompleteness {
        var remainingLocals = album.tracks.map { track in
            (
                filename: normalizeFilename(track.url.lastPathComponent),
                title: normalizeTitle(track.title),
                discTrack: track.trackNumber.map { "\(track.discNumber ?? 1)-\($0)" }
            )
        }

        var missing: [MissingTrack] = []
        for (offset, entry) in expected.enumerated() {
            // 1-to-1 matching prevents one local track from hiding two similar expected tracks.
            if let filename = entry.filename {
                let normFile = normalizeFilename(filename)
                if let idx = remainingLocals.firstIndex(where: { $0.filename == normFile }) {
                    remainingLocals.remove(at: idx)
                    continue
                }
            }
            let title = normalizeTitle(entry.title)
            if !title.isEmpty {
                if let idx = remainingLocals.firstIndex(where: { local in
                    guard !local.title.isEmpty else { return false }
                    if local.title == title { return true }
                    return min(local.title.count, title.count) >= 6
                        && (local.title.hasPrefix(title) || title.hasPrefix(local.title))
                }) {
                    remainingLocals.remove(at: idx)
                    continue
                }
            } else if let number = entry.number {
                let key = "\(entry.disc)-\(number)"
                if let idx = remainingLocals.firstIndex(where: { $0.discTrack == key }) {
                    remainingLocals.remove(at: idx)
                    continue
                }
            }
            missing.append(MissingTrack(
                id: "\(offset)-\(entry.disc)-\(entry.number ?? 0)-\(entry.title)",
                disc: entry.disc,
                number: entry.number,
                title: entry.title,
                duration: entry.duration,
                source: entry.source
            ))
        }
        return AlbumCompleteness(
            missing: missing,
            expectedCount: max(expected.count, album.tracks.count),
            sourceDescription: source,
            localCount: album.tracks.count
        )
    }

    static func normalizeTitle(_ title: String) -> String {
        var text = title.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
        for regex in titleRegexes {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        }
        return text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    private static func normalizeFilename(_ name: String) -> String {
        let lower = name.lowercased()
        let range = NSRange(lower.startIndex..., in: lower)
        return duplicateSuffixRegex.stringByReplacingMatches(in: lower, range: range, withTemplate: "")
    }
}

struct ExpectedTrack {
    let disc: Int
    let number: Int?
    let title: String
    let duration: Double?
    let filename: String?
    let source: MissingTrack.Source
}

// MARK: - Soulseek folder listings

struct FolderListing: Codable, Sendable {
    struct File: Codable, Sendable {
        let path: String
        let size: UInt64
        let duration: UInt32?
    }

    let username: String
    let remoteFolder: String
    let files: [File]

    init(username: String, remoteFolder: String, files: [SharedFile]) {
        self.username = username
        self.remoteFolder = remoteFolder
        self.files = files.map { File(path: $0.path, size: $0.size, duration: $0.attributes.duration) }
    }

    func expectedTracks() -> [ExpectedTrack] {
        files.map { file in
            let shared = SharedFile(path: file.path, size: file.size, attributes: FileAttributes(duration: file.duration))
            let parsed = MetadataReader.parseFilename((shared.filename as NSString).deletingPathExtension)
            return ExpectedTrack(
                disc: parsed.disc ?? 1,
                number: parsed.number,
                title: parsed.title,
                duration: file.duration.map(Double.init),
                filename: shared.filename,
                source: .soulseek(username: username, file: shared)
            )
        }
        .sorted { ($0.disc, $0.number ?? 999, $0.title) < ($1.disc, $1.number ?? 999, $1.title) }
    }
}

/// Folder listings keyed by the local folder name the album landed in.
final class FolderListingStore {
    private var listings: [String: FolderListing]
    private let saveQueue = DispatchQueue(label: "seekios.folder-listings")
    private let url = AppDirectories.applicationSupport.appendingPathComponent("album-sources.json")

    init() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: FolderListing].self, from: data) {
            listings = decoded
        } else {
            listings = [:]
        }
    }

    func listing(forLocalFolder name: String) -> FolderListing? { listings[name] }

    func save(_ listing: FolderListing, forLocalFolder name: String) {
        listings[name] = listing
        let snapshot = listings
        let targetURL = url
        saveQueue.async {
            AppDirectories.ensureParentDirectory(for: targetURL)
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: targetURL, options: .atomic)
            }
        }
    }
}

// MARK: - MusicBrainz

struct Tracklist: Codable, Sendable {
    let title: String
    let tracks: [Entry]

    struct Entry: Codable, Sendable {
        let disc: Int
        let number: Int?
        let title: String
        let duration: Double?
    }
}

extension Tracklist {
    fileprivate func expected() -> [ExpectedTrack] {
        tracks.map { ExpectedTrack(disc: $0.disc, number: $0.number, title: $0.title, duration: $0.duration,
                                   filename: nil, source: .musicBrainz) }
    }
}

/// Release tracklists from MusicBrainz (free, no key; max ~1 request/second, needs a User-Agent).
actor MusicBrainz {
    static let shared = MusicBrainz()

    private var lastRequest: ContinuousClock.Instant?
    private let directory: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tracklists", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private struct Cached: Codable {
        let tracklist: Tracklist?
        let fetched: Date
    }

    /// The best-matching release's tracks, or nil if none was found.
    func tracklist(albumID: String, releaseID: String?, title: String, artist: String, localCount: Int,
                   force: Bool) async -> (title: String, tracks: [ExpectedTrack])? {
        let file = directory.appendingPathComponent(albumID + ".json")
        if !force, let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode(Cached.self, from: data),
           cached.tracklist != nil || Date().timeIntervalSince(cached.fetched) < 7 * 86_400 {
            return cached.tracklist.map { ($0.title, $0.expected()) }
        }

        var found: Tracklist?
        do {
            if let releaseID, UUID(uuidString: releaseID) != nil {
                found = try await fetchRelease(releaseID)
            }
            if found == nil {
                if let searchedID = try await searchRelease(title: title, artist: artist, localCount: localCount),
                   UUID(uuidString: searchedID) != nil {
                    found = try await fetchRelease(searchedID)
                }
            }
        } catch {
            return nil
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Cached(tracklist: found, fetched: Date())) {
            try? data.write(to: file, options: .atomic)
        }
        return found.map { ($0.title, $0.expected()) }
    }

    private func escapeLucene(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: " ")
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func searchRelease(title: String, artist: String, localCount: Int) async throws -> String? {
        let escapedTitle = escapeLucene(title)
        let escapedArtist = escapeLucene(artist)
        guard !escapedTitle.isEmpty else { return nil }
        var query = "release:\"\(escapedTitle)\""
        if artist != "Various Artists", artist != "Unknown Artist", !escapedArtist.isEmpty {
            query += " AND artist:\"\(escapedArtist)\""
        }
        guard var components = URLComponents(string: "https://musicbrainz.org/ws/2/release/") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        guard let url = components.url else { return nil }
        struct Response: Decodable {
            struct Release: Decodable {
                let id: String
                let title: String
                let score: Int?
                let trackCount: Int?
                enum CodingKeys: String, CodingKey {
                    case id, title, score
                    case trackCount = "track-count"
                }
            }
            let releases: [Release]
        }
        guard let response: Response = try await get(url) else { return nil }
        let wanted = AlbumCompletenessStoreNormalizer.title(title)
        let candidates = response.releases.filter { ($0.score ?? 0) >= 80 }
            .filter { AlbumCompletenessStoreNormalizer.title($0.title) == wanted || ($0.score ?? 0) >= 95 }
        let best = candidates.min { lhs, rhs in
            func cost(_ release: Response.Release) -> Int {
                let count = release.trackCount ?? 0
                return count >= localCount ? count - localCount : 1000 + (localCount - count)
            }
            return cost(lhs) < cost(rhs)
        }
        return best?.id
    }

    private func fetchRelease(_ id: String) async throws -> Tracklist? {
        guard UUID(uuidString: id) != nil,
              var components = URLComponents(string: "https://musicbrainz.org/ws/2/release/\(id)") else { return nil }
        components.queryItems = [URLQueryItem(name: "inc", value: "recordings"), URLQueryItem(name: "fmt", value: "json")]
        guard let url = components.url else { return nil }
        struct Response: Decodable {
            struct Medium: Decodable {
                struct Track: Decodable {
                    let number: String?
                    let position: Int?
                    let title: String
                    let length: Int?
                }
                let position: Int?
                let tracks: [Track]?
            }
            let title: String
            let media: [Medium]?
        }
        guard let response: Response = try await get(url) else { return nil }
        let entries = (response.media ?? []).flatMap { medium in
            (medium.tracks ?? []).map { track in
                Tracklist.Entry(
                    disc: medium.position ?? 1,
                    number: track.position ?? Int(track.number ?? ""),
                    title: track.title,
                    duration: track.length.map { Double($0) / 1000 }
                )
            }
        }
        return entries.isEmpty ? nil : Tracklist(title: response.title, tracks: entries)
    }

    /// Returns `nil` on HTTP 404/400 so callers can fall back cleanly; throws on transient/network errors.
    private func get<T: Decodable>(_ url: URL) async throws -> T? {
        let clock = ContinuousClock()
        while let last = lastRequest {
            let elapsed = last.duration(to: clock.now)
            let target = Duration.milliseconds(1100)
            if elapsed >= target { break }
            try await Task.sleep(for: target - elapsed)
        }
        lastRequest = clock.now

        var request = URLRequest(url: url)
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 || status == 400 { return nil }
        guard status == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// Title normalisation usable off the main actor.
enum AlbumCompletenessStoreNormalizer {
    private static let bracketRegex = try! NSRegularExpression(pattern: #"\([^)]*\)|\[[^\]]*\]"#)

    static func title(_ text: String) -> String {
        let folded = text.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
        let range = NSRange(folded.startIndex..., in: folded)
        let stripped = bracketRegex.stringByReplacingMatches(in: folded, range: range, withTemplate: "")
        return stripped.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
}
