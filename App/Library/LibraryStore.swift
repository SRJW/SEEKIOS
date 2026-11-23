import Foundation
import SoulseekKit
import UniformTypeIdentifiers

/// Everything under Documents/Music. The folder is visible in the Files app, so music can also
/// be dropped in by hand; downloads and imports land there too.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var albums: [Album] = []
    @Published private(set) var items: [LibraryItem] = []
    @Published private(set) var artists: [ArtistEntry] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isImporting = false
    /// Bumped when cover art may have changed, so artwork views reload.
    @Published private(set) var artworkRevision = 0

    let root: URL
    var onSharesChanged: (([LocalShare]) -> Void)?

    private var cache: [String: CachedEntry] = [:]
    private var rescanQueued = false
    private var activeImportCount = 0
    private var albumByTrack: [String: Album] = [:]
    private var tracksByID: [String: Track] = [:]
    private var albumsByID: [String: Album] = [:]
    private var ownedFilenamesLower = Set<String>()
    private var ownedFolderNamesLower = Set<String>()
    private let cacheWriteQueue = DispatchQueue(label: "seekios.library-cache")

    nonisolated private static var cacheURL: URL {
        AppDirectories.applicationSupport.appendingPathComponent("library-cache-v2.json")
    }

    nonisolated static let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "mp4", "aac", "alac", "flac", "wav", "aif", "aiff", "caf"]
    nonisolated static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "heic"]
    /// Files that travel with the music but aren't songs: covers and synced lyrics.
    nonisolated static let sidecarExtensions: Set<String> = imageExtensions.union(["lrc"])

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = documents.appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let canonicalRoot = root.canonicalFileURL
        Task { await ArtworkStore.shared.setLibraryRoot(canonicalRoot) }
        if let data = try? Data(contentsOf: Self.cacheURL),
           let decoded = try? JSONDecoder().decode([String: CachedEntry].self, from: data) {
            cache = decoded
        }
    }

    func bumpArtwork() { artworkRevision += 1 }

    // MARK: Lookup

    func track(id: String) -> Track? { tracksByID[id] }
    func album(id: String) -> Album? { albumsByID[id] }
    func album(containing track: Track) -> Album? { albumByTrack[track.id] }

    func artist(named name: String) -> ArtistEntry? { artists.first { $0.name == name } }

    func ownsFile(named filename: String) -> Bool {
        ownedFilenamesLower.contains(filename.lowercased())
    }

    func ownsFolder(named folderName: String) -> Bool {
        ownedFolderNamesLower.contains(folderName.lowercased())
    }

    /// The library song stored at a file URL (e.g. a finished download), if any.
    func track(at url: URL) -> Track? {
        let rootPath = root.canonicalPath
        let path = url.canonicalPath
        guard path.hasPrefix(rootPath + "/") else { return nil }
        let relative = String(path.dropFirst(rootPath.count + 1))
        return tracksByID[relative]
    }

    /// Best artwork for a track: its own custom cover if one was set, else its album's when it
    /// has one, so covers stay consistent.
    func artwork(for track: Track) -> ArtworkSource {
        if customTrackArt.contains(track.id) { return .track(track) }
        return albumByTrack[track.id].map { .album($0) } ?? .track(track)
    }

    // MARK: Custom artwork

    /// Songs with their own picked cover (albums don't need tracking: their override is found by key).
    @Published private(set) var customTrackArt: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "customTrackArt") ?? [])

    func setCustomArtwork(_ data: Data, for target: ArtworkTarget) async -> Bool {
        guard await ArtworkStore.shared.setOverride(data, for: target.source) else { return false }
        if case let .track(track) = target {
            customTrackArt.insert(track.id)
            UserDefaults.standard.set(Array(customTrackArt), forKey: "customTrackArt")
        }
        artworkRevision += 1
        return true
    }

    func removeCustomArtwork(for target: ArtworkTarget) async {
        await ArtworkStore.shared.removeOverride(for: target.source)
        if case let .track(track) = target {
            customTrackArt.remove(track.id)
            UserDefaults.standard.set(Array(customTrackArt), forKey: "customTrackArt")
        }
        artworkRevision += 1
    }

    func hasCustomArtwork(_ target: ArtworkTarget) -> Bool {
        ArtworkStore.hasOverride(for: target.source)
    }

    // MARK: Lyrics files

    /// "Song.flac" → "Song.lrc" in the same folder.
    nonisolated static func lyricsURL(for track: Track) -> URL {
        track.url.deletingPathExtension().appendingPathExtension("lrc")
    }

    /// Copies a picked .lrc/.txt next to the song off the main actor so it's used instead of LRCLIB.
    func importLyrics(from source: URL, for track: Track) async -> Bool {
        let destination = Self.lyricsURL(for: track)
        return await Task.detached(priority: .userInitiated) {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: source), !data.isEmpty, data.count < 2_000_000 else { return false }
            return (try? data.write(to: destination, options: .atomic)) != nil
        }.value
    }

    func removeLyricsFile(for track: Track) {
        let url = Self.lyricsURL(for: track)
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Scanning

    func rescan() {
        guard !isScanning else {
            rescanQueued = true
            return
        }
        isScanning = true
        let root = self.root
        let known = cache

        Task.detached(priority: .utility) {
            let result = await Self.scan(root: root, cache: known)
            await MainActor.run { self.apply(result) }
        }
    }

    private func apply(_ result: ScanResult) {
        cache = result.cache
        tracks = result.tracks
        albums = result.albums
        items = result.items
        artists = result.artists
        tracksByID = result.tracksByID
        albumsByID = result.albumsByID
        albumByTrack = result.albumByTrack
        ownedFilenamesLower = result.ownedFilenamesLower
        ownedFolderNamesLower = result.ownedFolderNamesLower
        isScanning = false
        onSharesChanged?(result.shares)

        Task {
            await ArtworkStore.shared.forgetFolderListings()
            self.artworkRevision += 1
        }

        let snapshot = result.cache
        let targetURL = Self.cacheURL
        cacheWriteQueue.async {
            AppDirectories.ensureParentDirectory(for: targetURL)
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: targetURL, options: .atomic)
            }
        }

        if rescanQueued {
            rescanQueued = false
            rescan()
        }
    }

    private struct ScanResult: Sendable {
        let tracks: [Track]
        let albums: [Album]
        let items: [LibraryItem]
        let artists: [ArtistEntry]
        let tracksByID: [String: Track]
        let albumsByID: [String: Album]
        let albumByTrack: [String: Album]
        let ownedFilenamesLower: Set<String>
        let ownedFolderNamesLower: Set<String>
        let shares: [LocalShare]
        let cache: [String: CachedEntry]
    }

    private nonisolated static func scan(root: URL, cache: [String: CachedEntry]) async -> ScanResult {
        let files = audioFiles(in: root)
        var newCache: [String: CachedEntry] = [:]
        var tracks: [Track] = []
        var shares: [LocalShare] = []

        var pending: [(FileEntry, Int)] = []
        var infos = [TrackInfo?](repeating: nil, count: files.count)
        for (index, file) in files.enumerated() {
            if let cached = cache[file.relativePath], cached.size == file.size, cached.modified == file.modified {
                infos[index] = cached.info
            } else {
                pending.append((file, index))
            }
        }

        // Sliding window of 4 concurrent metadata reads (eliminates chunk head-of-line blocking).
        await withTaskGroup(of: (Int, TrackInfo).self) { group in
            var nextIndex = 0
            let maxConcurrent = 4
            while nextIndex < min(maxConcurrent, pending.count) {
                let (file, idx) = pending[nextIndex]
                nextIndex += 1
                group.addTask { (idx, await MetadataReader.read(url: file.url)) }
            }
            for await (idx, info) in group {
                infos[idx] = info
                if nextIndex < pending.count {
                    let (file, nextIdx) = pending[nextIndex]
                    nextIndex += 1
                    group.addTask { (nextIdx, await MetadataReader.read(url: file.url)) }
                }
            }
        }

        var filenamesLower = Set<String>()
        var foldersLower = Set<String>()
        let canonicalRoot = root.canonicalPath

        for (index, file) in files.enumerated() {
            let info = infos[index] ?? TrackInfo()
            newCache[file.relativePath] = CachedEntry(size: file.size, modified: file.modified, info: info)
            let fallbackTitle = file.url.deletingPathExtension().lastPathComponent
            let track = Track(
                id: file.relativePath,
                url: file.url,
                title: info.title ?? fallbackTitle,
                artist: info.artist ?? info.albumArtist ?? "Unknown Artist",
                albumArtist: info.albumArtist,
                album: info.album,
                trackNumber: info.trackNumber,
                discNumber: info.discNumber,
                year: info.year,
                duration: info.duration,
                addedAt: Date(timeIntervalSince1970: file.modified),
                isSpatial: info.isSpatial,
                hasEmbeddedArt: info.hasEmbeddedArt,
                musicBrainzAlbumID: info.musicBrainzAlbumID
            )
            tracks.append(track)
            filenamesLower.insert(file.url.lastPathComponent.lowercased())
            if track.folder.canonicalPath != canonicalRoot {
                foldersLower.insert(track.folder.lastPathComponent.lowercased())
            }
            let virtualPath = (["Seekios"] + file.relativePath.split(separator: "/").map(String.init)).joined(separator: "\\")
            shares.append(LocalShare(virtualPath: virtualPath, url: file.url, size: UInt64(max(file.size, 0))))
        }

        // Group and index completely off MainActor!
        let grouped = group(tracks, root: root)
        let tracksByID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let albumsByID = Dictionary(grouped.albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var byTrack: [String: Album] = [:]
        for album in grouped.albums {
            foldersLower.insert(album.title.lowercased())
            for track in album.tracks { byTrack[track.id] = album }
        }

        return ScanResult(
            tracks: tracks,
            albums: grouped.albums,
            items: grouped.items,
            artists: grouped.artists,
            tracksByID: tracksByID,
            albumsByID: albumsByID,
            albumByTrack: byTrack,
            ownedFilenamesLower: filenamesLower,
            ownedFolderNamesLower: foldersLower,
            shares: shares,
            cache: newCache
        )
    }

    private struct FileEntry: Sendable {
        let url: URL
        let relativePath: String
        let size: Int64
        let modified: Double
    }

    private nonisolated static func audioFiles(in root: URL) -> [FileEntry] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles]) else { return [] }
        let rootPath = root.canonicalPath
        var found: [FileEntry] = []
        for case let url as URL in enumerator {
            guard audioExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let fullPath = url.canonicalPath
            guard fullPath.hasPrefix(rootPath + "/") else { continue }
            let relative = String(fullPath.dropFirst(rootPath.count + 1))
            found.append(FileEntry(url: url, relativePath: relative, size: Int64(values.fileSize ?? 0),
                                   modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }
        return found
    }

    // MARK: Grouping

    private nonisolated static func group(_ tracks: [Track], root: URL) -> (albums: [Album], items: [LibraryItem], artists: [ArtistEntry]) {
        let rootPath = root.canonicalPath
        let tracksByFolder = Dictionary(grouping: tracks, by: { $0.folder.canonicalPath })
        // Pre-resolve folder-level albumArtist if any track in the folder defines one, preventing album splits.
        var folderAlbumArtist: [String: String] = [:]
        for (folder, folderTracks) in tracksByFolder {
            if let artist = folderTracks.compactMap(\.albumArtist).first(where: { !$0.isEmpty }) {
                folderAlbumArtist[folder] = artist
            }
        }

        var albumTracks: [String: [Track]] = [:]
        var albumTitles: [String: String] = [:]
        var singles: [Track] = []

        for track in tracks {
            let folderPath = track.folder.canonicalPath
            if let album = track.album?.trimmingCharacters(in: .whitespaces), !album.isEmpty {
                let effectiveAlbumArtist = track.albumArtist ?? folderAlbumArtist[folderPath]
                let owner = (effectiveAlbumArtist?.lowercased()).map { "artist:" + $0 } ?? "folder:" + folderPath
                let key = owner + "|" + album.lowercased()
                albumTracks[key, default: []].append(track)
                albumTitles[key] = album
            } else if folderPath != rootPath, (tracksByFolder[folderPath]?.count ?? 0) >= 2 {
                let key = "folder:" + folderPath
                albumTracks[key, default: []].append(track)
                albumTitles[key] = track.folder.lastPathComponent
            } else {
                singles.append(track)
            }
        }

        var albums: [Album] = []
        for (key, members) in albumTracks {
            // Strict weak ordering: disc -> (trackNumber ?? .max) -> filename
            let sorted = members.sorted { lhs, rhs in
                let leftDisc = lhs.discNumber ?? 1, rightDisc = rhs.discNumber ?? 1
                if leftDisc != rightDisc { return leftDisc < rightDisc }
                let leftTrack = lhs.trackNumber ?? Int.max, rightTrack = rhs.trackNumber ?? Int.max
                if leftTrack != rightTrack { return leftTrack < rightTrack }
                return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
            }
            let artists = Set(sorted.map(\.artist))
            let artist = sorted.compactMap(\.albumArtist).first
                ?? (artists.count == 1 ? sorted[0].artist : "Various Artists")
            albums.append(Album(
                id: MD5.hex(key),
                title: albumTitles[key] ?? "Unknown Album",
                artist: artist,
                year: sorted.compactMap(\.year).first,
                tracks: sorted,
                folder: sorted[0].folder,
                addedAt: sorted.map(\.addedAt).max() ?? .distantPast))
        }
        albums.sort { SortKey.less($0.title, $1.title) }

        let items = albums.map(LibraryItem.album) + singles.map(LibraryItem.single)

        var artistAlbums: [String: [Album]] = [:]
        var artistSingles: [String: [Track]] = [:]
        for album in albums { artistAlbums[album.artist, default: []].append(album) }
        for single in singles { artistSingles[single.artist, default: []].append(single) }
        let names = Set(artistAlbums.keys).union(artistSingles.keys)
        let artists = names.sorted(by: SortKey.less).map { name in
            ArtistEntry(
                name: name,
                albums: (artistAlbums[name] ?? []).sorted { lhs, rhs in
                    let ly = lhs.year ?? 0, ry = rhs.year ?? 0
                    if ly != ry { return ly > ry }
                    return SortKey.less(lhs.title, rhs.title)
                },
                singles: (artistSingles[name] ?? []).sorted { SortKey.less($0.title, $1.title) }
            )
        }
        return (albums, items, artists)
    }

    // MARK: Changes

    func delete(_ doomed: [Track]) {
        guard !doomed.isEmpty else { return }
        let doomedIDs = Set(doomed.map(\.id))
        let removedArt = customTrackArt.intersection(doomedIDs)
        if !removedArt.isEmpty {
            customTrackArt.subtract(removedArt)
            UserDefaults.standard.set(Array(customTrackArt), forKey: "customTrackArt")
        }

        let rootPath = root.canonicalPath
        let tracksToDelete = doomed
        Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            var folders = Set<URL>()
            for track in tracksToDelete {
                try? fileManager.removeItem(at: track.url)
                try? fileManager.removeItem(at: Self.lyricsURL(for: track))
                await ArtworkStore.shared.removeOverride(for: .track(track))
                folders.insert(track.folder)
            }
            // Drop folders that no longer hold any audio (never deleting Documents/Music itself).
            for folder in folders {
                let folderPath = folder.canonicalPath
                guard folderPath != rootPath, folderPath.hasPrefix(rootPath + "/") else { continue }
                let contents = (try? fileManager.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: []
                )) ?? []
                let hasAudio = contents.contains { Self.audioExtensions.contains($0.pathExtension.lowercased()) }
                let hasSubfolders = contents.contains {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }
                if !hasAudio, !hasSubfolders { try? fileManager.removeItem(at: folder) }
            }
            await MainActor.run { self.rescan() }
        }
    }

    /// Copies audio files (or whole folders, covers included) into the library. Returns how many
    /// audio files were added.
    func importItems(_ urls: [URL]) async -> Int {
        activeImportCount += 1
        isImporting = true
        defer {
            activeImportCount -= 1
            if activeImportCount <= 0 {
                activeImportCount = 0
                isImporting = false
            }
        }
        let root = self.root
        let added = await Task.detached(priority: .userInitiated) { () -> Int in
            var count = 0
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                count += Self.copyIntoLibrary(url, root: root)
            }
            return count
        }.value
        rescan()
        return added
    }

    private nonisolated static func copyIntoLibrary(_ url: URL, root: URL) -> Int {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }

        if isDirectory.boolValue {
            let destinationFolder = uniqueURL(root.appendingPathComponent(url.lastPathComponent, isDirectory: true))
            var count = 0
            guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { return 0 }
            let sourcePath = url.canonicalPath
            for case let file as URL in enumerator {
                let ext = file.pathExtension.lowercased()
                let isAudio = audioExtensions.contains(ext)
                guard isAudio || sidecarExtensions.contains(ext) else { continue }
                let filePath = file.canonicalPath
                guard filePath.hasPrefix(sourcePath + "/") else { continue }
                let relative = String(filePath.dropFirst(sourcePath.count + 1))
                let destination = destinationFolder.appendingPathComponent(relative)
                try? fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? fileManager.copyItem(at: file, to: destination)) != nil, isAudio { count += 1 }
            }
            return count
        }

        let ext = url.pathExtension.lowercased()
        if ext == "lrc" {
            let base = url.deletingPathExtension().lastPathComponent.lowercased()
            guard let match = audioFiles(in: root).first(where: {
                $0.url.deletingPathExtension().lastPathComponent.lowercased() == base
            }) else { return 0 }
            let destination = match.url.deletingPathExtension().appendingPathExtension("lrc")
            if let data = try? Data(contentsOf: url), !data.isEmpty, data.count < 2_000_000 {
                return (try? data.write(to: destination, options: .atomic)) != nil ? 1 : 0
            }
            return 0
        }
        guard audioExtensions.contains(ext) else { return 0 }
        let folder = root.appendingPathComponent("Imported", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = uniqueURL(folder.appendingPathComponent(url.lastPathComponent))
        return (try? fileManager.copyItem(at: url, to: destination)) != nil ? 1 : 0
    }

    private nonisolated static func uniqueURL(_ url: URL) -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let folder = url.deletingLastPathComponent()
        var counter = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    static let importableTypes: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff, .folder]
        + [UTType(filenameExtension: "flac"), UTType(filenameExtension: "lrc")].compactMap { $0 }
}

struct CachedEntry: Codable, Sendable {
    let size: Int64
    let modified: Double
    let info: TrackInfo
}
