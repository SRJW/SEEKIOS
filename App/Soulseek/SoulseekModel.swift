import Foundation
import SoulseekKit

/// Elemento de la Lista de Deseos (Wishlist)
struct WishlistItem: Codable, Identifiable, Equatable {
    var id: String { query.lowercased() }
    let query: String
    var lastMatchCount: Int
    var lastChecked: Date?
}

/// Navegación hacia una carpeta remota de un usuario en Soulseek
struct BrowseTarget: Hashable, Identifiable {
    let username: String
    let folder: String
    var id: String { "\(username)|\(folder)" }
}

struct SoulseekLogEntry: Identifiable, Hashable {
    let id: Int
    let text: String
}

struct StorageBreakdown: Sendable {
    let musicBytes: UInt64
    let downloadsBytes: UInt64
    let incompleteBytes: UInt64
    let incompleteCount: Int
    let artworkCacheBytes: UInt64
}

@MainActor
final class SoulseekModel: ObservableObject {
    @Published private(set) var connection: ClientState = .disconnected
    @Published private(set) var listeningPort: UInt16 = 0
    @Published private(set) var wishlistIntervalSeconds: UInt32 = 720
    @Published private(set) var searchHistory: [String] = []
    @Published private(set) var wishlist: [WishlistItem] = []
    @Published private(set) var isCheckingWishlist = false
    @Published private(set) var favoriteUsers: [String] = []
    @Published private(set) var blockedUsers: [String] = []
    @Published private(set) var userStatuses: [String: UserStatus] = [:]
    @Published private(set) var logLines: [SoulseekLogEntry] = []
    @Published var username: String = UserDefaults.standard.string(forKey: "username") ?? ""

    /// Ruta personalizada de descargas elegida por el usuario (o nil si usa la carpeta por defecto de la app)
    @Published private(set) var customDownloadDirectory: URL?
    @Published var saveAllToCustomFolder: Bool = UserDefaults.standard.bool(forKey: "save_all_to_custom_folder_v1") {
        didSet { UserDefaults.standard.set(saveAllToCustomFolder, forKey: "save_all_to_custom_folder_v1") }
    }

    let client: SoulseekClient
    let library: LibraryStore
    let transfers: TransfersStore
    let searchStore: SearchStore
    let defaultDownloadsDirectory: URL
    let incompleteDirectory: URL
    weak var completeness: AlbumCompletenessStore?
    weak var stats: StatsStore?

    private var wishlistTokens: [UInt32: String] = [:]
    private var wishlistCheckTask: Task<Void, Never>?
    private var started = false
    private var coverRequested = Set<String>()
    private var hasSecurityScopeAccess = false
    private var nextLogID = 1

    private let searchHistoryKey = "search_history_v1"
    private let wishlistKey = "wishlist_items_v1"
    private let favoriteUsersKey = "favorite_users_v1"
    private let blockedUsersKey = "blocked_users_v1"
    private let customDownloadBookmarkKey = "custom_download_folder_bookmark_v1"
    private let customDownloadPathKey = "custom_download_folder_path_v1"

    var otherDownloadsDirectory: URL {
        customDownloadDirectory ?? defaultDownloadsDirectory
    }

    var currentDownloadFolderDisplayName: String {
        if let custom = customDownloadDirectory {
            let parts = custom.pathComponents.suffix(2).joined(separator: " › ")
            return parts.isEmpty ? custom.lastPathComponent : parts
        }
        return "On My iPhone › Seekios › Downloads"
    }

    var hasCredentials: Bool {
        !username.isEmpty && Keychain.load(account: username) != nil
    }

    var isLoggedIn: Bool { connection == .loggedIn }

    init(library: LibraryStore) {
        self.library = library
        let support = AppDirectories.applicationSupport
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let defaultDir = docs.appendingPathComponent("Downloads", isDirectory: true)
        let incompleteDir = support.appendingPathComponent("Incomplete", isDirectory: true)
        self.defaultDownloadsDirectory = defaultDir
        self.incompleteDirectory = incompleteDir
        try? FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: incompleteDir, withIntermediateDirectories: true)

        self.transfers = TransfersStore()
        self.searchStore = SearchStore()
        self.client = SoulseekClient(downloadDirectory: library.root, incompleteDirectory: incompleteDir)

        searchStore.blockedUsersProvider = { [weak self] in self?.blockedUsers ?? [] }
        searchStore.favoriteUsersProvider = { [weak self] in self?.favoriteUsers ?? [] }
        searchStore.onQueryMatchesUpdated = { [weak self] query, count in
            self?.updateWishlistCountIfMatching(query: query, count: count)
        }

        loadCustomDownloadFolder()
        transfers.loadHistory(client: client)
        loadSearchHistory()
        loadWishlistAndPeers()
        applyClientSettings()

        client.onEvent = { [weak self] event in self?.handle(event) }
        library.onSharesChanged = { [weak self] shares in self?.client.updateShares(shares) }
    }

    func applyClientSettings() {
        client.configure(
            maxConcurrentDownloads: AppSettings.maxConcurrentDownloads,
            maxConcurrentUploads: AppSettings.maxConcurrentUploads,
            maxQueuedPerPeer: AppSettings.maxQueuedPerPeer,
            distributedSearchEnabled: AppSettings.distributedSearchEnabled
        )
    }

    // MARK: - Gestión de Carpeta de Descargas Personalizada

    private func loadCustomDownloadFolder() {
        if let bookmarkData = UserDefaults.standard.data(forKey: customDownloadBookmarkKey) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmarkData, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale) {
                hasSecurityScopeAccess = url.startAccessingSecurityScopedResource()
                if isStale, let freshData = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    UserDefaults.standard.set(freshData, forKey: customDownloadBookmarkKey)
                }
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                customDownloadDirectory = url
                return
            }
        }
        if let savedPath = UserDefaults.standard.string(forKey: customDownloadPathKey), !savedPath.isEmpty {
            let url = URL(fileURLWithPath: savedPath, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) {
                hasSecurityScopeAccess = url.startAccessingSecurityScopedResource()
                customDownloadDirectory = url
            }
        }
    }

    @discardableResult
    func setCustomDownloadFolder(_ url: URL) -> Bool {
        if let old = customDownloadDirectory, hasSecurityScopeAccess {
            old.stopAccessingSecurityScopedResource()
            hasSecurityScopeAccess = false
        }

        let accessed = url.startAccessingSecurityScopedResource()
        hasSecurityScopeAccess = accessed
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: customDownloadBookmarkKey)
        }
        UserDefaults.standard.set(url.path, forKey: customDownloadPathKey)

        customDownloadDirectory = url
        return true
    }

    func createAndSelectSubfolder(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let clean = String(trimmed.map { "/:\0".contains($0) ? "_" : $0 })
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let newFolder = docs.appendingPathComponent(clean, isDirectory: true)
        try? FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        _ = setCustomDownloadFolder(newFolder)
    }

    func resetDownloadFolderToDefault() {
        if let old = customDownloadDirectory, hasSecurityScopeAccess {
            old.stopAccessingSecurityScopedResource()
            hasSecurityScopeAccess = false
        }
        customDownloadDirectory = nil
        UserDefaults.standard.removeObject(forKey: customDownloadBookmarkKey)
        UserDefaults.standard.removeObject(forKey: customDownloadPathKey)
    }

    // MARK: - Connection

    func start() {
        guard !started else { return }
        started = true
        library.rescan()
        reconnectIfNeeded()
    }

    func reconnectIfNeeded() {
        switch connection {
        case .disconnected, .failed:
            guard hasCredentials, let password = Keychain.load(account: username) else { return }
            applyClientSettings()
            client.connect(username: username, password: password)
        case .connecting, .loggedIn:
            break
        }
    }

    func logIn(username: String, password: String) {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !password.isEmpty else { return }
        if trimmed != self.username { Keychain.delete(account: self.username) }
        self.username = trimmed
        UserDefaults.standard.set(trimmed, forKey: "username")
        Keychain.save(password, account: trimmed)
        applyClientSettings()
        client.connect(username: trimmed, password: password)
    }

    func logOut() {
        wishlistCheckTask?.cancel()
        wishlistCheckTask = nil
        isCheckingWishlist = false
        client.disconnect()
    }

    // MARK: - Wishlist & Favorite / Blocked Users

    private func loadWishlistAndPeers() {
        if let data = UserDefaults.standard.data(forKey: wishlistKey),
           let decoded = try? JSONDecoder().decode([WishlistItem].self, from: data) {
            wishlist = decoded
        }
        favoriteUsers = UserDefaults.standard.stringArray(forKey: favoriteUsersKey) ?? []
        blockedUsers = UserDefaults.standard.stringArray(forKey: blockedUsersKey) ?? []
    }

    private func saveWishlist() {
        if let data = try? JSONEncoder().encode(wishlist) {
            UserDefaults.standard.set(data, forKey: wishlistKey)
        }
    }

    private func updateWishlistCountIfMatching(query: String, count: Int) {
        guard !query.isEmpty,
              let idx = wishlist.firstIndex(where: { $0.query.caseInsensitiveCompare(query) == .orderedSame }) else { return }
        if wishlist[idx].lastMatchCount != count {
            wishlist[idx].lastMatchCount = count
            wishlist[idx].lastChecked = Date()
            saveWishlist()
        }
    }

    func isInWishlist(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return wishlist.contains { $0.query.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    func toggleWishlist(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let index = wishlist.firstIndex(where: { $0.query.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            wishlist.remove(at: index)
        } else {
            let hits = searchStore.currentQuery.caseInsensitiveCompare(trimmed) == .orderedSame ? searchStore.results.count : 0
            wishlist.insert(WishlistItem(query: trimmed, lastMatchCount: hits, lastChecked: Date()), at: 0)
        }
        saveWishlist()
    }

    func removeWishlistItem(_ item: WishlistItem) {
        wishlist.removeAll { $0.id == item.id }
        saveWishlist()
    }

    /// Sends wishlist queries paced with Soulseek's native WishlistSearch (code 103) so the server
    /// doesn't throttle or silently drop searches.
    func checkAllWishlist() {
        guard isLoggedIn, !wishlist.isEmpty, !isCheckingWishlist else { return }
        isCheckingWishlist = true
        wishlistTokens.removeAll()
        let items = wishlist

        wishlistCheckTask?.cancel()
        wishlistCheckTask = Task { [weak self] in
            guard let self else { return }
            let spacingNs: UInt64 = 4_000_000_000  // 4s spacing prevents server flood drops
            for item in items {
                guard !Task.isCancelled, self.isLoggedIn else { break }
                if let idx = self.wishlist.firstIndex(where: { $0.id == item.id }) {
                    self.wishlist[idx].lastMatchCount = 0
                    self.wishlist[idx].lastChecked = Date()
                }
                let token = self.client.wishlistSearch(item.query)
                self.wishlistTokens[token] = item.query
                try? await Task.sleep(nanoseconds: spacingNs)
            }
            self.saveWishlist()
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            self.isCheckingWishlist = false
        }
    }

    func isFavoriteUser(_ user: String) -> Bool {
        favoriteUsers.contains { $0.caseInsensitiveCompare(user) == .orderedSame }
    }

    func toggleFavoriteUser(_ user: String) {
        let trimmed = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let idx = favoriteUsers.firstIndex(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            favoriteUsers.remove(at: idx)
        } else {
            favoriteUsers.insert(trimmed, at: 0)
            client.watchUser(trimmed)
        }
        UserDefaults.standard.set(favoriteUsers, forKey: favoriteUsersKey)
        searchStore.rebuildResults()
    }

    func isBlockedUser(_ user: String) -> Bool {
        blockedUsers.contains { $0.caseInsensitiveCompare(user) == .orderedSame }
    }

    func toggleBlockedUser(_ user: String) {
        let trimmed = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let idx = blockedUsers.firstIndex(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            blockedUsers.remove(at: idx)
        } else {
            blockedUsers.insert(trimmed, at: 0)
            favoriteUsers.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
            UserDefaults.standard.set(favoriteUsers, forKey: favoriteUsersKey)
        }
        UserDefaults.standard.set(blockedUsers, forKey: blockedUsersKey)
        searchStore.rebuildResults()
    }

    // MARK: - Search History

    private func loadSearchHistory() {
        searchHistory = UserDefaults.standard.stringArray(forKey: searchHistoryKey) ?? []
    }

    private func saveSearchHistory() {
        UserDefaults.standard.set(searchHistory, forKey: searchHistoryKey)
    }

    func recordSearchQuery(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchHistory.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        searchHistory.insert(trimmed, at: 0)
        if searchHistory.count > 40 {
            searchHistory = Array(searchHistory.prefix(40))
        }
        saveSearchHistory()
    }

    func removeSearchHistoryItem(_ item: String) {
        searchHistory.removeAll { $0 == item }
        saveSearchHistory()
    }

    func clearSearchHistory() {
        searchHistory.removeAll()
        saveSearchHistory()
    }

    // MARK: - Search & Lightweight Folder Browsing

    func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isLoggedIn else { return }
        recordSearchQuery(trimmed)
        let token = client.search(trimmed)
        searchStore.beginSearch(query: trimmed, token: token)
    }

    func stopActiveSearch() {
        guard let token = searchStore.activeTabID else { return }
        client.stopSearch(token)
        searchStore.markSearchStopped(token: token)
    }

    func closeSearchTab(_ token: UInt32) {
        searchStore.closeTab(token) { [weak self] stoppedToken in
            self?.client.stopSearch(stoppedToken)
        }
    }

    /// Lightweight Nicotine+-style browsing:
    /// - If `folder` is non-empty, asks ONLY `FolderContentsRequest` (code 36) unless full shares are requested.
    /// - If `folder` is empty (user root), asks `SharedFileListRequest` (code 4) and caches it.
    func browseUserFolder(username: String, folder: String, forceRefresh: Bool = false) async -> RemoteDirectoryIndex {
        if !forceRefresh, searchStore.hasFullShareList(for: username) {
            return await searchStore.directoryIndex(for: username)
        }

        if !folder.isEmpty {
            let folderFiles: [SharedFile]? = await withCheckedContinuation { cont in
                client.browseFolder(username: username, folder: folder) { files in
                    cont.resume(returning: files)
                }
            }
            if let folderFiles, !folderFiles.isEmpty {
                searchStore.mergeIntoCache(username: username, newFiles: folderFiles)
                return await searchStore.directoryIndex(for: username)
            }
            // Fallback to full share list only if the peer ignored FolderContentsRequest and we have nothing yet.
            if !searchStore.knownFiles(for: username).isEmpty && !forceRefresh {
                return await searchStore.directoryIndex(for: username)
            }
        }

        let allFiles: [SharedFile]? = await withCheckedContinuation { cont in
            client.browseUserShares(username: username) { files in
                cont.resume(returning: files)
            }
        }
        if let allFiles, !allFiles.isEmpty {
            searchStore.mergeIntoCache(username: username, newFiles: allFiles)
            searchStore.markFullShareListLoaded(for: username)
        }
        return await searchStore.directoryIndex(for: username)
    }

    func findTrack(artist: String, title: String) {
        guard isLoggedIn else {
            searchStore.beginTrackSearch(title: title, token: nil)
            return
        }
        let query = ResultFilters.terms("\(artist) \(title)").joined(separator: " ")
        let token = client.search(query)
        searchStore.beginTrackSearch(title: title, token: token)
    }

    func stopTrackSearch() {
        searchStore.stopTrackSearch()
    }

    // MARK: - Downloads & Uploads

    func download(_ file: SharedFile, from username: String, knownImages: [SharedFile] = []) {
        client.download(username: username, file: file)
        if LibraryStore.audioExtensions.contains(file.fileExtension) {
            fetchCover(username: username, folder: file.folder, knownImages: knownImages)
        }
    }

    func downloadFolder(_ folder: FolderResult) {
        folder.files.forEach { client.download(username: folder.username, file: $0) }
        if folder.isAudioFolder {
            fetchCover(username: folder.username, folder: folder.folder, knownImages: folder.images)
        }
    }

    func downloadFiles(_ files: [SharedFile], from username: String) {
        files.forEach { client.download(username: username, file: $0) }
        let audioFolders = Set(files.filter { LibraryStore.audioExtensions.contains($0.fileExtension) }.map(\.folder))
        let knownByFolder = Dictionary(grouping: files.filter { LibraryStore.imageExtensions.contains($0.fileExtension) }, by: \.folder)
        for folder in audioFolders {
            fetchCover(username: username, folder: folder, knownImages: knownByFolder[folder] ?? [])
        }
    }

    /// Uses lightweight `FolderContentsRequest` (code 36) ONLY — never triggers a massive full share list transfer.
    private func fetchCover(username: String, folder: String, knownImages: [SharedFile]) {
        guard !folder.isEmpty else { return }
        let key = username + "|" + folder
        guard !coverRequested.contains(key) else { return }
        coverRequested.insert(key)

        client.browseFolder(username: username, folder: folder) { [weak self] files in
            guard let self else { return }
            if let files, !files.isEmpty {
                self.searchStore.mergeIntoCache(username: username, newFiles: files)
                self.completeness?.recordListing(username: username, remoteFolder: folder, files: files)
            }
            let images = (files ?? []).filter { $0.folder == folder && LibraryStore.imageExtensions.contains($0.fileExtension) }
            if let best = Self.bestCover(images.isEmpty ? knownImages : images) {
                self.client.download(username: username, file: best)
            }
            for lyrics in (files ?? []) where lyrics.folder == folder && lyrics.fileExtension == "lrc" && lyrics.size < 512_000 {
                self.client.download(username: username, file: lyrics)
            }
        }
    }

    func downloadMissing(_ file: SharedFile, from username: String, into album: Album) {
        client.download(username: username, file: file, folderName: album.folder.lastPathComponent)
    }

    static func bestCover(_ images: [SharedFile]) -> SharedFile? {
        let usable = images.filter { $0.size > 0 && $0.size < 15_000_000 }
        let preferred = ["cover", "folder", "front", "album", "artwork"]
        for name in preferred {
            if let match = usable.first(where: { ($0.filename as NSString).deletingPathExtension.lowercased() == name }) {
                return match
            }
        }
        for name in preferred {
            if let match = usable.first(where: { $0.filename.lowercased().contains(name) }) { return match }
        }
        return usable.count <= 3 ? usable.max { $0.size < $1.size } : nil
    }

    func pause(_ item: DownloadItem) {
        client.pause(item.id)
    }

    func pause(_ ids: Set<DownloadID>) {
        for id in ids { client.pause(id) }
    }

    func retry(_ item: DownloadItem) {
        client.retry(item.id, size: item.size)
    }

    func cancel(_ item: DownloadItem, deletePartial: Bool = true) {
        remove([item.id], deletePartial: deletePartial)
    }

    func remove(_ ids: Set<DownloadID>, deletePartial: Bool = false) {
        for id in ids { client.cancel(id, deletePartial: deletePartial) }
        transfers.removeDownloads(ids)
    }

    @discardableResult
    func retry(_ ids: Set<DownloadID>) -> Int {
        var count = 0
        for item in transfers.downloads where ids.contains(item.id) {
            if item.isFailed || item.isPaused {
                client.retry(item.id, size: item.size)
                count += 1
            }
        }
        return count
    }

    func clearFinished() {
        remove(Set(transfers.downloads.filter { $0.isCompleted || $0.isFailed }.map(\.id)))
        transfers.clearFinishedUploads()
    }

    func clearCompleted() {
        remove(Set(transfers.downloads.filter(\.isCompleted).map(\.id)))
    }

    func clearFailed() {
        remove(Set(transfers.downloads.filter(\.isFailed).map(\.id)), deletePartial: true)
    }

    func retryAllFailed() {
        retry(Set(transfers.downloads.filter { $0.isFailed || $0.isPaused }.map(\.id)))
    }

    func pauseAllActive() {
        pause(Set(transfers.downloads.filter(\.isActive).map(\.id)))
    }

    func cancelAllActive() {
        remove(Set(transfers.downloads.filter(\.isActive).map(\.id)), deletePartial: true)
    }

    func abortUpload(_ item: UploadItem) {
        client.abortUpload(item.id)
    }

    func clearFinishedUploads() {
        transfers.clearFinishedUploads()
    }

    func libraryTracks(for ids: Set<DownloadID>) -> [Track] {
        transfers.downloads.compactMap { item -> Track? in
            guard ids.contains(item.id) else { return nil }
            if let libURL = item.libraryURL, let track = library.track(at: libURL) { return track }
            if case let .completed(url) = item.state { return library.track(at: url) }
            return nil
        }
    }

    func cancelAll(from username: String) {
        remove(Set(transfers.downloads.filter { $0.id.username == username }.map(\.id)), deletePartial: true)
    }

    // MARK: - Storage Inspection & Orphan Partial Cleanup

    func computeStorageBreakdown() async -> StorageBreakdown {
        let musicRoot = library.root
        let downloadsRoot = otherDownloadsDirectory
        let incompleteRoot = incompleteDirectory
        let artworkRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Artwork", isDirectory: true)

        return await Task.detached(priority: .utility) {
            func dirStats(_ url: URL) -> (UInt64, Int) {
                var total: UInt64 = 0
                var count = 0
                let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
                guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else {
                    return (0, 0)
                }
                for case let fileURL as URL in enumerator {
                    guard let vals = try? fileURL.resourceValues(forKeys: Set(keys)), vals.isRegularFile == true else { continue }
                    total += UInt64(max(0, vals.fileSize ?? 0))
                    count += 1
                }
                return (total, count)
            }
            let music = dirStats(musicRoot).0
            let downloads = downloadsRoot.canonicalPath == musicRoot.canonicalPath ? 0 : dirStats(downloadsRoot).0
            let incomplete = dirStats(incompleteRoot)
            let artwork = dirStats(artworkRoot).0
            return StorageBreakdown(
                musicBytes: music,
                downloadsBytes: downloads,
                incompleteBytes: incomplete.0,
                incompleteCount: incomplete.1,
                artworkCacheBytes: artwork
            )
        }.value
    }

    func cleanOrphanedPartials() async -> Int {
        let activeHashes = Set(
            transfers.downloads
                .filter { !$0.isCompleted }
                .map { MD5.hex($0.id.username + "\n" + $0.id.path) + ".part" }
        )
        let incompleteRoot = incompleteDirectory
        return await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: incompleteRoot, includingPropertiesForKeys: nil) else { return 0 }
            var removed = 0
            for file in files where file.pathExtension == "part" {
                if !activeHashes.contains(file.lastPathComponent) {
                    if (try? fm.removeItem(at: file)) != nil { removed += 1 }
                }
            }
            return removed
        }.value
    }

    // MARK: - Background File Relocation (off MainActor)

    private nonisolated static func relocateCompletedFile(
        fileURL: URL,
        remotePath: String,
        isAudioOrSidecar: Bool,
        saveAllToCustomFolder: Bool,
        customDownloadDirectory: URL?,
        targetBase: URL,
        libraryRoot: URL
    ) -> (displayURL: URL, libraryURL: URL?) {
        if isAudioOrSidecar && (!saveAllToCustomFolder || customDownloadDirectory == nil) {
            return (fileURL, fileURL)
        }
        let fm = FileManager.default
        let scoped = targetBase.startAccessingSecurityScopedResource()
        defer { if scoped { targetBase.stopAccessingSecurityScopedResource() } }

        let shared = SharedFile(path: remotePath, size: 0)
        let rawFolderName = shared.folder.split(separator: "\\").last.map(String.init) ?? "Misc"
        let cleanFolderName = String(rawFolderName.map { "/:\0".contains($0) ? "_" : $0 })
        let targetSubfolder = targetBase.appendingPathComponent(cleanFolderName, isDirectory: true)
        try? fm.createDirectory(at: targetSubfolder, withIntermediateDirectories: true)

        let destinationURL = targetSubfolder.appendingPathComponent(fileURL.lastPathComponent)
        if fileURL.canonicalPath == destinationURL.canonicalPath {
            return (fileURL, isAudioOrSidecar ? fileURL : nil)
        }
        try? fm.removeItem(at: destinationURL)
        do {
            if isAudioOrSidecar {
                try fm.copyItem(at: fileURL, to: destinationURL)
                return (destinationURL, fileURL)
            } else {
                try fm.moveItem(at: fileURL, to: destinationURL)
                let parentDir = fileURL.deletingLastPathComponent()
                if parentDir.canonicalPath != libraryRoot.canonicalPath,
                   let contents = try? fm.contentsOfDirectory(atPath: parentDir.path),
                   contents.isEmpty {
                    try? fm.removeItem(at: parentDir)
                }
                return (destinationURL, nil)
            }
        } catch {
            return (fileURL, isAudioOrSidecar ? fileURL : nil)
        }
    }

    // MARK: - Events

    private func handle(_ event: ClientEvent) {
        switch event {
        case let .state(state):
            connection = state
            if state == .loggedIn {
                for user in favoriteUsers { client.watchUser(user) }
            } else if case let .failed(message) = state {
                appendLog(message)
            }

        case let .listeningPort(port):
            listeningPort = port

        case let .wishlistInterval(seconds):
            wishlistIntervalSeconds = max(seconds, 60)

        case let .userStatus(username, status):
            userStatuses[username.lowercased()] = status

        case let .searchResponse(response):
            if let wishQuery = wishlistTokens[response.token] {
                if !isBlockedUser(response.username) && !response.files.isEmpty {
                    if let idx = wishlist.firstIndex(where: { $0.query.caseInsensitiveCompare(wishQuery) == .orderedSame }) {
                        wishlist[idx].lastMatchCount += 1
                        wishlist[idx].lastChecked = Date()
                        saveWishlist()
                    }
                }
            }
            _ = searchStore.ingestSearchResponse(response)

        case let .download(update):
            let ext = SharedFile(path: update.id.path, size: 0).fileExtension.lowercased()
            let isAudio = LibraryStore.audioExtensions.contains(ext)
            let isSidecar = LibraryStore.sidecarExtensions.contains(ext)

            if case let .completed(url) = update.state {
                let wasCompleted = transfers.item(for: update.id)?.isCompleted ?? false
                if !wasCompleted { stats?.recordDownload(bytes: update.size, from: update.id.username) }

                let needsRelocate = !(isAudio || isSidecar) || (saveAllToCustomFolder && customDownloadDirectory != nil)
                if needsRelocate {
                    let targetBase = otherDownloadsDirectory
                    let customDir = customDownloadDirectory
                    let saveAll = saveAllToCustomFolder
                    let libRoot = library.root
                    Task { [weak self] in
                        let relocated = await Task.detached(priority: .userInitiated) {
                            Self.relocateCompletedFile(
                                fileURL: url,
                                remotePath: update.id.path,
                                isAudioOrSidecar: isAudio || isSidecar,
                                saveAllToCustomFolder: saveAll,
                                customDownloadDirectory: customDir,
                                targetBase: targetBase,
                                libraryRoot: libRoot
                            )
                        }.value
                        guard let self else { return }
                        self.transfers.applyDownloadUpdate(update, finalState: .completed(relocated.displayURL), libraryURL: relocated.libraryURL)
                        self.handleCompletedSideEffects(ext: ext, isAudio: isAudio)
                    }
                } else {
                    transfers.applyDownloadUpdate(update, finalState: .completed(url), libraryURL: url)
                    handleCompletedSideEffects(ext: ext, isAudio: isAudio)
                }
            } else {
                transfers.applyDownloadUpdate(update, finalState: update.state)
            }

        case let .upload(update):
            if update.state == .completed,
               transfers.uploads.first(where: { $0.id == update.id })?.state != .completed {
                stats?.recordUpload(bytes: update.size, to: update.id.username)
            }
            transfers.applyUploadUpdate(update)

        case let .log(line):
            appendLog(line)
        }
    }

    private func handleCompletedSideEffects(ext: String, isAudio: Bool) {
        if ext == "lrc" {
            // Sidecar lyrics
        } else if LibraryStore.imageExtensions.contains(ext) {
            let library = self.library
            Task {
                await ArtworkStore.shared.invalidateFolders()
                library.bumpArtwork()
            }
        } else if isAudio {
            library.rescan()
        }
    }

    private func appendLog(_ line: String) {
        let stamp = Formatting.time.string(from: Date())
        logLines.append(SoulseekLogEntry(id: nextLogID, text: "\(stamp)  \(line)"))
        nextLogID += 1
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
        Diagnostics.shared.log(line, category: "soulseek")
    }
}
