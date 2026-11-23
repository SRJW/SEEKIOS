import Foundation
import SoulseekKit

/// A folder from one user's search results — precomputes display summaries once at creation time.
struct FolderResult: Identifiable {
    let id: String
    let username: String
    let folder: String
    let folderLowercased: String
    let name: String
    let parentPath: String
    let parentFolderPath: String?
    let pathLevels: [(name: String, fullPath: String)]
    let files: [SharedFile]
    let images: [SharedFile]
    let slotFree: Bool
    let speed: UInt32
    let queueLength: UInt32
    let totalSize: UInt64
    let extensions: Set<String>
    let isAudioFolder: Bool
    let isLossless: Bool
    let isHiRes: Bool
    let qualityScore: Int
    let formatSummary: String
    let coverQuery: String

    init(
        id: String,
        username: String,
        folder: String,
        files: [SharedFile],
        images: [SharedFile],
        slotFree: Bool,
        speed: UInt32,
        queueLength: UInt32
    ) {
        self.id = id
        self.username = username
        self.folder = folder
        self.folderLowercased = folder.lowercased()
        let parts = folder.split(separator: "\\").map(String.init)
        self.name = parts.last ?? username
        self.parentPath = parts.dropLast().joined(separator: " › ")
        self.parentFolderPath = parts.count > 1 ? parts.dropLast().joined(separator: "\\") : nil
        var current = ""
        self.pathLevels = parts.map { part in
            current = current.isEmpty ? part : "\(current)\\\(part)"
            return (name: part, fullPath: current)
        }
        let sortedFiles = files.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        self.files = sortedFiles
        self.images = images
        self.slotFree = slotFree
        self.speed = speed
        self.queueLength = queueLength
        self.totalSize = sortedFiles.reduce(0) { $0 + $1.size }

        let exts = Set(sortedFiles.map { $0.fileExtension.lowercased() })
        self.extensions = exts
        self.isAudioFolder = !exts.isDisjoint(with: ResultFilters.audioSet)
        let lossless = !sortedFiles.isEmpty && sortedFiles.allSatisfy { file in
            ["flac", "wav", "aif", "aiff", "alac"].contains(file.fileExtension.lowercased()) || file.attributes.bitDepth != nil
        }
        self.isLossless = lossless
        let maxDepth = sortedFiles.compactMap(\.attributes.bitDepth).max() ?? 0
        let maxRate = sortedFiles.compactMap(\.attributes.sampleRate).max() ?? 0
        self.isHiRes = lossless && (maxDepth >= 24 || maxRate > 48_000)

        if lossless {
            let depth = maxDepth > 0 ? maxDepth : 16
            let rate = maxRate > 0 ? maxRate : 44_100
            self.qualityScore = 10_000 + Int(depth) * 100 + Int(rate / 1000)
        } else if let minBitrate = sortedFiles.compactMap(\.attributes.bitrate).min() {
            self.qualityScore = Int(minBitrate)
        } else {
            self.qualityScore = Int(min(totalSize / 1_048_576, 5_000))
        }

        let displayExts = Set(sortedFiles.map {
            let ext = $0.fileExtension.uppercased()
            return ext.isEmpty ? "FILE" : ext
        }).sorted()
        var summary = displayExts.prefix(4).joined(separator: "/")
        if displayExts.count > 4 { summary += " +\(displayExts.count - 4)" }
        if let file = sortedFiles.first(where: { $0.attributes.bitDepth != nil }),
           let depth = file.attributes.bitDepth, let rate = file.attributes.sampleRate {
            summary += " \(depth)/\(Formatting.kilohertz(rate))"
        } else if let bitrate = sortedFiles.compactMap({ $0.attributes.bitrate }).max() {
            summary += " \(bitrate)k"
        }
        self.formatSummary = summary
        self.coverQuery = isAudioFolder ? CoverLookup.query(forFolderPath: folder) : ""
    }
}

/// Flattened single-file search result (Nicotine+ flat list mode).
struct FlatFileResult: Identifiable {
    let id: String
    let username: String
    let file: SharedFile
    let folderImages: [SharedFile]
    let slotFree: Bool
    let speed: UInt32
    let queueLength: UInt32
}

struct TrackCandidate: Identifiable {
    let username: String
    let file: SharedFile
    let slotFree: Bool
    let speed: UInt32
    let queueLength: UInt32
    var id: String { username + "|" + file.path }
}

/// Pre-indexed directory tree for O(1) folder navigation in RemoteFolderBrowserView
/// (eliminates 9x full linear scans over 30k+ peer files on every render).
struct RemoteDirectoryIndex: Sendable {
    struct SubfolderInfo: Identifiable, Hashable, Sendable {
        let name: String
        let fullPath: String
        let totalFileCount: Int
        var id: String { fullPath }
    }

    /// Lowercased folder path -> direct files sorted by filename.
    let filesByFolder: [String: [SharedFile]]
    /// Lowercased folder path -> immediate child subfolders sorted by name.
    let subfoldersByFolder: [String: [SubfolderInfo]]
    /// All files in the user's known tree (for recursive folder download).
    let allFiles: [SharedFile]

    static let empty = RemoteDirectoryIndex(filesByFolder: [:], subfoldersByFolder: [:], allFiles: [])

    static func build(from files: [SharedFile]) -> RemoteDirectoryIndex {
        var deduped: [SharedFile] = []
        var seen = Set<String>()
        deduped.reserveCapacity(files.count)
        for f in files where seen.insert(f.path.lowercased()).inserted {
            deduped.append(f)
        }

        var directMap: [String: [SharedFile]] = [:]
        // parentLower -> [childLower: (name, fullPath, count)]
        var childMap: [String: [String: (name: String, fullPath: String, count: Int)]] = [:]

        for file in deduped {
            let folder = file.folder
            let folderKey = folder.lowercased()
            directMap[folderKey, default: []].append(file)

            let parts = folder.split(separator: "\\").map(String.init)
            var currentPath = ""
            var parentKey = ""
            for part in parts {
                let nextPath = currentPath.isEmpty ? part : "\(currentPath)\\\(part)"
                let childKey = part.lowercased()
                var entry = childMap[parentKey]?[childKey] ?? (name: part, fullPath: nextPath, count: 0)
                entry.count += 1
                childMap[parentKey, default: [:]][childKey] = entry
                parentKey = nextPath.lowercased()
                currentPath = nextPath
            }
        }

        for key in directMap.keys {
            directMap[key]?.sort { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        }

        var sortedSubfolders: [String: [SubfolderInfo]] = [:]
        for (parentKey, children) in childMap {
            sortedSubfolders[parentKey] = children.values
                .map { SubfolderInfo(name: $0.name, fullPath: $0.fullPath, totalFileCount: $0.count) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }

        return RemoteDirectoryIndex(filesByFolder: directMap, subfoldersByFolder: sortedSubfolders, allFiles: deduped)
    }

    func directFiles(in folder: String) -> [SharedFile] {
        filesByFolder[folder.lowercased()] ?? []
    }

    func subfolders(in folder: String) -> [SubfolderInfo] {
        subfoldersByFolder[folder.lowercased()] ?? []
    }

    func recursiveFiles(under folder: String) -> [SharedFile] {
        if folder.isEmpty { return allFiles }
        let targetLower = folder.lowercased()
        let prefixLower = targetLower + "\\"
        return allFiles.filter { file in
            let f = file.folder.lowercased()
            return f == targetLower || f.hasPrefix(prefixLower)
        }
    }
}

/// Stored in-memory search tab so users can keep recent searches open like Nicotine+.
struct SearchTab: Identifiable {
    let id: UInt32
    let query: String
    var responses: [SearchResponse]
    var isActive: Bool
}

/// Dedicated observable store for search state and remote directory indexes.
@MainActor
final class SearchStore: ObservableObject {
    @Published private(set) var results: [FolderResult] = []
    @Published private(set) var responseCount = 0
    @Published private(set) var currentQuery = ""
    @Published private(set) var isSearching = false
    @Published private(set) var hiddenCount = 0
    @Published private(set) var tabs: [SearchTab] = []
    @Published private(set) var activeTabID: UInt32?
    @Published private(set) var trackCandidates: [TrackCandidate] = []
    @Published private(set) var isFindingTrack = false

    @Published var audioOnly = false {
        didSet { rebuildResults() }
    }
    @Published var filters = ResultFilters.load() {
        didSet {
            filters.save()
            rebuildResults()
        }
    }

    private var pendingByToken: [UInt32: [SearchResponse]] = [:]
    private var flushScheduled = false
    private var searchTimeoutTasks: [UInt32: Task<Void, Never>] = [:]
    private var trackSearchToken: UInt32?
    private var trackSearchTitle = ""
    private var trackTimeoutTask: Task<Void, Never>?

    private var browseCache: [String: [SharedFile]] = [:]
    private var directoryIndexCache: [String: RemoteDirectoryIndex] = [:]
    private var fullBrowseLoadedUsers = Set<String>()

    var blockedUsersProvider: () -> [String] = { [] }
    var favoriteUsersProvider: () -> [String] = { [] }
    var onQueryMatchesUpdated: ((String, Int) -> Void)?

    func beginSearch(query: String, token: UInt32) {
        let tab = SearchTab(id: token, query: query, responses: [], isActive: true)
        tabs.insert(tab, at: 0)
        if tabs.count > 5 {
            let dropped = tabs.removeLast()
            searchTimeoutTasks[dropped.id]?.cancel()
            searchTimeoutTasks.removeValue(forKey: dropped.id)
            pendingByToken.removeValue(forKey: dropped.id)
        }
        activeTabID = token
        currentQuery = query
        isSearching = true
        results = []
        responseCount = 0
        hiddenCount = 0

        searchTimeoutTasks[token]?.cancel()
        searchTimeoutTasks[token] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 35_000_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.markSearchStopped(token: token)
        }
    }

    func selectTab(_ id: UInt32) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        activeTabID = tab.id
        currentQuery = tab.query
        isSearching = tab.isActive
        rebuildResults()
    }

    func closeTab(_ id: UInt32, onStop: (UInt32) -> Void) {
        onStop(id)
        searchTimeoutTasks[id]?.cancel()
        searchTimeoutTasks.removeValue(forKey: id)
        pendingByToken.removeValue(forKey: id)
        tabs.removeAll { $0.id == id }
        if activeTabID == id {
            if let next = tabs.first {
                selectTab(next.id)
            } else {
                activeTabID = nil
                currentQuery = ""
                isSearching = false
                results = []
                responseCount = 0
                hiddenCount = 0
            }
        }
    }

    func markSearchStopped(token: UInt32) {
        searchTimeoutTasks[token]?.cancel()
        searchTimeoutTasks.removeValue(forKey: token)
        if let idx = tabs.firstIndex(where: { $0.id == token }) {
            tabs[idx].isActive = false
        }
        if activeTabID == token {
            isSearching = false
        }
    }

    func clearActiveSearch() {
        activeTabID = nil
        currentQuery = ""
        isSearching = false
        results = []
        responseCount = 0
        hiddenCount = 0
    }

    func beginTrackSearch(title: String, token: UInt32?) {
        trackTimeoutTask?.cancel()
        trackCandidates = []
        trackSearchTitle = AlbumCompletenessStore.normalizeTitle(title)
        trackSearchToken = token
        isFindingTrack = token != nil
        guard token != nil else { return }
        trackTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 25_000_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.isFindingTrack = false
        }
    }

    func stopTrackSearch() {
        trackTimeoutTask?.cancel()
        trackTimeoutTask = nil
        trackSearchToken = nil
        isFindingTrack = false
    }

    func ingestSearchResponse(_ response: SearchResponse) -> Bool {
        if response.token == trackSearchToken {
            addTrackCandidates(from: response)
            return true
        }
        guard tabs.contains(where: { $0.id == response.token }) else { return false }
        pendingByToken[response.token, default: []].append(response)
        if !flushScheduled {
            flushScheduled = true
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                self?.flushPendingResponses()
            }
        }
        return true
    }

    private func flushPendingResponses() {
        flushScheduled = false
        guard !pendingByToken.isEmpty else { return }
        let batch = pendingByToken
        pendingByToken.removeAll()

        var activeTouched = false
        for (token, incoming) in batch {
            for resp in incoming {
                mergeIntoCache(username: resp.username, newFiles: resp.files)
            }
            if let idx = tabs.firstIndex(where: { $0.id == token }) {
                tabs[idx].responses += incoming
                if token == activeTabID { activeTouched = true }
            }
        }
        if activeTouched {
            rebuildResults()
        }
    }

    func folder(withID id: String) -> FolderResult? {
        results.first { $0.id == id }
    }

    func rebuildResults() {
        guard let activeTabID, let tab = tabs.first(where: { $0.id == activeTabID }) else {
            results = []
            responseCount = 0
            hiddenCount = 0
            return
        }
        responseCount = tab.responses.count
        let blockedSet = Set(blockedUsersProvider().map { $0.lowercased() })
        let favSet = Set(favoriteUsersProvider().map { $0.lowercased() })

        var groupedFiles: [String: (username: String, folder: String, files: [SharedFile], slotFree: Bool, speed: UInt32, queue: UInt32)] = [:]
        var images: [String: [SharedFile]] = [:]

        for response in tab.responses {
            if blockedSet.contains(response.username.lowercased()) { continue }

            for file in response.files where LibraryStore.imageExtensions.contains(file.fileExtension) {
                images[response.username + "|" + file.folder, default: []].append(file)
            }
            let files = audioOnly
                ? response.files.filter { LibraryStore.audioExtensions.contains($0.fileExtension) }
                : response.files
            for file in files {
                let key = response.username + "|" + file.folder
                if groupedFiles[key] == nil {
                    groupedFiles[key] = (response.username, file.folder, [file], response.slotFree, response.averageSpeed, response.queueLength)
                } else {
                    groupedFiles[key]?.files.append(file)
                }
            }
        }

        let all = groupedFiles.map { key, entry in
            FolderResult(
                id: key,
                username: entry.username,
                folder: entry.folder,
                files: entry.files,
                images: images[key] ?? [],
                slotFree: entry.slotFree,
                speed: entry.speed,
                queueLength: entry.queue
            )
        }
        let kept = all.filter { filters.accepts($0) }
        hiddenCount = all.count - kept.count
        let ordered = filters.ordered(kept, query: currentQuery)

        results = ordered.sorted { lhs, rhs in
            let lFav = favSet.contains(lhs.username.lowercased())
            let rFav = favSet.contains(rhs.username.lowercased())
            if lFav != rFav { return lFav }
            return false
        }
        onQueryMatchesUpdated?(currentQuery, results.count)
    }

    private func addTrackCandidates(from response: SearchResponse) {
        let wanted = trackSearchTitle
        let matches = response.files.filter { file in
            guard LibraryStore.audioExtensions.contains(file.fileExtension) else { return false }
            let name = AlbumCompletenessStore.normalizeTitle((file.filename as NSString).deletingPathExtension)
            return wanted.isEmpty || name.contains(wanted)
        }
        guard !matches.isEmpty else { return }
        trackCandidates += matches.prefix(5).map {
            TrackCandidate(username: response.username, file: $0, slotFree: response.slotFree,
                           speed: response.averageSpeed, queueLength: response.queueLength)
        }
        trackCandidates.sort { lhs, rhs in
            if lhs.slotFree != rhs.slotFree { return lhs.slotFree }
            let left = lhs.file.attributes.bitDepth != nil ? 2_000 : Int(lhs.file.attributes.bitrate ?? 0)
            let right = rhs.file.attributes.bitDepth != nil ? 2_000 : Int(rhs.file.attributes.bitrate ?? 0)
            if left != right { return left > right }
            return lhs.speed > rhs.speed
        }
        if trackCandidates.count > 60 { trackCandidates.removeLast(trackCandidates.count - 60) }
    }

    // MARK: - Remote Directory Tree Cache & Indexing

    func hasFullShareList(for username: String) -> Bool {
        fullBrowseLoadedUsers.contains(username.lowercased())
    }

    func markFullShareListLoaded(for username: String) {
        fullBrowseLoadedUsers.insert(username.lowercased())
    }

    func mergeIntoCache(username: String, newFiles: [SharedFile]) {
        guard !newFiles.isEmpty else { return }
        let key = username.lowercased()
        var existing = browseCache[key] ?? []
        var seen = Set(existing.map { $0.path.lowercased() })
        var changed = false
        for file in newFiles {
            if seen.insert(file.path.lowercased()).inserted {
                existing.append(file)
                changed = true
            }
        }
        if changed {
            browseCache[key] = existing
            directoryIndexCache.removeValue(forKey: key)
        }
    }

    func knownFiles(for username: String) -> [SharedFile] {
        browseCache[username.lowercased()] ?? []
    }

    func directoryIndex(for username: String) async -> RemoteDirectoryIndex {
        let key = username.lowercased()
        if let cached = directoryIndexCache[key] { return cached }
        let files = browseCache[key] ?? []
        let built = await Task.detached(priority: .userInitiated) {
            RemoteDirectoryIndex.build(from: files)
        }.value
        // Only cache if underlying array hasn't changed while building.
        if (browseCache[key]?.count ?? 0) == files.count {
            directoryIndexCache[key] = built
        }
        return built
    }
}
