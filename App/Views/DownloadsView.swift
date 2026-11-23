import QuickLook
import SoulseekKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LocalFolderItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

private struct DownloadFolderGroup: Identifiable {
    let id: String
    let folderName: String
    let folderPath: String
    let username: String
    let items: [DownloadItem]
}

private enum TransferFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case active = "Active"
    case paused = "Paused"
    case failed = "Failed"
    case done = "Done"
    var id: String { rawValue }
}

struct DownloadsView: View {
    @EnvironmentObject private var soulseek: SoulseekModel
    @EnvironmentObject private var transfers: TransfersStore
    @EnvironmentObject private var router: AppRouter

    @State private var selection = Set<DownloadID>()
    @State private var editMode: EditMode = .inactive
    @State private var previewItem: QuickLookPreviewItem?
    @State private var folderToBrowse: LocalFolderItem?
    @State private var browsePeerTarget: BrowseTarget?
    @State private var showFolderPicker = false
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var filter: TransferFilter = .all
    @State private var searchText = ""

    var body: some View {
        let allDownloads = transfers.downloads
        let activeList = allDownloads.filter(\.isActive)
        let pausedList = allDownloads.filter(\.isPaused)
        let failedList = allDownloads.filter(\.isFailed)
        let completedList = allDownloads.filter(\.isCompleted)
        let filteredDownloads = applyFilter(allDownloads)
        let grouped = groupByFolder(filteredDownloads)
        let totalRemainingBytes = activeList.reduce(UInt64(0)) { $0 + $1.remainingBytes }
        let globalETA = Formatting.eta(remainingBytes: totalRemainingBytes, bytesPerSecond: transfers.totalDownloadSpeed)
        let resumableSelectedCount = allDownloads.filter { selection.contains($0.id) && ($0.isFailed || $0.isPaused) }.count

        NavigationStack {
            List(selection: $selection) {
                // 1. Live Speed & ETA summary bar (Nicotine+-style)
                if !activeList.isEmpty || transfers.activeUploadCount > 0 {
                    Section {
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 10) {
                                    Label(
                                        transfers.totalDownloadSpeed > 0 ? Formatting.speed(transfers.totalDownloadSpeed) : "0 KB/s",
                                        systemImage: "arrow.down.circle.fill"
                                    )
                                    .foregroundStyle(.tint)
                                    if transfers.activeUploadCount > 0 || transfers.totalUploadSpeed > 0 {
                                        Label(
                                            transfers.totalUploadSpeed > 0 ? Formatting.speed(transfers.totalUploadSpeed) : "0 KB/s",
                                            systemImage: "arrow.up.circle.fill"
                                        )
                                        .foregroundStyle(.green)
                                    }
                                }
                                .font(.subheadline.weight(.semibold).monospacedDigit())

                                HStack(spacing: 6) {
                                    Text("\(activeList.count) active")
                                    if let globalETA {
                                        Text("· ETA \(globalETA)")
                                    }
                                    if totalRemainingBytes > 0 {
                                        Text("· \(Formatting.bytes(totalRemainingBytes)) left")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !activeList.isEmpty {
                                Button {
                                    soulseek.pauseAllActive()
                                } label: {
                                    Label("Pause All", systemImage: "pause.circle")
                                        .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                // 2. Destination controls
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill.badge.gearshape")
                            .font(.title3)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Save Location")
                                .font(.subheadline.weight(.semibold))
                            Text(soulseek.currentDownloadFolderDisplayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Choose") {
                            showFolderPicker = true
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }

                    HStack(spacing: 16) {
                        Button {
                            folderToBrowse = LocalFolderItem(url: soulseek.otherDownloadsDirectory)
                        } label: {
                            Label("Show Downloads Folder", systemImage: "folder.fill")
                                .font(.subheadline)
                        }
                        .buttonStyle(.borderless)

                        Spacer()

                        Button {
                            newFolderName = ""
                            showNewFolderAlert = true
                        } label: {
                            Label("New Folder…", systemImage: "folder.badge.plus")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if soulseek.customDownloadDirectory != nil {
                        Toggle("Also Copy Music to Chosen Folder", isOn: $soulseek.saveAllToCustomFolder)
                        Button("Reset to Default App Folder", role: .destructive) {
                            soulseek.resetDownloadFolderToDefault()
                        }
                        .font(.footnote)
                    }
                } header: {
                    Text("Download Destination")
                }

                // 3. Filter & Quick Actions bar
                if !allDownloads.isEmpty {
                    Section {
                        Picker("Filter", selection: $filter) {
                            ForEach(TransferFilter.allCases) { f in
                                Text(filterLabel(f, total: allDownloads.count, active: activeList.count, paused: pausedList.count, failed: failedList.count, done: completedList.count))
                                    .tag(f)
                            }
                        }
                        .pickerStyle(.segmented)

                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("Filter by filename, folder or peer…", text: $searchText)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            if !searchText.isEmpty {
                                Button { searchText = "" } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if !failedList.isEmpty || !pausedList.isEmpty || !completedList.isEmpty {
                            HStack(spacing: 10) {
                                let resumableCount = failedList.count + pausedList.count
                                if resumableCount > 0 {
                                    Button {
                                        soulseek.retryAllFailed()
                                    } label: {
                                        Label("Resume All (\(resumableCount))", systemImage: "play.circle.fill")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.orange)
                                }

                                if !completedList.isEmpty {
                                    Button {
                                        soulseek.clearCompleted()
                                    } label: {
                                        Label("Clear Done", systemImage: "checkmark.circle")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .buttonStyle(.bordered)
                                }

                                Spacer()
                                Text("\(completedList.count) done")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // 4. Uploads section (with state, speed, abort & clear)
                if !transfers.uploads.isEmpty {
                    Section {
                        ForEach(transfers.uploads) { upload in
                            UploadRow(upload: upload)
                        }
                    } header: {
                        HStack {
                            Text("Uploads (\(transfers.uploads.count))")
                            Spacer()
                            if transfers.uploads.contains(where: { !$0.isActive }) {
                                Button("Clear Finished") {
                                    soulseek.clearFinishedUploads()
                                }
                                .font(.caption.weight(.semibold))
                                .textCase(nil)
                            }
                        }
                    }
                }

                // 5. Grouped Downloads (unique ID per user + full remote folder path)
                if grouped.isEmpty {
                    Section {
                        EmptyStateView(
                            title: allDownloads.isEmpty ? "No Transfers" : "No Matching Transfers",
                            message: allDownloads.isEmpty
                                ? "Files you download from Search appear here. Paused and interrupted transfers keep their partial data on disk for resuming."
                                : "Try switching the transfer filter or clearing your search.",
                            systemImage: "arrow.down.circle"
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .listRowBackground(Color.clear)
                    }
                } else {
                    ForEach(grouped) { group in
                        Section {
                            ForEach(group.items) { item in
                                DownloadRow(
                                    item: item,
                                    onPreview: { url in previewItem = QuickLookPreviewItem(url: url) },
                                    onShowFolder: { folderURL in folderToBrowse = LocalFolderItem(url: folderURL) },
                                    onBrowsePeer: { target in browsePeerTarget = target }
                                )
                                .tag(item.id)
                            }
                        } header: {
                            HStack {
                                Label(group.folderName, systemImage: "folder.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    folderToBrowse = LocalFolderItem(url: localContainerFolder(for: group))
                                } label: {
                                    Label("Folder", systemImage: "folder.badge.magnifyingglass")
                                        .font(.caption.weight(.semibold))
                                }
                                .textCase(nil)
                            }
                        } footer: {
                            HStack {
                                Button {
                                    browsePeerTarget = BrowseTarget(username: group.username, folder: group.folderPath)
                                } label: {
                                    Label("From \(group.username)", systemImage: "person")
                                        .font(.caption2)
                                }
                                .buttonStyle(.plain)

                                Spacer()

                                let hasResumable = group.items.contains { $0.isFailed || $0.isPaused }
                                if hasResumable {
                                    Button("Resume Folder") {
                                        soulseek.retry(Set(group.items.map(\.id)))
                                    }
                                    .font(.caption2.weight(.semibold))
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Downloads")
            .environment(\.editMode, $editMode)
            .onChange(of: allDownloads.isEmpty) { _, isEmpty in
                if isEmpty {
                    editMode = .inactive
                    selection.removeAll()
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !allDownloads.isEmpty {
                        Button(editMode == .active ? "Done" : "Select") {
                            withAnimation {
                                editMode = (editMode == .active) ? .inactive : .active
                                if editMode == .inactive { selection.removeAll() }
                            }
                        }
                    }
                    Menu {
                        Button {
                            folderToBrowse = LocalFolderItem(url: soulseek.otherDownloadsDirectory)
                        } label: {
                            Label("Show Downloads Folder", systemImage: "folder")
                        }
                        Button {
                            showFolderPicker = true
                        } label: {
                            Label("Change Download Location…", systemImage: "folder.badge.gearshape")
                        }
                        Button {
                            newFolderName = ""
                            showNewFolderAlert = true
                        } label: {
                            Label("Create New Download Folder…", systemImage: "folder.badge.plus")
                        }
                        Divider()
                        if !activeList.isEmpty {
                            Button {
                                soulseek.pauseAllActive()
                            } label: {
                                Label("Pause All Active", systemImage: "pause.circle")
                            }
                        }
                        if !failedList.isEmpty || !pausedList.isEmpty {
                            Button {
                                soulseek.retryAllFailed()
                            } label: {
                                Label("Resume All Paused / Failed", systemImage: "arrow.clockwise")
                            }
                        }
                        if !completedList.isEmpty {
                            Button {
                                soulseek.clearCompleted()
                            } label: {
                                Label("Clear Completed", systemImage: "checkmark.circle")
                            }
                        }
                        if !failedList.isEmpty {
                            Button(role: .destructive) {
                                soulseek.clearFailed()
                            } label: {
                                Label("Remove Failed", systemImage: "xmark.circle")
                            }
                        }
                        if !activeList.isEmpty {
                            Button(role: .destructive) {
                                soulseek.cancelAllActive()
                            } label: {
                                Label("Cancel & Delete Active", systemImage: "stop.circle")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }

                if editMode == .active && !selection.isEmpty {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button("Pause") {
                            soulseek.pause(selection)
                            selection.removeAll()
                            editMode = .inactive
                        }
                        Spacer()
                        if resumableSelectedCount > 0 {
                            Button("Resume (\(resumableSelectedCount))") {
                                soulseek.retry(selection)
                                selection.removeAll()
                                editMode = .inactive
                            }
                            Spacer()
                        }
                        Button("Delete (\(selection.count))", role: .destructive) {
                            soulseek.remove(selection, deletePartial: true)
                            selection.removeAll()
                            editMode = .inactive
                        }
                    }
                }
            }
            .sheet(item: $folderToBrowse) { item in
                NavigationStack {
                    LocalFolderBrowserView(folderURL: item.url)
                }
            }
            .sheet(item: $browsePeerTarget) { target in
                NavigationStack {
                    RemoteFolderBrowserView(target: target)
                }
            }
            .sheet(isPresented: $showFolderPicker) {
                FolderDocumentPicker { pickedURL in
                    soulseek.setCustomDownloadFolder(pickedURL)
                }
                .ignoresSafeArea()
            }
            .alert("Create New Download Folder", isPresented: $showNewFolderAlert) {
                TextField("Folder name (e.g. Albums, Archives)", text: $newFolderName)
                Button("Create & Select") {
                    soulseek.createAndSelectSubfolder(named: newFolderName)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Creates a folder inside On My iPhone › Seekios and sets it as your active download folder.")
            }
            .fullScreenCover(item: $previewItem) { item in
                QuickLookPreview(url: item.url)
                    .ignoresSafeArea()
            }
        }
    }

    private func filterLabel(_ filter: TransferFilter, total: Int, active: Int, paused: Int, failed: Int, done: Int) -> String {
        switch filter {
        case .all: return "All"
        case .active: return active > 0 ? "Active (\(active))" : "Active"
        case .paused: return paused > 0 ? "Paused (\(paused))" : "Paused"
        case .failed: return failed > 0 ? "Failed (\(failed))" : "Failed"
        case .done: return done > 0 ? "Done (\(done))" : "Done"
        }
    }

    private func applyFilter(_ items: [DownloadItem]) -> [DownloadItem] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { item in
            switch filter {
            case .all: break
            case .active: if !item.isActive { return false }
            case .paused: if !item.isPaused { return false }
            case .failed: if !item.isFailed { return false }
            case .done: if !item.isCompleted { return false }
            }
            if !trimmed.isEmpty {
                return item.filename.lowercased().contains(trimmed)
                    || item.leafFolder.lowercased().contains(trimmed)
                    || item.id.username.lowercased().contains(trimmed)
            }
            return true
        }
    }

    private func groupByFolder(_ items: [DownloadItem]) -> [DownloadFolderGroup] {
        var groups: [String: (folderName: String, folderPath: String, username: String, items: [DownloadItem])] = [:]
        var order: [String] = []
        for item in items {
            let key = "\(item.id.username)|\(item.folderPath)"
            if groups[key] == nil {
                order.append(key)
                groups[key] = (folderName: item.leafFolder, folderPath: item.folderPath, username: item.id.username, items: [])
            }
            groups[key]?.items.append(item)
        }
        return order.compactMap { key in
            guard let g = groups[key] else { return nil }
            return DownloadFolderGroup(id: key, folderName: g.folderName, folderPath: g.folderPath, username: g.username, items: g.items)
        }
    }

    private func localContainerFolder(for group: DownloadFolderGroup) -> URL {
        for item in group.items {
            if case let .completed(url) = item.state {
                let parent = url.deletingLastPathComponent()
                if FileManager.default.fileExists(atPath: parent.path) {
                    return parent
                }
            }
        }
        let candidate = soulseek.otherDownloadsDirectory.appendingPathComponent(group.folderName, isDirectory: true)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return soulseek.otherDownloadsDirectory
    }
}

private struct UploadRow: View {
    let upload: UploadItem
    @EnvironmentObject private var soulseek: SoulseekModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(upload.filename)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if upload.isActive {
                    Button {
                        soulseek.abortUpload(upload)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack(spacing: 6) {
                Text("To \(upload.id.username)")
                Text("·")
                Text(statusText)
                    .foregroundStyle(statusColor)
                if upload.state == .transferring, upload.bytesPerSecond > 0 {
                    Text("· \(Formatting.speed(upload.bytesPerSecond))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if upload.isActive {
                ProgressView(value: upload.progress)
                    .tint(.green)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if upload.isActive {
                Button(role: .destructive) {
                    soulseek.abortUpload(upload)
                } label: {
                    Label("Abort Upload", systemImage: "stop.circle")
                }
            }
        }
    }

    private var statusText: String {
        switch upload.state {
        case .queued: return "Queued"
        case .transferring: return "\(Formatting.bytes(upload.sent)) / \(Formatting.bytes(upload.size))"
        case .completed: return "Completed · \(Formatting.bytes(upload.size))"
        case .failed: return "Failed / Aborted"
        }
    }

    private var statusColor: Color {
        switch upload.state {
        case .completed: return .green
        case .failed: return .orange
        default: return .secondary
        }
    }
}

struct DownloadRow: View {
    let item: DownloadItem
    let onPreview: (URL) -> Void
    let onShowFolder: (URL) -> Void
    let onBrowsePeer: (BrowseTarget) -> Void
    @EnvironmentObject private var soulseek: SoulseekModel
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: iconForExtension(item.fileExtension))
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.filename)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)

                    statusSubtitle
                }

                Spacer()

                trailingAction
            }

            if item.isActive || (item.received > 0 && item.progress < 1.0) {
                ProgressView(value: item.progress)
                    .tint(item.isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.orange))
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            if case let .completed(url) = item.state {
                Button {
                    onPreview(url)
                } label: {
                    Label("Preview / Open File", systemImage: "eye")
                }

                Button {
                    onShowFolder(url.deletingLastPathComponent())
                } label: {
                    Label("Show Container Folder", systemImage: "folder")
                }

                ShareLink(item: url) {
                    Label("Share / Save to Files…", systemImage: "square.and.arrow.up")
                }
            }

            if item.isActive {
                Button {
                    soulseek.pause(item)
                } label: {
                    Label("Pause (Keep Partial)", systemImage: "pause.circle")
                }
            }

            if item.isFailed || item.isPaused {
                Button {
                    soulseek.retry(item)
                } label: {
                    Label("Resume Download", systemImage: "play.circle")
                }
            }

            Divider()

            Button {
                let query = (item.filename as NSString).deletingPathExtension
                    .replacingOccurrences(of: "_", with: " ")
                router.openSearch(query)
            } label: {
                Label("Search Alternative Sources", systemImage: "magnifyingglass")
            }

            Button {
                onBrowsePeer(BrowseTarget(username: item.id.username, folder: item.folderPath))
            } label: {
                Label("Browse \(item.id.username)'s Folder", systemImage: "folder.badge.person.crop")
            }

            Button {
                soulseek.toggleFavoriteUser(item.id.username)
            } label: {
                Label(
                    soulseek.isFavoriteUser(item.id.username) ? "Remove Favorite User" : "Favorite \(item.id.username)",
                    systemImage: soulseek.isFavoriteUser(item.id.username) ? "star.slash" : "star"
                )
            }

            Button(role: .destructive) {
                soulseek.toggleBlockedUser(item.id.username)
            } label: {
                Label("Block \(item.id.username)", systemImage: "hand.raised")
            }

            Divider()

            Button(role: .destructive) {
                soulseek.cancel(item, deletePartial: true)
            } label: {
                Label("Remove & Delete Partial", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var statusSubtitle: some View {
        switch item.state {
        case .requesting:
            Text("Connecting to \(item.id.username)… · \(Formatting.bytes(item.received)) / \(Formatting.bytes(item.size))")
                .font(.caption)
                .foregroundStyle(.secondary)
        case let .queued(place):
            let placeStr = place.map { "Place #\($0) in queue" } ?? "Queued"
            Text("\(placeStr) · \(Formatting.bytes(item.received)) / \(Formatting.bytes(item.size))")
                .font(.caption)
                .foregroundStyle(.orange)
        case .starting:
            Text("Starting transfer… · \(Formatting.bytes(item.received)) / \(Formatting.bytes(item.size))")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .transferring:
            let pct = Int((item.progress * 100).rounded())
            let speedStr = item.bytesPerSecond > 0 ? " · \(Formatting.speed(item.bytesPerSecond))" : ""
            let etaStr = item.etaText.map { " · \($0)" } ?? ""
            Text("\(pct)%\(speedStr)\(etaStr) · \(Formatting.bytes(item.received)) / \(Formatting.bytes(item.size))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        case .paused:
            let pct = Int((item.progress * 100).rounded())
            Text("Paused at \(pct)% · \(Formatting.bytes(item.received)) / \(Formatting.bytes(item.size))")
                .font(.caption)
                .foregroundStyle(.orange)
        case let .completed(url):
            Text("Completed · \(Formatting.bytes(item.size)) · \(url.deletingLastPathComponent().lastPathComponent)")
                .font(.caption)
                .foregroundStyle(.green)
        case let .failed(reason):
            Text("\(reason) · \(Formatting.bytes(item.received)) / \(Formatting.bytes(item.size))")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var trailingAction: some View {
        switch item.state {
        case let .completed(url):
            HStack(spacing: 8) {
                Button {
                    onShowFolder(url.deletingLastPathComponent())
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)

                Button {
                    let libTrack = item.libraryURL.flatMap { library.track(at: $0) } ?? library.track(at: url)
                    if let track = libTrack {
                        player.play([track])
                    } else {
                        onPreview(url)
                    }
                } label: {
                    Image(systemName: LibraryStore.audioExtensions.contains(item.fileExtension) ? "play.circle.fill" : "eye.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
            }

        case .failed, .paused:
            Button {
                soulseek.retry(item)
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.borderless)

        default:
            Button {
                soulseek.pause(item)
            } label: {
                Image(systemName: "pause.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
    }

    private func iconForExtension(_ ext: String) -> String {
        if LibraryStore.audioExtensions.contains(ext) { return "music.note" }
        if LibraryStore.imageExtensions.contains(ext) { return "photo" }
        if ["mp4", "mkv", "mov", "avi", "webm"].contains(ext) { return "film" }
        if ["zip", "rar", "7z", "tar", "gz"].contains(ext) { return "doc.zipper" }
        if ["pdf", "epub", "txt", "md"].contains(ext) { return "book" }
        return "doc.fill"
    }
}

private struct LocalFileEntry: Identifiable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: UInt64?
    var id: String { url.path }
}

struct LocalFolderBrowserView: View {
    let folderURL: URL
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var soulseek: SoulseekModel
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: Player
    @State private var entries: [LocalFileEntry] = []
    @State private var previewItem: QuickLookPreviewItem?

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folderURL.lastPathComponent)
                            .font(.headline)
                        Text(folderURL.path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Button {
                    soulseek.setCustomDownloadFolder(folderURL)
                } label: {
                    Label("Use This Folder for Future Downloads", systemImage: "checkmark.folder.fill")
                }

                Button {
                    openInSystemFilesApp(folderURL)
                } label: {
                    Label("Open in iOS Files App", systemImage: "arrow.up.forward.app.fill")
                }

                ShareLink(item: folderURL) {
                    Label("Share / Export Entire Folder…", systemImage: "square.and.arrow.up")
                }
            }

            Section("Files in Folder (\(entries.count))") {
                if entries.isEmpty {
                    Text("This folder is empty.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries) { entry in
                        if entry.isDirectory {
                            NavigationLink {
                                LocalFolderBrowserView(folderURL: entry.url)
                            } label: {
                                Label(entry.name, systemImage: "folder.fill")
                            }
                        } else {
                            HStack {
                                Button {
                                    let ext = entry.url.pathExtension.lowercased()
                                    if LibraryStore.audioExtensions.contains(ext), let track = library.track(at: entry.url) {
                                        player.play([track])
                                    } else {
                                        previewItem = QuickLookPreviewItem(url: entry.url)
                                    }
                                } label: {
                                    HStack {
                                        Image(systemName: "doc.fill")
                                            .foregroundStyle(.tint)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.name)
                                                .foregroundStyle(.primary)
                                                .lineLimit(2)
                                            if let size = entry.size {
                                                Text(Formatting.bytes(size))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                                .buttonStyle(.plain)

                                Spacer()

                                ShareLink(item: entry.url) {
                                    Image(systemName: "square.and.arrow.up")
                                }
                                .buttonStyle(.borderless)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    deleteItem(entry.url)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(folderURL.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task(id: folderURL) { await reloadContents() }
        .fullScreenCover(item: $previewItem) { item in
            QuickLookPreview(url: item.url)
                .ignoresSafeArea()
        }
    }

    private func reloadContents() async {
        let target = folderURL
        let loaded = await Task.detached(priority: .userInitiated) { () -> [LocalFileEntry] in
            let scoped = target.startAccessingSecurityScopedResource()
            defer { if scoped { target.stopAccessingSecurityScopedResource() } }
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
            let items = (try? FileManager.default.contentsOfDirectory(
                at: target,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )) ?? []
            return items.map { url in
                let vals = try? url.resourceValues(forKeys: keys)
                let isDir = vals?.isDirectory ?? false
                let size = isDir ? nil : vals?.fileSize.map { UInt64(max(0, $0)) }
                return LocalFileEntry(url: url, name: url.lastPathComponent, isDirectory: isDir, size: size)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }.value
        entries = loaded
    }

    private func deleteItem(_ url: URL) {
        Task {
            await Task.detached(priority: .userInitiated) {
                let scoped = folderURL.startAccessingSecurityScopedResource()
                defer { if scoped { folderURL.stopAccessingSecurityScopedResource() } }
                try? FileManager.default.removeItem(at: url)
            }.value
            await reloadContents()
        }
    }

    private func openInSystemFilesApp(_ url: URL) {
        if let sharedURL = URL(string: "shareddocuments://\(url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path)") {
            UIApplication.shared.open(sharedURL)
        }
    }
}

/// Native iOS folder picker using SwiftUI `@Environment(\.dismiss)` without double-dismiss races.
struct FolderDocumentPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    var onPick: (URL) -> Void

    init(onPick: @escaping (URL) -> Void) {
        self.onPick = onPick
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: FolderDocumentPicker

        init(parent: FolderDocumentPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let first = urls.first {
                DispatchQueue.main.async {
                    self.parent.onPick(first)
                    self.parent.dismiss()
                }
            } else {
                DispatchQueue.main.async { self.parent.dismiss() }
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            DispatchQueue.main.async { self.parent.dismiss() }
        }
    }
}
