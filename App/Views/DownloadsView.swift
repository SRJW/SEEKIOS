import SoulseekKit
import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var soulseek: SoulseekModel
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var router: AppRouter
    @State private var collapsed = Set<String>()
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<DownloadID>()
    @State private var confirmDeleteFiles = false
    @State private var showSavedFolderSheet = false

    private var isSelecting: Bool { editMode.isEditing }

    private struct UserGroup: Identifiable {
        let username: String
        let items: [DownloadItem]
        var id: String { username }

        var active: Int { items.filter(\.isActive).count }
        var failed: Int { items.filter { if case .failed = $0.state { return true } else { return false } }.count }
        var done: Int { items.filter { if case .completed = $0.state { return true } else { return false } }.count }
        var progress: Double {
            let size = items.reduce(UInt64(0)) { $0 + $1.size }
            let received = items.reduce(UInt64(0)) { total, item in
                if case .completed = item.state { return total + item.size }
                return total + item.received
            }
            return size > 0 ? min(1, Double(received) / Double(size)) : 0
        }
    }

    private var groups: [UserGroup] {
        var order: [String] = []
        var byUser: [String: [DownloadItem]] = [:]
        for item in soulseek.visibleDownloads {
            if byUser[item.id.username] == nil { order.append(item.id.username) }
            byUser[item.id.username, default: []].append(item)
        }
        let groups = order.map { UserGroup(username: $0, items: byUser[$0] ?? []) }
        return groups.sorted { ($0.active > 0 ? 0 : 1) < ($1.active > 0 ? 0 : 1) }
    }

    private var selectedItems: [DownloadItem] {
        soulseek.visibleDownloads.filter { selection.contains($0.id) }
    }

    private var selectedCompletedURLs: [URL] {
        selectedItems.compactMap { item in
            if case let .completed(url) = item.state { return url }
            return nil
        }
    }

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                if !soulseek.isLoggedIn {
                    Section { ConnectionBanner() }
                }

                // Botón fijo en la parte superior para abrir la carpeta donde se guardan las descargas
                Section {
                    Button {
                        showSavedFolderSheet = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill")
                                .font(.title2)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Open Downloaded Files Folder")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("View storage path & manage all saved files on iPhone")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                }

                ForEach(groups) { group in
                    Section {
                        if !collapsed.contains(group.username) {
                            ForEach(group.items) { item in
                                DownloadRow(item: item)
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            soulseek.cancel(item)
                                        } label: {
                                            Label(item.isActive ? "Cancel" : "Remove", systemImage: "xmark")
                                        }
                                        if case .failed = item.state {
                                            Button {
                                                soulseek.retry(item)
                                            } label: {
                                                Label("Retry", systemImage: "arrow.clockwise")
                                            }
                                            .tint(.blue)
                                        }
                                    }
                                    .contextMenu {
                                        if case let .completed(url) = item.state {
                                            ShareLink(item: url) {
                                                Label("Share / Save to Files…", systemImage: "square.and.arrow.up")
                                            }
                                            ShareLink(item: url.deletingLastPathComponent()) {
                                                Label("Export Containing Folder…", systemImage: "folder")
                                            }
                                        }
                                        if case .failed = item.state {
                                            Button {
                                                soulseek.retry(item)
                                            } label: {
                                                Label("Retry", systemImage: "arrow.clockwise")
                                            }
                                        }
                                        Button(role: .destructive) {
                                            soulseek.cancel(item)
                                        } label: {
                                            Label(item.isActive ? "Cancel Download" : "Remove from List", systemImage: "xmark")
                                        }
                                    }
                            }
                        }
                    } header: {
                        groupHeader(group)
                    }
                }

                if !soulseek.uploads.isEmpty {
                    Section {
                        if !collapsed.contains(uploadsKey) {
                            ForEach(soulseek.uploads) { item in
                                UploadRow(item: item).selectionDisabled()
                            }
                        }
                    } header: {
                        collapsibleHeader(key: uploadsKey) {
                            Label("Uploads", systemImage: "arrow.up.circle")
                            Spacer()
                            Text(soulseek.activeUploadCount > 0 ? "\(soulseek.activeUploadCount) active" : "\(soulseek.uploads.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle(isSelecting ? (selection.isEmpty ? "Select Items" : "\(selection.count) Selected") : "Downloads")
            .navigationBarTitleDisplayMode(isSelecting ? .inline : .large)
            .animation(.default, value: collapsed)
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) {
                if isSelecting { selectionBar }
            }
            .sheet(isPresented: $showSavedFolderSheet) {
                SavedDownloadsFolderView(
                    otherDownloadsURL: soulseek.otherDownloadsDirectory,
                    musicLibraryURL: library.root
                )
            }
            .onChange(of: soulseek.downloads.map(\.id)) { _, ids in
                selection.formIntersection(ids)
            }
            .confirmationDialog(deleteTitle, isPresented: $confirmDeleteFiles, titleVisibility: .visible) {
                Button("Delete Files", role: .destructive) { deleteSelectedFiles() }
            } message: {
                Text("Finished files are permanently removed from this iPhone. Unfinished downloads are cancelled.")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if isSelecting {
                let all = Set(soulseek.visibleDownloads.map(\.id))
                Button(selection == all && !all.isEmpty ? "Deselect All" : "Select All") {
                    if selection == all {
                        selection.removeAll()
                    } else {
                        selection = all
                        collapsed.removeAll()
                    }
                }
            } else {
                Button(collapsed.isEmpty ? "Collapse All" : "Expand All") {
                    collapsed = collapsed.isEmpty ? Set(groups.map(\.username) + [uploadsKey]) : []
                }
                .disabled(groups.isEmpty && soulseek.uploads.isEmpty)
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !isSelecting {
                Button {
                    showSavedFolderSheet = true
                } label: {
                    Image(systemName: "folder.badge.gearshape")
                }

                Menu {
                    Button { showSavedFolderSheet = true } label: { Label("Show Downloads Folder", systemImage: "folder") }
                    Divider()
                    Button { soulseek.retryAllFailed() } label: { Label("Retry All Failed", systemImage: "arrow.clockwise") }
                    Button { soulseek.clearCompleted() } label: { Label("Clear Completed", systemImage: "checkmark.circle") }
                    Button { soulseek.clearFailed() } label: { Label("Clear Failed", systemImage: "exclamationmark.circle") }
                    Button { soulseek.clearFinished() } label: { Label("Clear All Finished", systemImage: "trash.slash") }
                    Divider()
                    Button(role: .destructive) { soulseek.cancelAllActive() } label: {
                        Label("Cancel All Downloads", systemImage: "xmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            Button(isSelecting ? "Done" : "Select") {
                withAnimation {
                    editMode = isSelecting ? .inactive : .active
                    selection.removeAll()
                }
            }
            .disabled(!isSelecting && soulseek.visibleDownloads.isEmpty)
        }
    }

    private var selectionBar: some View {
        let items = selectedItems
        let failed = items.filter { if case .failed = $0.state { return true } else { return false } }.count
        let finishedSongs = soulseek.libraryTracks(for: selection)
        let urls = selectedCompletedURLs
        return HStack {
            Button {
                soulseek.retry(selection)
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .disabled(failed == 0)
            Spacer()
            if !urls.isEmpty {
                ShareLink(items: urls) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Spacer()
            }
            Menu {
                Button { player.playNext(finishedSongs) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                Button { player.addToQueue(finishedSongs) } label: { Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") }
                Button { router.addToPlaylist(finishedSongs) } label: { Label("Add to Playlist…", systemImage: "text.badge.plus") }
            } label: {
                Label("Songs", systemImage: "music.note.list")
            }
            .disabled(finishedSongs.isEmpty)
            Spacer()
            Button {
                soulseek.remove(selection)
                selection.removeAll()
            } label: {
                Label(items.contains(where: \.isActive) ? "Cancel" : "Clear", systemImage: "xmark.circle")
            }
            .disabled(items.isEmpty)
            Spacer()
            Button(role: .destructive) {
                confirmDeleteFiles = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(items.isEmpty)
        }
        .labelStyle(.titleAndIcon)
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var deleteTitle: String {
        let completedCount = selectedCompletedURLs.count
        return completedCount == 0 ? "Remove \(selection.count) item\(selection.count == 1 ? "" : "s")?"
            : "Delete \(completedCount) downloaded file\(completedCount == 1 ? "" : "s")?"
    }

    private func deleteSelectedFiles() {
        let tracks = soulseek.libraryTracks(for: selection)
        let trackURLs = Set(tracks.map { $0.url.standardizedFileURL })
        if !tracks.isEmpty {
            player.remove(tracks)
            favorites.forget(tracks)
            playlists.forget(tracks)
            library.delete(tracks)
        }
        for url in selectedCompletedURLs where !trackURLs.contains(url.standardizedFileURL) {
            try? FileManager.default.removeItem(at: url)
        }
        soulseek.remove(selection)
        selection.removeAll()
        withAnimation { editMode = .inactive }
    }

    private let uploadsKey = "\u{0}uploads"

    private func groupHeader(_ group: UserGroup) -> some View {
        collapsibleHeader(key: group.username) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(group.username, systemImage: "person.fill")
                        .textCase(nil)
                        .lineLimit(1)
                    Spacer()
                    Text(summary(group)).foregroundStyle(.secondary)
                }
                if group.active > 0 {
                    ProgressView(value: group.progress)
                }
            }
        }
        .contextMenu {
            Button {
                withAnimation { editMode = .active }
                selection.formUnion(group.items.map(\.id))
                collapsed.remove(group.username)
            } label: {
                Label("Select All from \(group.username)", systemImage: "checkmark.circle")
            }
            if group.failed > 0 {
                Button { soulseek.retryFailed(from: group.username) } label: {
                    Label("Retry Failed", systemImage: "arrow.clockwise")
                }
            }
            Button(role: .destructive) { soulseek.cancelAll(from: group.username) } label: {
                Label("Cancel and Remove All", systemImage: "xmark")
            }
        }
    }

    private func summary(_ group: UserGroup) -> String {
        var parts: [String] = []
        if group.active > 0 { parts.append("\(group.active) active") }
        if group.done > 0 { parts.append("\(group.done) done") }
        if group.failed > 0 { parts.append("\(group.failed) failed") }
        return parts.joined(separator: " · ")
    }

    private func collapsibleHeader<Content: View>(key: String, @ViewBuilder content: () -> Content) -> some View {
        Button {
            if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .rotationEffect(.degrees(collapsed.contains(key) ? 0 : 90))
                content()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
    }
}

/// Visor interactivo que muestra la carpeta exacta donde Seekios guarda las descargas y lista todos los archivos en disco
struct SavedDownloadsFolderView: View {
    let otherDownloadsURL: URL
    let musicLibraryURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = 0
    @State private var files: [URL] = []
    @State private var copiedPath = false

    private var activeRootURL: URL {
        selectedTab == 0 ? otherDownloadsURL : musicLibraryURL
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Folder", selection: $selectedTab) {
                        Text("General Downloads").tag(0)
                        Text("Music Library").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                Section("Storage Location on iPhone") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(selectedTab == 0 ? "Documents / Downloads" : "Documents / Music")
                            .font(.headline)
                        Text(activeRootURL.path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)

                    Button {
                        UIPasteboard.general.string = activeRootURL.path
                        copiedPath = true
                    } label: {
                        Label(copiedPath ? "Path Copied to Clipboard!" : "Copy Exact Folder Path",
                              systemImage: copiedPath ? "checkmark.circle.fill" : "doc.on.doc")
                    }

                    ShareLink(item: activeRootURL) {
                        Label("Export / Save Folder to iOS Files App…", systemImage: "folder.badge.plus")
                    }
                }

                Section("Saved Files in This Folder (\(files.count))") {
                    if files.isEmpty {
                        Text("No files saved in this folder yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(files, id: \.path) { fileURL in
                            HStack(spacing: 12) {
                                Image(systemName: icon(for: fileURL))
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(fileURL.lastPathComponent)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(2)
                                    Text(fileDetails(for: fileURL))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                ShareLink(item: fileURL) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.body)
                                }
                                .buttonStyle(.borderless)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    try? FileManager.default.removeItem(at: fileURL)
                                    reloadFiles()
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Downloads Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        reloadFiles()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { reloadFiles() }
            .onChange(of: selectedTab) { _, _ in
                copiedPath = false
                reloadFiles()
            }
        }
    }

    private func reloadFiles() {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: activeRootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            files = []
            return
        }
        var found: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                found.append(url)
            }
        }
        files = found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func fileDetails(for url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let parent = url.deletingLastPathComponent().lastPathComponent
        return "\(parent) · \(Formatting.bytes(UInt64(max(0, size))))"
    }

    private func icon(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ResultFilters.audioSet.contains(ext) { return "music.note" }
        if ResultFilters.videoSet.contains(ext) { return "film" }
        if ResultFilters.archiveSet.contains(ext) { return "doc.zipper" }
        if ResultFilters.documentSet.contains(ext) { return "book.fill" }
        if ResultFilters.imageSet.contains(ext) { return "photo" }
        return "doc.fill"
    }
}

struct UploadRow: View {
    let item: UploadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.filename).lineLimit(1)
            if item.state == .transferring {
                ProgressView(value: item.progress)
            }
            HStack {
                Text(status)
                Spacer()
                Text("to \(item.id.username)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var status: String {
        switch item.state {
        case .queued: return "Queued"
        case .transferring: return "\(Formatting.bytes(item.sent)) of \(Formatting.bytes(item.size))"
        case .completed: return "Sent"
        case .failed: return "Stopped"
        }
    }
}

struct DownloadRow: View {
    let item: DownloadItem
    @EnvironmentObject private var library: LibraryStore

    private var artwork: ArtworkSource {
        if case let .completed(url) = item.state, let track = library.track(at: url) {
            return library.artwork(for: track)
        }
        return .remote(CoverLookup.query(forFolderPath: item.folderPath))
    }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(source: artwork, size: 46, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.filename)
                    .lineLimit(2)
                if item.state == .transferring {
                    ProgressView(value: item.progress)
                }
                HStack {
                    Text(status)
                    Spacer()
                    Text(item.id.username)
                }
                .font(.caption)
                .foregroundStyle(statusColor)
            }
            if case let .completed(url) = item.state {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body)
                        .foregroundStyle(.tint)
                        .padding(.leading, 4)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    private var status: String {
        let ext = SharedFile(path: item.id.path, size: item.size).fileExtension.uppercased()
        let prefix = ext.isEmpty ? "" : "\(ext) · "
        switch item.state {
        case .requesting:
            return prefix + "Contacting peer…"
        case let .queued(place):
            return prefix + (place.map { "Queued (#\($0))" } ?? "Queued")
        case .starting:
            return prefix + "Starting…"
        case .transferring:
            return prefix + "\(Formatting.bytes(item.received)) of \(Formatting.bytes(item.size))"
        case .completed:
            return prefix + "Done · \(Formatting.bytes(item.size))"
        case let .failed(reason):
            return prefix + reason
        }
    }

    private var statusColor: Color {
        switch item.state {
        case .completed: return .green
        case .failed: return .red
        default: return .secondary
        }
    }
}
