import SoulseekKit
import SwiftUI

private enum SearchViewMode: String, CaseIterable, Identifiable {
    case folders = "Folders"
    case files = "Files"
    var id: String { rawValue }
}

struct SearchView: View {
    @EnvironmentObject private var soulseek: SoulseekModel
    @EnvironmentObject private var searchStore: SearchStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var router: AppRouter

    @State private var path = NavigationPath()
    @State private var query = ""
    @State private var keywordFilter = ""
    @State private var isSearchFocused = false
    @State private var showFilters = false
    @State private var showPeersSheet = false
    @State private var viewMode: SearchViewMode = .folders

    private var displayedResults: [FolderResult] {
        let trimmed = keywordFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return searchStore.results }
        let rawTerms = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        let includeTerms = rawTerms.filter { !$0.hasPrefix("-") }
        let excludeTerms = rawTerms.filter { $0.hasPrefix("-") && $0.count > 1 }.map { String($0.dropFirst()) }

        return searchStore.results.filter { folder in
            let folderText = "\(folder.folderLowercased) \(folder.username.lowercased())"
            if excludeTerms.contains(where: { ex in
                folderText.contains(ex) || folder.files.contains { $0.filename.lowercased().contains(ex) }
            }) {
                return false
            }
            return includeTerms.allSatisfy { term in
                if folderText.contains(term) { return true }
                return folder.files.contains { $0.filename.lowercased().contains(term) }
            }
        }
    }

    private func flatFiles(from folders: [FolderResult]) -> [FlatFileResult] {
        let trimmed = keywordFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let includeTerms = trimmed.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.hasPrefix("-") }
        var out: [FlatFileResult] = []
        out.reserveCapacity(min(folders.count * 4, 400))
        for folder in folders {
            for file in folder.files {
                if !includeTerms.isEmpty {
                    let hay = "\(folder.folderLowercased) \(folder.username.lowercased()) \(file.filename.lowercased())"
                    if !includeTerms.allSatisfy({ hay.contains($0) }) { continue }
                }
                out.append(FlatFileResult(
                    id: "\(folder.username)|\(file.path)",
                    username: folder.username,
                    file: file,
                    folderImages: folder.images,
                    slotFree: folder.slotFree,
                    speed: folder.speed,
                    queueLength: folder.queueLength
                ))
                if out.count >= 400 { return out }
            }
        }
        return out
    }

    private var matchingHistory: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return soulseek.searchHistory }
        return soulseek.searchHistory.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    private var shouldShowHomeSections: Bool {
        isSearchFocused || searchStore.currentQuery.isEmpty
    }

    var body: some View {
        NavigationStack(path: $path) {
            let shownFolders = displayedResults
            List {
                if !soulseek.isLoggedIn {
                    Section { ConnectionBanner() }
                }

                // Multi-tab bar for concurrent / recent in-memory searches (Nicotine+-style)
                if !searchStore.tabs.isEmpty && !isSearchFocused {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(searchStore.tabs) { tab in
                                    let isSelected = tab.id == searchStore.activeTabID
                                    HStack(spacing: 6) {
                                        Button {
                                            query = tab.query
                                            keywordFilter = ""
                                            searchStore.selectTab(tab.id)
                                        } label: {
                                            HStack(spacing: 5) {
                                                if tab.isActive {
                                                    ProgressView().controlSize(.mini)
                                                }
                                                Text(tab.query)
                                                    .lineLimit(1)
                                            }
                                            .font(.caption.weight(.semibold))
                                        }
                                        .buttonStyle(.plain)

                                        Button {
                                            soulseek.closeSearchTab(tab.id)
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.caption2.weight(.bold))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                                    .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.15)), in: Capsule())
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        .listRowBackground(Color.clear)
                    }
                }

                // 1. Wishlist
                if shouldShowHomeSections && !soulseek.wishlist.isEmpty {
                    Section {
                        ForEach(soulseek.wishlist) { item in
                            Button {
                                query = item.query
                                keywordFilter = ""
                                isSearchFocused = false
                                soulseek.search(item.query)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "star.fill")
                                        .foregroundStyle(.yellow)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.query)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        if let checked = item.lastChecked {
                                            Text("Checked \(checked.formatted(.relative(presentation: .named)))")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if item.lastMatchCount > 0 {
                                        Text("\(item.lastMatchCount) hits")
                                            .font(.caption.weight(.semibold))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Color.green.opacity(0.2), in: Capsule())
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    soulseek.removeWishlistItem(item)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Label("Wishlist", systemImage: "star.circle.fill")
                            Spacer()
                            Button {
                                soulseek.checkAllWishlist()
                            } label: {
                                if soulseek.isCheckingWishlist {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("Check All")
                                }
                            }
                            .font(.caption.weight(.semibold))
                            .textCase(nil)
                            .disabled(!soulseek.isLoggedIn || soulseek.isCheckingWishlist)
                        }
                    }
                }

                // 2. Favorite Users (direct browse)
                if shouldShowHomeSections && !soulseek.favoriteUsers.isEmpty {
                    Section("Favorite Users (Tap to Browse)") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(soulseek.favoriteUsers, id: \.self) { user in
                                    Button {
                                        path.append(BrowseTarget(username: user, folder: ""))
                                    } label: {
                                        HStack(spacing: 5) {
                                            if let status = soulseek.userStatuses[user.lowercased()] {
                                                Circle()
                                                    .fill(status == .online ? Color.green : (status == .away ? Color.orange : Color.gray))
                                                    .frame(width: 7, height: 7)
                                            }
                                            Label(user, systemImage: "person.crop.circle.badge.checkmark")
                                        }
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(Color.secondary.opacity(0.15), in: Capsule())
                                        .foregroundStyle(.tint)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                // 3. Recent Search History (sibling buttons — no nested Button hit-testing bug)
                if shouldShowHomeSections && !matchingHistory.isEmpty {
                    Section {
                        ForEach(matchingHistory, id: \.self) { item in
                            HStack(spacing: 10) {
                                Button {
                                    query = item
                                    keywordFilter = ""
                                    isSearchFocused = false
                                    soulseek.search(item)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .foregroundStyle(.secondary)
                                        Text(item)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Button {
                                    soulseek.toggleWishlist(item)
                                } label: {
                                    Image(systemName: soulseek.isInWishlist(item) ? "star.fill" : "star")
                                        .foregroundStyle(soulseek.isInWishlist(item) ? .yellow : .secondary)
                                }
                                .buttonStyle(.borderless)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    soulseek.removeSearchHistoryItem(item)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("Recent Searches")
                            Spacer()
                            Button("Clear") {
                                soulseek.clearSearchHistory()
                            }
                            .font(.caption.weight(.semibold))
                            .textCase(nil)
                        }
                    }
                }

                // 4. Active Search Results
                if !searchStore.currentQuery.isEmpty && !isSearchFocused {
                    Section {
                        FilterChips(showAll: $showFilters, viewMode: $viewMode)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }

                    // Live keyword filter (supports -exclude terms) + Wishlist button
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "line.3.horizontal.decrease")
                                .foregroundStyle(.secondary)
                            TextField("Filter (supports -exclude, user, ext)…", text: $keywordFilter)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            if !keywordFilter.isEmpty {
                                Button {
                                    keywordFilter = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            Divider().frame(height: 18)
                            Button {
                                soulseek.toggleWishlist(searchStore.currentQuery)
                            } label: {
                                let saved = soulseek.isInWishlist(searchStore.currentQuery)
                                Label(saved ? "Saved" : "Wishlist", systemImage: saved ? "star.fill" : "star")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(saved ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tint))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }

                    // Status + Stop Search + Clear Filters
                    Section {
                        HStack(spacing: 8) {
                            if searchStore.isSearching {
                                ProgressView().controlSize(.mini)
                            }
                            let keywordHidden = max(0, searchStore.results.count - shownFolders.count)
                            let totalHidden = searchStore.hiddenCount + keywordHidden
                            Text("\(searchStore.responseCount) users · \(shownFolders.count) folders")
                            if totalHidden > 0 {
                                Text("· \(totalHidden) hidden")
                            }
                            Spacer()
                            if searchStore.isSearching {
                                Button("Stop") {
                                    soulseek.stopActiveSearch()
                                }
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.orange)
                            } else if searchStore.filters.activeCount > 0 || searchStore.audioOnly || !keywordFilter.isEmpty {
                                Button("Clear Filters") {
                                    searchStore.audioOnly = false
                                    keywordFilter = ""
                                    searchStore.filters = ResultFilters(sort: searchStore.filters.sort)
                                }
                                .font(.footnote.weight(.semibold))
                            }
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    if viewMode == .folders {
                        ForEach(shownFolders) { folder in
                            NavigationLink(value: folder.id) {
                                FolderRow(
                                    folder: folder,
                                    isFavorite: soulseek.isFavoriteUser(folder.username),
                                    inLibrary: library.ownsFolder(named: folder.name)
                                )
                            }
                            .contextMenu {
                                Button {
                                    path.append(BrowseTarget(username: folder.username, folder: folder.folder))
                                } label: {
                                    Label("Browse Full Folder", systemImage: "folder")
                                }
                                if let parent = folder.parentFolderPath {
                                    Button {
                                        path.append(BrowseTarget(username: folder.username, folder: parent))
                                    } label: {
                                        Label("Browse Parent Folder", systemImage: "folder.badge.gearshape")
                                    }
                                }
                                Button {
                                    path.append(BrowseTarget(username: folder.username, folder: ""))
                                } label: {
                                    Label("Browse All User Files (\(folder.username))", systemImage: "externaldrive.fill.badge.person.crop")
                                }
                                Button {
                                    soulseek.downloadFolder(folder)
                                } label: {
                                    Label("Download Folder", systemImage: "arrow.down.circle")
                                }
                                Divider()
                                Button {
                                    soulseek.toggleFavoriteUser(folder.username)
                                } label: {
                                    Label(soulseek.isFavoriteUser(folder.username) ? "Remove Favorite User" : "Favorite User (\(folder.username))",
                                          systemImage: soulseek.isFavoriteUser(folder.username) ? "star.slash" : "star")
                                }
                                Button(role: .destructive) {
                                    soulseek.toggleBlockedUser(folder.username)
                                } label: {
                                    Label("Block User (\(folder.username))", systemImage: "hand.raised.fill")
                                }
                            }
                        }
                    } else {
                        let flat = flatFiles(from: shownFolders)
                        ForEach(flat) { entry in
                            FileRow(
                                file: entry.file,
                                username: entry.username,
                                folderImages: entry.folderImages,
                                showUserBadge: true,
                                slotFree: entry.slotFree,
                                speed: entry.speed,
                                inLibrary: library.ownsFile(named: entry.file.filename),
                                onBrowseFolder: { target in path.append(target) }
                            )
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Search")
            .searchable(text: $query, isPresented: $isSearchFocused, prompt: "Search any file, album, zip, book…")
            .onSubmit(of: .search) {
                keywordFilter = ""
                isSearchFocused = false
                if !soulseek.isLoggedIn {
                    router.message = soulseek.hasCredentials
                        ? "Reconnecting to Soulseek… try again in a moment."
                        : "Log in to Soulseek under Settings to search."
                    soulseek.reconnectIfNeeded()
                } else {
                    soulseek.search(query)
                }
            }
            .onReceive(router.$pendingSearch) { pending in
                guard let pending else { return }
                query = pending
                keywordFilter = ""
                isSearchFocused = false
                soulseek.search(pending)
                router.pendingSearch = nil
            }
            .navigationDestination(for: String.self) { id in
                FolderDetailView(folderID: id, onBrowse: { target in path.append(target) })
            }
            .navigationDestination(for: BrowseTarget.self) { target in
                RemoteFolderBrowserView(target: target)
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showPeersSheet = true
                    } label: {
                        Image(systemName: "person.2.crop.square.stack")
                    }
                    Button {
                        showFilters = true
                    } label: {
                        Image(systemName: (searchStore.filters.activeCount > 0 || searchStore.audioOnly)
                              ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .sheet(isPresented: $showFilters) {
                SearchFiltersView()
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showPeersSheet) {
                PeersManagerSheet { target in
                    showPeersSheet = false
                    path.append(target)
                }
            }
            .overlay {
                if searchStore.currentQuery.isEmpty && soulseek.searchHistory.isEmpty && soulseek.wishlist.isEmpty && soulseek.isLoggedIn && !isSearchFocused {
                    EmptyStateView(title: "Search Soulseek",
                                   message: "Search for music, videos, archives, books or any file. Results stream in live.",
                                   systemImage: "magnifyingglass")
                }
            }
        }
    }
}

/// Manage Favorite and Blocked users (with direct browse & manual block input).
struct PeersManagerSheet: View {
    var onBrowseUser: ((BrowseTarget) -> Void)? = nil
    @EnvironmentObject private var soulseek: SoulseekModel
    @Environment(\.dismiss) private var dismiss
    @State private var newUsername = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Add User Manually") {
                    TextField("Soulseek username…", text: $newUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack(spacing: 12) {
                        Button {
                            let trimmed = newUsername.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            if !soulseek.isFavoriteUser(trimmed) { soulseek.toggleFavoriteUser(trimmed) }
                            newUsername = ""
                        } label: {
                            Label("Add Favorite", systemImage: "star.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button(role: .destructive) {
                            let trimmed = newUsername.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            if !soulseek.isBlockedUser(trimmed) { soulseek.toggleBlockedUser(trimmed) }
                            newUsername = ""
                        } label: {
                            Label("Block User", systemImage: "hand.raised.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .disabled(newUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("Favorite Users (\(soulseek.favoriteUsers.count))") {
                    if soulseek.favoriteUsers.isEmpty {
                        Text("Long-press any search result folder to favorite a fast user.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(soulseek.favoriteUsers, id: \.self) { user in
                            HStack {
                                Button {
                                    onBrowseUser?(BrowseTarget(username: user, folder: ""))
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                                        Text(user).foregroundStyle(.primary)
                                        if let status = soulseek.userStatuses[user.lowercased()] {
                                            Text(status == .online ? "Online" : (status == .away ? "Away" : "Offline"))
                                                .font(.caption2)
                                                .foregroundStyle(status == .online ? .green : .secondary)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                Spacer()
                                Button("Remove", role: .destructive) {
                                    soulseek.toggleFavoriteUser(user)
                                }
                                .font(.caption)
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                Section("Blocked Users / Blacklist (\(soulseek.blockedUsers.count))") {
                    if soulseek.blockedUsers.isEmpty {
                        Text("Blocked users are automatically hidden from all search results.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(soulseek.blockedUsers, id: \.self) { user in
                            HStack {
                                Label(user, systemImage: "hand.raised.fill")
                                    .foregroundStyle(.red)
                                Spacer()
                                Button("Unblock") {
                                    soulseek.toggleBlockedUser(user)
                                }
                                .font(.caption)
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Favorite & Blocked Users")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct FolderRow: View {
    let folder: FolderResult
    var isFavorite: Bool = false
    var inLibrary: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if folder.isAudioFolder && !folder.coverQuery.isEmpty {
                ArtworkView(source: .remote(folder.coverQuery), size: 60, cornerRadius: 6)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.14))
                    Image(systemName: iconForFolder)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 60, height: 60)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(folder.name)
                        .font(.headline)
                        .lineLimit(2)
                    if inLibrary {
                        Text("Owned")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.18), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                if !folder.parentPath.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.caption2)
                        Text(folder.parentPath)
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text(folder.formatSummary)
                    Text("\(folder.files.count) files")
                    Text(Formatting.bytes(folder.totalSize))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Label(folder.username, systemImage: isFavorite ? "star.fill" : "person")
                        .foregroundStyle(isFavorite ? .yellow : .primary)
                        .lineLimit(1)
                    if folder.slotFree {
                        Label("Free slot", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Queue \(folder.queueLength)", systemImage: "hourglass")
                            .foregroundStyle(.orange)
                    }
                    Text(Formatting.speed(folder.speed))
                }
                .font(.caption2)
                .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, 2)
    }

    private var iconForFolder: String {
        if !folder.extensions.isDisjoint(with: ResultFilters.videoSet) { return "film" }
        if !folder.extensions.isDisjoint(with: ResultFilters.archiveSet) { return "doc.zipper" }
        if !folder.extensions.isDisjoint(with: ResultFilters.documentSet) { return "book" }
        if !folder.extensions.isDisjoint(with: ResultFilters.imageSet) { return "photo" }
        return "folder.fill"
    }
}

struct FolderDetailView: View {
    let folderID: String
    let onBrowse: (BrowseTarget) -> Void
    @EnvironmentObject private var soulseek: SoulseekModel
    @EnvironmentObject private var searchStore: SearchStore
    @EnvironmentObject private var library: LibraryStore
    @State private var fileFilter = ""
    @State private var directoryIndex: RemoteDirectoryIndex = .empty
    @State private var isLoadingFullFolder = false

    var body: some View {
        if let folder = searchStore.folder(withID: folderID) {
            let direct = directoryIndex.directFiles(in: folder.folder)
            let allFolderFiles = direct.isEmpty ? folder.files : direct
            let subfolders = directoryIndex.subfolders(in: folder.folder)
            let trimmedFilter = fileFilter.trimmingCharacters(in: .whitespaces)
            let filteredFiles = trimmedFilter.isEmpty
                ? allFolderFiles
                : allFolderFiles.filter { $0.filename.localizedCaseInsensitiveContains(trimmedFilter) }

            List {
                Section {
                    HStack(spacing: 16) {
                        if folder.isAudioFolder && !folder.coverQuery.isEmpty {
                            ArtworkView(source: .remote(folder.coverQuery), size: 110, cornerRadius: 10)
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.14))
                                Image(systemName: "folder.fill").font(.largeTitle).foregroundStyle(.tint)
                            }
                            .frame(width: 90, height: 90)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(folder.name).font(.headline)
                            Text(folder.formatSummary).font(.subheadline).foregroundStyle(.secondary)
                            Text("\(allFolderFiles.count) files · \(Formatting.bytes(allFolderFiles.reduce(0) { $0 + $1.size }))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if isLoadingFullFolder {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.mini)
                                    Text("Fetching folder listing…")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                }

                Section("Container & Root Folders (Tap to Browse)") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            Button {
                                onBrowse(BrowseTarget(username: folder.username, folder: ""))
                            } label: {
                                Label(folder.username, systemImage: "person.crop.square.fill")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.secondary.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.tint)
                            }
                            .buttonStyle(.plain)

                            ForEach(Array(folder.pathLevels.enumerated()), id: \.offset) { _, level in
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Button {
                                    onBrowse(BrowseTarget(username: folder.username, folder: level.fullPath))
                                } label: {
                                    Label(level.name, systemImage: "folder.fill")
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color.secondary.opacity(0.15), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }

                    if let parent = folder.parentFolderPath {
                        Button {
                            onBrowse(BrowseTarget(username: folder.username, folder: parent))
                        } label: {
                            Label("Go Up to Parent Folder", systemImage: "arrow.turn.left.up")
                        }
                    }

                    Button {
                        onBrowse(BrowseTarget(username: folder.username, folder: ""))
                    } label: {
                        Label("Browse All Shared Folders of \(folder.username)", systemImage: "externaldrive.fill.badge.person.crop")
                    }
                }

                if !subfolders.isEmpty {
                    Section("Subfolders Inside (\(subfolders.count))") {
                        ForEach(subfolders) { sub in
                            Button {
                                onBrowse(BrowseTarget(username: folder.username, folder: sub.fullPath))
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(.tint)
                                    Text(sub.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text("\(sub.totalFileCount) files")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    Button {
                        soulseek.downloadFiles(allFolderFiles, from: folder.username)
                    } label: {
                        Label("Download All (\(allFolderFiles.count) files)", systemImage: "arrow.down.circle.fill")
                    }
                    .disabled(!soulseek.isLoggedIn)

                    Button {
                        soulseek.toggleFavoriteUser(folder.username)
                    } label: {
                        Label(soulseek.isFavoriteUser(folder.username) ? "Remove \(folder.username) from Favorites" : "Add \(folder.username) to Favorite Users",
                              systemImage: soulseek.isFavoriteUser(folder.username) ? "star.slash" : "star")
                    }
                } footer: {
                    Text("From \(folder.username) · \(folder.folder)")
                }

                Section("Files in Folder (\(filteredFiles.count))") {
                    if allFolderFiles.count > 5 {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("Filter files in this folder…", text: $fileFilter)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            if !fileFilter.isEmpty {
                                Button { fileFilter = "" } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    ForEach(filteredFiles, id: \.path) { file in
                        FileRow(
                            file: file,
                            username: folder.username,
                            folderImages: folder.images,
                            inLibrary: library.ownsFile(named: file.filename),
                            onBrowseFolder: onBrowse
                        )
                    }
                }
            }
            .navigationTitle(folder.name)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: folder.id) {
                directoryIndex = await searchStore.directoryIndex(for: folder.username)
                isLoadingFullFolder = true
                // Lightweight FolderContentsRequest (code 36) only!
                directoryIndex = await soulseek.browseUserFolder(username: folder.username, folder: folder.folder)
                isLoadingFullFolder = false
            }
        } else {
            Text("This result is no longer available.")
                .foregroundStyle(.secondary)
        }
    }
}

/// Fast O(1) indexed remote directory browser with in-place path navigation (no infinite NavigationStack push),
/// recursive folder downloads, and multi-file selection.
struct RemoteFolderBrowserView: View {
    let target: BrowseTarget
    @EnvironmentObject private var soulseek: SoulseekModel
    @EnvironmentObject private var searchStore: SearchStore
    @EnvironmentObject private var library: LibraryStore

    @State private var currentPath: String
    @State private var directoryIndex: RemoteDirectoryIndex = .empty
    @State private var isLoading = true
    @State private var filterText = ""
    @State private var selectedPaths = Set<String>()
    @State private var isSelecting = false

    init(target: BrowseTarget) {
        self.target = target
        self._currentPath = State(initialValue: target.folder)
    }

    private var folderTitle: String {
        currentPath.split(separator: "\\").last.map(String.init) ?? target.username
    }

    private var parentPath: String? {
        let parts = currentPath.split(separator: "\\")
        guard parts.count > 1 else { return nil }
        return parts.dropLast().joined(separator: "\\")
    }

    private var pathLevels: [(name: String, fullPath: String)] {
        let parts = currentPath.split(separator: "\\").map(String.init)
        var acc = ""
        return parts.map { part in
            acc = acc.isEmpty ? part : "\(acc)\\\(part)"
            return (name: part, fullPath: acc)
        }
    }

    var body: some View {
        let trimmed = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        let rawSubfolders = directoryIndex.subfolders(in: currentPath)
        let subfolders = trimmed.isEmpty ? rawSubfolders : rawSubfolders.filter { $0.name.lowercased().contains(trimmed) }
        let rawFiles = directoryIndex.directFiles(in: currentPath)
        let directFiles = trimmed.isEmpty ? rawFiles : rawFiles.filter { $0.filename.lowercased().contains(trimmed) }
        let recursiveFiles = directoryIndex.recursiveFiles(under: currentPath)

        List {
            Section("Path Navigation") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Button {
                            navigate(to: "")
                        } label: {
                            Label(target.username, systemImage: "person.crop.square.fill")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                                .foregroundStyle(.tint)
                        }
                        .buttonStyle(.plain)

                        ForEach(Array(pathLevels.enumerated()), id: \.offset) { _, level in
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Button {
                                navigate(to: level.fullPath)
                            } label: {
                                Label(level.name, systemImage: "folder.fill")
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.secondary.opacity(0.15), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }

                if let parent = parentPath {
                    Button {
                        navigate(to: parent)
                    } label: {
                        Label("Up to Parent Folder", systemImage: "arrow.turn.left.up")
                    }
                } else if !currentPath.isEmpty {
                    Button {
                        navigate(to: "")
                    } label: {
                        Label("Up to User Root (\(target.username))", systemImage: "arrow.turn.left.up")
                    }
                }
            }

            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter folders or files here…", text: $filterText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !filterText.isEmpty {
                        Button { filterText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if isLoading {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(currentPath.isEmpty
                             ? "Requesting full share list from \(target.username)…"
                             : "Requesting folder contents from \(target.username)…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }

            if !subfolders.isEmpty {
                Section {
                    if recursiveFiles.count > directFiles.count {
                        Button {
                            soulseek.downloadFiles(recursiveFiles, from: target.username)
                        } label: {
                            Label("Download Entire Tree (\(recursiveFiles.count) files)", systemImage: "arrow.down.doc.fill")
                        }
                        .disabled(!soulseek.isLoggedIn)
                    }

                    ForEach(subfolders) { sub in
                        Button {
                            navigate(to: sub.fullPath)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill")
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(sub.name)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    Text("\(sub.totalFileCount) files inside")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                let subFiles = directoryIndex.recursiveFiles(under: sub.fullPath)
                                soulseek.downloadFiles(subFiles, from: target.username)
                            } label: {
                                Label("Download Subfolder (\(sub.totalFileCount) files)", systemImage: "arrow.down.circle")
                            }
                        }
                    }
                } header: {
                    Text("Subfolders (\(subfolders.count))")
                }
            }

            if !directFiles.isEmpty {
                Section {
                    if isSelecting {
                        HStack {
                            Button(selectedPaths.count == directFiles.count ? "Deselect All" : "Select All") {
                                if selectedPaths.count == directFiles.count {
                                    selectedPaths.removeAll()
                                } else {
                                    selectedPaths = Set(directFiles.map(\.path))
                                }
                            }
                            .font(.caption.weight(.semibold))
                            Spacer()
                            Button("Download Selected (\(selectedPaths.count))") {
                                let chosen = directFiles.filter { selectedPaths.contains($0.path) }
                                soulseek.downloadFiles(chosen, from: target.username)
                                selectedPaths.removeAll()
                                isSelecting = false
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(selectedPaths.isEmpty || !soulseek.isLoggedIn)
                        }
                    } else {
                        Button {
                            soulseek.downloadFiles(directFiles, from: target.username)
                        } label: {
                            Label("Download All Files in This Folder (\(directFiles.count))", systemImage: "arrow.down.circle.fill")
                        }
                        .disabled(!soulseek.isLoggedIn)
                    }

                    ForEach(directFiles, id: \.path) { file in
                        if isSelecting {
                            Button {
                                if selectedPaths.contains(file.path) {
                                    selectedPaths.remove(file.path)
                                } else {
                                    selectedPaths.insert(file.path)
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: selectedPaths.contains(file.path) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedPaths.contains(file.path) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(file.filename).foregroundStyle(.primary).lineLimit(2)
                                        Text(Formatting.bytes(file.size)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        } else {
                            FileRow(
                                file: file,
                                username: target.username,
                                folderImages: [],
                                inLibrary: library.ownsFile(named: file.filename),
                                onBrowseFolder: { next in navigate(to: next.folder) }
                            )
                        }
                    }
                } header: {
                    HStack {
                        Text("Files (\(directFiles.count))")
                        Spacer()
                        Button(isSelecting ? "Done" : "Select") {
                            isSelecting.toggle()
                            if !isSelecting { selectedPaths.removeAll() }
                        }
                        .font(.caption.weight(.semibold))
                        .textCase(nil)
                    }
                }
            }

            if !isLoading && subfolders.isEmpty && directFiles.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No files or subfolders found at this level.")
                            .foregroundStyle(.secondary)
                        if !currentPath.isEmpty && !searchStore.hasFullShareList(for: target.username) {
                            Button("Load Full User Share List") {
                                Task { await loadFullShareList() }
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                    }
                }
            }
        }
        .navigationTitle(folderTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    soulseek.toggleFavoriteUser(target.username)
                } label: {
                    Image(systemName: soulseek.isFavoriteUser(target.username) ? "star.fill" : "star")
                        .foregroundStyle(soulseek.isFavoriteUser(target.username) ? .yellow : .primary)
                }
                Button {
                    Task { await loadCurrentFolder(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .task(id: "\(target.username)|\(currentPath)") {
            await loadCurrentFolder(force: false)
        }
    }

    private func navigate(to path: String) {
        selectedPaths.removeAll()
        isSelecting = false
        filterText = ""
        currentPath = path
    }

    private func loadCurrentFolder(force: Bool) async {
        directoryIndex = await searchStore.directoryIndex(for: target.username)
        // If we already have full shares cached and aren't forcing refresh, instant O(1) navigation!
        if !force && searchStore.hasFullShareList(for: target.username) {
            isLoading = false
            return
        }
        isLoading = true
        directoryIndex = await soulseek.browseUserFolder(username: target.username, folder: currentPath, forceRefresh: force)
        isLoading = false
    }

    private func loadFullShareList() async {
        isLoading = true
        directoryIndex = await soulseek.browseUserFolder(username: target.username, folder: "", forceRefresh: true)
        isLoading = false
    }
}

struct FileRow: View {
    let file: SharedFile
    let username: String
    let folderImages: [SharedFile]
    var showUserBadge: Bool = false
    var slotFree: Bool = true
    var speed: UInt32 = 0
    var inLibrary: Bool = false
    var onBrowseFolder: ((BrowseTarget) -> Void)? = nil
    @EnvironmentObject private var soulseek: SoulseekModel

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.filename)
                        .lineLimit(2)
                    if inLibrary {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if showUserBadge {
                    HStack(spacing: 6) {
                        Label(username, systemImage: "person")
                        if slotFree {
                            Text("Free").foregroundStyle(.green)
                        } else {
                            Text("Queued").foregroundStyle(.orange)
                        }
                        Text(Formatting.speed(speed))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
            FileStatusButton(file: file, username: username, folderImages: folderImages)
        }
        .contextMenu {
            Button {
                soulseek.download(file, from: username, knownImages: folderImages)
            } label: {
                Label("Download File", systemImage: "arrow.down.circle")
            }
            if let onBrowseFolder {
                Button {
                    onBrowseFolder(BrowseTarget(username: username, folder: file.folder))
                } label: {
                    Label("Open Container Folder", systemImage: "folder")
                }
            }
        }
    }

    private var details: String {
        var parts: [String] = []
        let ext = file.fileExtension.uppercased()
        if !ext.isEmpty { parts.append(ext) }
        parts.append(Formatting.bytes(file.size))
        if let duration = file.attributes.duration { parts.append(Formatting.duration(Double(duration))) }
        if let bitrate = file.attributes.bitrate { parts.append("\(bitrate) kbps") }
        if let depth = file.attributes.bitDepth, let rate = file.attributes.sampleRate {
            parts.append("\(depth)-bit/\(Formatting.kilohertz(rate)) kHz")
        }
        return parts.joined(separator: " · ")
    }
}

/// Isolated subview so only individual rows showing active transfer status subscribe to TransfersStore.
private struct FileStatusButton: View {
    let file: SharedFile
    let username: String
    let folderImages: [SharedFile]
    @EnvironmentObject private var soulseek: SoulseekModel
    @EnvironmentObject private var transfers: TransfersStore

    var body: some View {
        switch transfers.state(of: file, from: username) {
        case .none, .some(.failed), .some(.paused):
            Button {
                soulseek.download(file, from: username, knownImages: folderImages)
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .disabled(!soulseek.isLoggedIn)
        case let .some(.completed(url)):
            HStack(spacing: 10) {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body)
                }
                .buttonStyle(.borderless)
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        default:
            ProgressView()
        }
    }
}

struct SearchFiltersView: View {
    @EnvironmentObject private var searchStore: SearchStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Sort By", selection: $searchStore.filters.sort) {
                        ForEach(ResultFilters.Sort.allCases) { sort in
                            Label(sort.rawValue, systemImage: sort.systemImage).tag(sort)
                        }
                    }
                }

                Section("File Type & Quality") {
                    Picker("Category", selection: $searchStore.filters.fileType) {
                        ForEach(ResultFilters.FileType.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Minimum Bitrate", selection: $searchStore.filters.minBitrate) {
                        ForEach(ResultFilters.bitrateChoices, id: \.self) { kbps in
                            Text(kbps == 0 ? "Any" : "\(kbps) kbps").tag(kbps)
                        }
                    }
                    Toggle("Hi-Res Audio Only (24-bit / >48 kHz)", isOn: $searchStore.filters.hiResOnly)
                    Toggle("Audio Formats Only", isOn: $searchStore.audioOnly)
                    TextField("Exact extension (e.g. flac, epub, mkv)", text: $searchStore.filters.exactExtension)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Toggle("Free Upload Slot Only", isOn: $searchStore.filters.freeSlotOnly)
                    Picker("Minimum Folder Size", selection: $searchStore.filters.minSizeMB) {
                        ForEach(ResultFilters.sizeMBChoices, id: \.self) { mb in
                            Text(mb == 0 ? "Any" : "≥ \(mb) MB").tag(mb)
                        }
                    }
                    Stepper(value: $searchStore.filters.minFiles, in: 1...30) {
                        LabeledContent("Minimum Files", value: searchStore.filters.minFiles == 1 ? "Any" : "\(searchStore.filters.minFiles)")
                    }
                } header: {
                    Text("Availability & Size")
                } footer: {
                    Text("A minimum of around 6 files skips single files and finds full albums or packs.")
                }

                Section {
                    TextField("live, remix, sample", text: $searchStore.filters.excludeWords)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Exclude Words")
                } footer: {
                    Text("Hides folders whose path contains any of these. You can also type -word in the live filter.")
                }

                if !searchStore.filters.isDefault || searchStore.audioOnly {
                    Section {
                        Button("Reset Filters", role: .destructive) {
                            searchStore.audioOnly = false
                            searchStore.filters = ResultFilters()
                        }
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct FilterChips: View {
    @Binding var showAll: Bool
    @Binding var viewMode: SearchViewMode
    @EnvironmentObject private var searchStore: SearchStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    viewMode = (viewMode == .folders) ? .files : .folders
                } label: {
                    chip(viewMode == .folders ? "Folders" : "Files",
                         systemImage: viewMode == .folders ? "folder" : "doc.text",
                         active: viewMode == .files)
                }

                Menu {
                    Picker("Sort By", selection: $searchStore.filters.sort) {
                        ForEach(ResultFilters.Sort.allCases) { sort in
                            Label(sort.rawValue, systemImage: sort.systemImage).tag(sort)
                        }
                    }
                } label: {
                    chip(searchStore.filters.sort.rawValue, systemImage: "arrow.up.arrow.down", active: true)
                }

                Menu {
                    Picker("File Type", selection: $searchStore.filters.fileType) {
                        ForEach(ResultFilters.FileType.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    chip(searchStore.filters.fileType.shortLabel, systemImage: "doc", active: searchStore.filters.fileType != .any)
                }

                Button {
                    searchStore.audioOnly.toggle()
                } label: {
                    chip("Audio Only", systemImage: "music.note", active: searchStore.audioOnly)
                }

                Button {
                    searchStore.filters.freeSlotOnly.toggle()
                } label: {
                    chip("Free Slot", systemImage: "checkmark.circle", active: searchStore.filters.freeSlotOnly)
                }

                Button {
                    showAll = true
                } label: {
                    let count = searchStore.filters.activeCount
                    chip(count > 0 ? "More (\(count))" : "More", systemImage: "slider.horizontal.3", active: count > 0)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func chip(_ title: String, systemImage: String, active: Bool) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(active ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary.opacity(0.15)), in: Capsule())
    }
}
