import Foundation
import ImageIO
import SoulseekKit
import UIKit

/// Finds and caches cover art. Order for library items:
/// 0. a cover the user picked in the app (kept in Application Support, files untouched)
/// 1. an image file next to the music (cover.jpg, folder.jpg, …)
/// 2. art embedded in the audio file (extracted once into the cache folder)
/// 3. an iTunes Search lookup, if enabled in Settings
actor ArtworkStore {
    static let shared = ArtworkStore()

    private let memory = NSCache<NSString, UIImage>()
    private var inFlightFile: [String: Task<URL?, Never>] = [:]
    private var inFlightImage: [String: Task<UIImage?, Never>] = [:]
    private var generation = 0
    private var folderImages: [String: URL?] = [:]
    private var missingEmbedded = Set<String>()
    private var libraryRootPath: String?

    nonisolated let directory: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Lock-protected in-memory mirror of override keys so `hasOverride` never hits disk on MainActor.
    private static let overrideLock = NSLock()
    nonisolated(unsafe) private static var overrideFilenames: Set<String> = {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: overridesDirectory.path)) ?? []
        return Set(files)
    }()

    init() {
        memory.countLimit = 250
        memory.totalCostLimit = 64 * 1024 * 1024  // 64 MB cap prevents iOS Jetsam OOM
    }

    func setLibraryRoot(_ url: URL) {
        libraryRootPath = url.canonicalPath
    }

    /// `maxPixel` is the longest edge in pixels; images are decoded at (roughly) that size.
    func image(for source: ArtworkSource, maxPixel: Int) async -> UIImage? {
        let bucket = [160, 320, 640, 1200].first { $0 >= maxPixel } ?? 1200
        let keyString = "\(source.key)@\(bucket)"
        let cacheKey = keyString as NSString
        if let cached = memory.object(forKey: cacheKey) { return cached }

        if let existing = inFlightImage[keyString] {
            return await existing.value
        }

        let startGen = generation
        let task = Task<UIImage?, Never> {
            guard !Task.isCancelled else { return nil }
            guard let file = await self.file(for: source) else { return nil }
            guard !Task.isCancelled else { return nil }
            return await Task.detached(priority: .userInitiated) {
                Self.downsample(file, maxPixel: bucket)
            }.value
        }
        inFlightImage[keyString] = task
        let image = await task.value
        if inFlightImage[keyString] == task { inFlightImage[keyString] = nil }
        if let image, startGen == generation {
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? (bucket * bucket * 4)
            memory.setObject(image, forKey: cacheKey, cost: cost)
        }
        return image
    }

    /// Raw image data at full size (Now Playing info, sharing).
    func file(for source: ArtworkSource) async -> URL? {
        let key = source.key
        if let task = inFlightFile[key] { return await task.value }
        let task = Task { await self.resolve(source) }
        inFlightFile[key] = task
        let result = await task.value
        if inFlightFile[key] == task { inFlightFile[key] = nil }
        return result
    }

    /// Forget everything about this source (e.g. after a new cover was set or downloaded).
    func invalidate(_ source: ArtworkSource) {
        generation += 1
        inFlightFile.removeValue(forKey: source.key)?.cancel()
        for bucket in [160, 320, 640, 1200] {
            let key = "\(source.key)@\(bucket)"
            inFlightImage.removeValue(forKey: key)?.cancel()
            memory.removeObject(forKey: key as NSString)
        }
        let hash = MD5.hex(source.key)
        for prefix in ["emb-", "web-"] {
            for ext in ["img", "none"] {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(prefix)\(hash).\(ext)"))
            }
        }
    }

    /// Deletes extracted and downloaded covers (folder images next to the music are untouched).
    func clearDisk() {
        generation += 1
        for task in inFlightFile.values { task.cancel() }
        for task in inFlightImage.values { task.cancel() }
        inFlightFile.removeAll()
        inFlightImage.removeAll()
        memory.removeAllObjects()
        folderImages.removeAll()
        missingEmbedded.removeAll()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    /// Re-check folders for cover files next time, without dropping decoded images.
    func forgetFolderListings() {
        folderImages.removeAll()
    }

    func invalidateFolders() {
        generation += 1
        folderImages.removeAll()
        memory.removeAllObjects()
    }

    // MARK: Custom covers

    nonisolated static let overridesDirectory: URL = {
        let url = AppDirectories.applicationSupport.appendingPathComponent("ArtworkOverrides", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    nonisolated static func overrideFilename(for source: ArtworkSource) -> String {
        MD5.hex(source.key) + ".img"
    }

    nonisolated static func overrideURL(for source: ArtworkSource) -> URL {
        overridesDirectory.appendingPathComponent(overrideFilename(for: source))
    }

    nonisolated static func hasOverride(for source: ArtworkSource) -> Bool {
        let name = overrideFilename(for: source)
        overrideLock.lock(); defer { overrideLock.unlock() }
        return overrideFilenames.contains(name)
    }

    /// Saves picked image data as this album's or song's cover. Rejects anything ImageIO can't read.
    func setOverride(_ data: Data, for source: ArtworkSource) -> Bool {
        guard Self.isValidImage(data) else { return false }
        let url = Self.overrideURL(for: source)
        AppDirectories.ensureParentDirectory(for: url)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return false }
        let name = Self.overrideFilename(for: source)
        Self.overrideLock.lock()
        Self.overrideFilenames.insert(name)
        Self.overrideLock.unlock()
        invalidate(source)
        return true
    }

    func removeOverride(for source: ArtworkSource) {
        try? FileManager.default.removeItem(at: Self.overrideURL(for: source))
        let name = Self.overrideFilename(for: source)
        Self.overrideLock.lock()
        Self.overrideFilenames.remove(name)
        Self.overrideLock.unlock()
        invalidate(source)
    }

    // MARK: Resolution

    private func resolve(_ source: ArtworkSource) async -> URL? {
        guard !Task.isCancelled else { return nil }
        if case .remote = source {} else {
            if Self.hasOverride(for: source) {
                let custom = Self.overrideURL(for: source)
                if FileManager.default.fileExists(atPath: custom.path) { return custom }
            }
        }
        switch source {
        case let .album(album):
            if let local = folderImage(in: album.folder) { return local }
            // Check parent folder for multi-disc albums (e.g. Album/CD1/ -> Album/cover.jpg)
            let parent = album.folder.deletingLastPathComponent()
            if !isLibraryRoot(parent), let parentCover = folderImage(in: parent) { return parentCover }
            for track in album.tracks where track.hasEmbeddedArt {
                if let embedded = await embedded(track, cacheKey: source.key) { return embedded }
            }
            return await online(query: "\(album.artist) \(album.title)", entity: "album", cacheKey: source.key)

        case let .track(track):
            if !isLibraryRoot(track.folder), let local = folderImage(in: track.folder) { return local }
            if track.hasEmbeddedArt, let embedded = await embedded(track, cacheKey: source.key) { return embedded }
            return await online(query: "\(track.artist) \(track.title)", entity: "song", cacheKey: source.key)

        case let .remote(query):
            guard !query.isEmpty else { return nil }
            return await online(query: query, entity: "album", cacheKey: source.key)
        }
    }

    private func isLibraryRoot(_ folder: URL) -> Bool {
        if let rootPath = libraryRootPath {
            return folder.canonicalPath == rootPath
        }
        return folder.lastPathComponent == "Music" && folder.deletingLastPathComponent().lastPathComponent == "Documents"
    }

    private func folderImage(in folder: URL) -> URL? {
        let key = folder.canonicalPath
        if let known = folderImages[key] { return known }
        let found = Self.findFolderImage(in: folder)
        folderImages[key] = found
        return found
    }

    nonisolated static func findFolderImage(in folder: URL) -> URL? {
        let keys: [URLResourceKey] = [.fileSizeKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                         options: [.skipsHiddenFiles]) else { return nil }
        let images = contents.filter { LibraryStore.imageExtensions.contains($0.pathExtension.lowercased()) }
        guard !images.isEmpty else { return nil }
        let preferred = ["cover", "folder", "front", "album", "artwork", "art"]
        for name in preferred {
            if let match = images.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == name }) {
                return match
            }
        }
        for name in preferred {
            if let match = images.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased().contains(name) }) {
                return match
            }
        }
        func size(_ url: URL) -> Int {
            let values = try? url.resourceValues(forKeys: Set(keys))
            return values?.fileSize ?? 0
        }
        return images.max { size($0) < size($1) }
    }

    private func embedded(_ track: Track, cacheKey: String) async -> URL? {
        let file = directory.appendingPathComponent("emb-\(MD5.hex(cacheKey)).img")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard !missingEmbedded.contains(track.id) else { return nil }
        guard let data = await MetadataReader.embeddedArtwork(url: track.url),
              Self.isValidImage(data) else {
            missingEmbedded.insert(track.id)
            return nil
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        return file
    }

    private func online(query: String, entity: String, cacheKey: String) async -> URL? {
        let hash = MD5.hex(cacheKey)
        let file = directory.appendingPathComponent("web-\(hash).img")
        let miss = directory.appendingPathComponent("web-\(hash).none")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard AppSettings.artworkLookupEnabled else { return nil }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: miss.path),
           let date = attributes[.modificationDate] as? Date, Date().timeIntervalSince(date) < 7 * 86_400 {
            return nil
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, trimmed.lowercased() != "unknown artist unknown album" else { return nil }

        let startGen = generation
        switch await CoverLookup.shared.artwork(query: trimmed, entity: entity) {
        case let .found(data):
            guard startGen == generation, Self.isValidImage(data) else { return nil }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return (try? data.write(to: file, options: .atomic)) != nil ? file : nil
        case .notFound:
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: miss.path, contents: nil)
            return nil
        case .failed:
            return nil
        }
    }

    nonisolated static func isValidImage(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }

    nonisolated static func downsample(_ url: URL, maxPixel: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// iTunes Search API lookups, spaced cleanly without accumulating future debt on cancellation.
actor CoverLookup {
    static let shared = CoverLookup()

    enum Outcome {
        case found(Data)
        case notFound
        case failed
    }

    private var lastRequest = Date.distantPast
    private let spacing: TimeInterval = 3

    private static let discRegex = try! NSRegularExpression(pattern: #"^(cd|disc|disk)\s*\d+$"#, options: [.caseInsensitive])
    private static let cleanRegexes: [NSRegularExpression] = [
        #"\[[^\]]*\]"#, #"\([^)]*\)"#, #"\{[^}]*\}"#,
        #"\b(flac|mp3|aac|alac|ogg|opus|wav|320|256|192|v0|v2|vbr|cbr|web|cd|vinyl|lossless|hi-?res|24bit|16bit|24-\d+|16-44|kbps|remaster(ed)?|deluxe edition)\b"#,
        #"\b(19|20)\d{2}\b"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    private static let whitespaceRegex = try! NSRegularExpression(pattern: #"\s+"#)

    func artwork(query: String, entity: String) async -> Outcome {
        // Wait only until the next slot is available; cancel cleanly instead of pushing lastRequest minutes ahead.
        while true {
            if Task.isCancelled { return .failed }
            let remaining = spacing - Date().timeIntervalSince(lastRequest)
            if remaining <= 0 { break }
            do {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            } catch {
                return .failed
            }
        }
        if Task.isCancelled { return .failed }
        lastRequest = Date()

        guard var components = URLComponents(string: "https://itunes.apple.com/search") else { return .failed }
        components.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "limit", value: "3"),
        ]
        guard let url = components.url else { return .failed }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .failed }
            let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
            guard let small = decoded.results.first(where: { $0.artworkUrl100 != nil })?.artworkUrl100 else {
                return .notFound
            }
            let large = small.replacingOccurrences(of: "100x100bb", with: "1000x1000bb")
            guard let imageURL = URL(string: large) else { return .notFound }
            let (imageData, imageResponse) = try await URLSession.shared.data(from: imageURL)
            guard (imageResponse as? HTTPURLResponse)?.statusCode == 200, !imageData.isEmpty else { return .failed }
            return .found(imageData)
        } catch {
            return .failed
        }
    }

    private struct SearchResponse: Decodable {
        struct Result: Decodable {
            let artworkUrl100: String?
        }
        let results: [Result]
    }

    /// Turns a Soulseek folder path into an "artist album" search: drops format tags, years and
    /// bracketed junk, and uses the parent folder as the artist when the album folder lacks one.
    static func query(forFolderPath path: String) -> String {
        var parts = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
        guard !parts.isEmpty else { return "" }
        if let last = parts.last,
           discRegex.firstMatch(in: last, range: NSRange(last.startIndex..., in: last)) != nil,
           parts.count > 1 {
            parts.removeLast()
        }
        let album = clean(parts[parts.count - 1])
        if album.contains(" - ") || parts.count < 2 { return album.replacingOccurrences(of: " - ", with: " ") }
        let generic: Set<String> = ["music", "musique", "downloads", "complete", "shared", "soulseek", "albums", "mp3", "flac", "audio"]
        let parent = clean(parts[parts.count - 2])
        if generic.contains(parent.lowercased()) || parent.isEmpty { return album }
        return "\(parent) \(album)"
    }

    static func clean(_ name: String) -> String {
        var text = name.replacingOccurrences(of: "_", with: " ")
        for regex in cleanRegexes {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        }
        let wsRange = NSRange(text.startIndex..., in: text)
        text = whitespaceRegex.stringByReplacingMatches(in: text, range: wsRange, withTemplate: " ")
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " -.–"))
    }
}
