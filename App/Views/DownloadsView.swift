import QuickLook
import SoulseekKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LocalFolderItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

private enum TransferGroupMode: String, CaseIterable, Identifiable {
    case folder = "folder"
    case user = "user"
    case flat = "flat"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .folder: return "Group by Folder"
        case .user: return "Group by User"
        case .flat: return "Ungrouped (Flat)"
        }
    }

    var shortLabel: String {
        switch self {
        case .folder: return "Folder"
        case .user: return "User"
        case .flat: return "Flat"
        }
    }
}

private enum TransferSortMode: String, CaseIterable, Identifiable {
    case newest = "newest"
    case status = "status"
    case speed = "speed"
    case progress = "progress"
    case size = "size"
    case filename = "filename"
    case user = "user"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .newest: return "Order Added"
        case .status: return "Status"
        case .speed: return "Speed"
        case .progress: return "Progress"
        case .size: return "File Size"
        case .filename: return "Filename"
        case .user: return "Username"
        }
    }
}

private enum TransferFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case downloading = "Downloading"
    case queued = "Queued"
    case paused = "Paused"
    case failed = "Failed"
    case finished = "Finished"

    var id: String { rawValue }
}

private struct TransferGroup: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let username: String
    let folderPath: String
    let isUserGroup: Bool
    let items: [DownloadItem]

    var totalBytes: UInt64 { items.reduce(0) { $0 + $1.size } }
    var receivedBytes: UInt64 {
        items.reduce(0) { acc, item in
            acc + (item.isCompleted ? item.size : min(item.received, item.size))
        }
    }
    var progress: Double {
        totalBytes > 0 ? min(max(Double(receivedBytes) / Double(totalBytes), 0), 1) : 0
    }
    var speed: Double {
        items.reduce(0) { acc, item in
            acc + (item.state == .transferring ? item.bytesPerSecond : 0)
        }
    }
    var completedCount: Int { items.filter(\.isCompleted).count }
    var activeCount: Int { items.filter(\.isActive).count }
    var pausedCount: Int { items.filter(\.isPaused).count }
    var failedCount: Int { items.filter(\.isFailed).count }
    var remainingBytes: UInt64 { items.filter(\.isActive).reduce(0) { $0 + $1.remainingBytes } }
    var etaText: String? { Formatting.eta(remainingBytes: remainingBytes, bytesPerSecond: speed) }
}

struct DownloadsView: View {
    @EnvironmentObject private var soulseek: SoulseekModel
    @EnvironmentObject private var transfers: TransfersStore
    @EnvironmentObject private var router: AppRouter

    @AppStorage("downloads.groupMode") private var groupModeRaw = TransferGroupMode.folder.rawValue
    @AppStorage("downloads.sortMode") private var sortModeRaw = TransferSortMode.newest.rawValue

    @State private var selection = Set<DownloadID>()
    @State private var editMode: EditMode = .inactive
    @State private var collapsedGroups = Set<String>()
    @State private var previewItem: QuickLookPreviewItem?
    @State private var videoItem: VideoPlaybackItem?
    @State private var folderToBrowse: LocalFolderItem?
    @State private var browsePeerTarget: BrowseTarget?
    @State private var filter: TransferFilter = .all
    @State private var searchText = ""

    private var groupMode: TransferGroupMode {
        TransferGroupMode(rawValue: groupModeRaw) ?? .folder
    }

    private var sortMode: TransferSortMode {
        TransferSortMode(rawValue: sortModeRaw) ?? .newest
    }

    var body: some View {
        let allDownloads = transfers.downloads
        let downloadingCount = allDownloads.filter { $0.state == .transferring || $0.state == .starting }.count
        let queuedCount = allDownloads.filter {
            switch $0.state {
            case .requesting, .queued: return true
            default: return false
            }
        }.count
        let activeList = allDownloads.filter(\.isActive)
        let pausedList = allDownloads.filter(\.isPaused)
        let failedList = allDownloads.filter(\.isFailed)
        let completedList = allDownloads.filter(\.isCompleted)
        let filteredDownloads = sortItems(applyFilter(allDownloads))
        let groups = buildGroups(filteredDownloads)
        let totalRemainingBytes = activeList.reduce(UInt64(0)) { $0 + $1.remainingBytes }
        let globalETA = Formatting.eta(remainingBytes: totalRemainingBytes, bytesPerSecond: transfers.totalDownloadSpeed)
        let resumableSelectedCount = allDownloads.filter { selection.contains($0.id) && ($0.isFailed || $0.isPaused) }.count

        NavigationStack {
            List(selection: $selection) {
                // 1. Compact Nicotine+ Status + Default Download Folder Strip
                Section {
                    statusAndDestinationHeader(
                        activeCount: activeList.count,
                        downloadingCount: downloadingCount,
                        queuedCount: queuedCount,
                        pausedCount: pausedList.count,
                        failedCount: failedList.count,
                        remainingBytes: totalRemainingBytes,
                        globalETA: globalETA
                    )
                }

                // 2. Horizontal Nicotine+ Status Filter Chips
                if !allDownloads.isEmpty {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(TransferFilter.allCases) { option in
                                    let count = countFor(
                                        option,
                                        total: allDownloads.count,
                                        downloading: downloadingCount,
                                        queued: queuedCount,
                                        paused: pausedList.count,
                                        failed: failedList.count,
                                        finished: completedList.count
                                    )
                                    filterChip(option, count: count)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                        .listRowBackground(Color.clear)
                    }
                }

                // 3. Uploads Section (only when active or present — hidden when sharing is off)
                if !transfers.uploads.isEmpty {
                    Section {
                        ForEach(transfers.uploads) { upload in
                            UploadRow(upload: upload)
                        }
                    } header: {
                        HStack {
                            Label("Uploads (\(transfers.uploads.count))", systemImage: "arrow.up.circle")
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

                // 4. Downloads Tree / List (Nicotine+ Folder / User / Flat)
                if filteredDownloads.isEmpty {
                    Section {
                        EmptyStateView(
                            title: allDownloads.isEmpty ? "No Downloads Yet" : "No Matching Transfers",
                            message: allDownloads.isEmpty
                                ? "Search for music or files to queue downloads. Interrupted or paused files keep their partial data so you can resume anytime."
                                : "Try another status filter or clear your search query.",
                            systemImage: "arrow.down.circle"
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .listRowBackground(Color.clear)
                    }
                } else if groupMode == .flat {
                    Section {
                        ForEach(filteredDownloads) { item in
                            downloadRowView(item, showPeer: true)
                        }
                    } header: {
                        HStack {
                            Text("All Files (\(filteredDownloads.count))")
                            Spacer()
                            Text(sortMode.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ForEach(groups) { group in
                        let isCollapsed = collapsedGroups.contains(group.id)
                        Section {
                            groupSummaryRow(group, isCollapsed: isCollapsed)
                            if !isCollapsed {
                                ForEach(group.items) { item in
                                    downloadRowView(item, showPeer: false)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Downloads")
            .searchable(text: $searchText, prompt: "Filter filename, folder, or user")
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
                        Picker("Group By", selection: $groupModeRaw) {
                            ForEach(TransferGroupMode.allCases) { mode in
                                Text(mode.label).tag(mode.rawValue)
                            }
                        }

                        Picker("Sort By", selection: $sortModeRaw) {
                            ForEach(TransferSortMode.allCases) { mode in
                                Text(mode.label).tag(mode.rawValue)
                            }
                        }

                        if groupMode != .flat && !groups.isEmpty {
                            Divider()
                            Button {
                                collapsedGroups.removeAll()
                            } label: {
                                Label("Expand All Groups", systemImage: "chevron.down.circle")
                            }
                            Button {
                                collapsedGroups = Set(groups.map(\.id))
                            } label: {
                                Label("Collapse All Groups", systemImage: "chevron.right.circle")
                            }
                        }

                        Divider()

                        Button {
                            folderToBrowse = LocalFolderItem(url: soulseek.otherDownloadsDirectory)
                        } label: {
                            Label("Browse Downloaded Files", systemImage: "folder")
                        }

                        Divider()

                        if !activeList.isEmpty {
                            Button {
                                soulseek.pauseAllActive()
                            } label: {
                                Label("Pause All Active", systemImage: "pause.circle")
                            }
                        }
                        if !failedList.isEmpty {
                            Button {
                                soulseek.retryOnlyFailed()
                            } label: {
                                Label("Retry Failed (\(failedList.count))", systemImage: "arrow.clockwise")
                            }
                        }
                        if !pausedList.isEmpty || !failedList.isEmpty {
                            Button {
                                soulseek.retryAllFailed()
                            } label: {
                                Label("Resume All Paused & Failed", systemImage: "play.circle")
                            }
                        }
                        if !completedList.isEmpty {
                            Button {
                                soulseek.clearCompleted()
                            } label: {
                                Label("Clear Finished (\(completedList.count))", systemImage: "checkmark.circle")
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
                                Label("Abort All Active", systemImage: "stop.circle")
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
            .fullScreenCover(item: $videoItem) { item in
                VideoPlayerSheet(url: item.url)
            }
            .fullScreenCover(item: $previewItem) { item in
                QuickLookPreview(url: item.url)
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: - Nicotine+ Header & Filter Chips

    @ViewBuilder
    private func statusAndDestinationHeader(
        activeCount: Int,
        downloadingCount: Int,
        queuedCount: Int,
        pausedCount: Int,
        failedCount: Int,
        remainingBytes: UInt64,
        globalETA: String?
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    Label(
                        transfers.totalDownloadSpeed > 0 ? Formatting.speed(transfers.totalDownloadSpeed) : "0 KB/s",
                        systemImage: "arrow.down.circle.fill"
                    )
                    .foregroundStyle(transfers.totalDownloadSpeed > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))

                    if transfers.activeUploadCount > 0 || transfers.totalUploadSpeed > 0 {
                        Label(
                            transfers.totalUploadSpeed > 0 ? Formatting.speed(transfers.totalUploadSpeed) : "0 KB/s",
                            systemImage: "arrow.up.circle.fill"
                        )
                        .foregroundStyle(.green)
                    }
                }
                .font(.subheadline.weight(.semibold).monospacedDigit())

                HStack(spacing: 5) {
                    if downloadingCount > 0 {
                        Text("\(downloadingCount) downloading")
                    }
                    if queuedCount > 0 {
                        Text(downloadingCount > 0 ? "· \(queuedCount) queued" : "\(queuedCount) queued")
                    }
                    if activeCount == 0 {
                        if pausedCount > 0 || failedCount > 0 {
                            Text("\(pausedCount) paused · \(failedCount) failed")
                        } else {
                            Text("Idle")
                        }
                    }
                    if let globalETA {
                        Text("· ETA \(globalETA)")
                    }
                    if remainingBytes > 0 {
                        Text("· \(Formatting.bytes(remainingBytes)) left")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            if activeCount > 0 {
                Button {
                    soulseek.pauseAllActive()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if pausedCount + failedCount > 0 {
                Button {
                    soulseek.retryAllFailed()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private func filterChip(_ option: TransferFilter, count: Int) -> some View {
        let selected = filter == option
        return Button {
            filter = option
        } label: {
            HStack(spacing: 4) {
                Text(option.rawValue)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(selected ? Color.white.opacity(0.25) : Color.secondary.opacity(0.18), in: Capsule())
                }
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)), in: Capsule())
            .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Nicotine+ Collapsible Group Row & File Row

    private func groupSummaryRow(_ group: TransferGroup, isCollapsed: Bool) -> some View {
        let groupIDs = Set(group.items.map(\.id))
        let peerStatus = soulseek.userStatuses[group.username.lowercased()]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if isCollapsed {
                            collapsedGroups.remove(group.id)
                        } else {
                            collapsedGroups.insert(group.id)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)

                        Image(systemName: group.isUserGroup ? "person.crop.circle.fill" : "folder.fill")
                            .font(.title3)
                            .foregroundStyle(.tint)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            HStack(spacing: 5) {
                                if let status = peerStatus {
                                    Circle()
                                        .fill(statusColor(status))
                                        .frame(width: 6, height: 6)
                                }
                                Text(group.subtitle)
                                Text("·")
                                Text("\(group.completedCount)/\(group.items.count)")
                                    .monospacedDigit()
                                if group.speed > 0 {
                                    Text("· \(Formatting.speed(group.speed))")
                                        .foregroundStyle(.tint)
                                        .monospacedDigit()
                                }
                                if let eta = group.etaText {
                                    Text("· \(eta)")
                                        .monospacedDigit()
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 4)

                Menu {
                    if group.activeCount > 0 {
                        Button {
                            soulseek.pause(groupIDs)
                        } label: {
                            Label("Pause Group", systemImage: "pause.circle")
                        }
                    }
                    if group.pausedCount > 0 || group.failedCount > 0 {
                        Button {
                            soulseek.retry(groupIDs)
                        } label: {
                            Label("Resume / Retry Group", systemImage: "play.circle")
                        }
                    }
                    Button {
                        folderToBrowse = LocalFolderItem(url: localContainerFolder(for: group))
                    } label: {
                        Label("Open Local Folder", systemImage: "folder")
                    }
                    Button {
                        browsePeerTarget = BrowseTarget(username: group.username, folder: group.isUserGroup ? "" : group.folderPath)
                    } label: {
                        Label("Browse \(group.username)", systemImage: "folder.badge.person.crop")
                    }
                    if group.completedCount > 0 {
                        Button {
                            soulseek.clearCompleted(in: groupIDs)
                        } label: {
                            Label("Clear Finished in Group", systemImage: "checkmark.circle")
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        soulseek.remove(groupIDs, deletePartial: true)
                    } label: {
                        Label("Remove Group & Partials", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }

            if group.totalBytes > 0 {
                HStack(spacing: 8) {
                    ProgressView(value: group.progress)
                        .tint(groupTint(group))
                    Text("\(Formatting.bytes(group.receivedBytes)) / \(Formatting.bytes(group.totalBytes))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func downloadRowView(_ item: DownloadItem, showPeer: Bool) -> some View {
        DownloadRow(
            item: item,
            showPeer: showPeer,
            onPlayVideo: { url in videoItem = VideoPlaybackItem(url: url) },
            onPreview: { url in previewItem = QuickLookPreviewItem(url: url) },
            onShowFolder: { folderURL in folderToBrowse = LocalFolderItem(url: folderURL) },
            onBrowsePeer: { target in browsePeerTarget = target }
        )
        .tag(item.id)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if item.isActive {
                Button {
                    soulseek.pause(item)
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .tint(.orange)
            } else if item.isPaused || item.isFailed {
                Button {
                    soulseek.retry(item)
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .tint(.green)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                soulseek.cancel(item, deletePartial: true)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    // MARK: - Filtering, Sorting & Grouping

    private func countFor(
        _ option: TransferFilter,
        total: Int,
        downloading: Int,
        queued: Int,
        paused: Int,
        failed: Int,
        finished: Int
    ) -> Int {
        switch option {
        case .all: return total
        case .downloading: return downloading
        case .queued: return queued
        case .paused: return paused
        case .failed: return failed
        case .finished: return finished
        }
    }

    private func applyFilter(_ items: [DownloadItem]) -> [DownloadItem] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return items.filter { item in
            switch filter {
            case .all:
                break
            case .downloading:
                if item.state != .transferring && item.state != .starting { return false }
            case .queued:
                switch item.state {
                case .requesting, .queued: break
                default: return false
                }
            case .paused:
                if !item.isPaused { return false }
            case .failed:
                if !item.isFailed { return false }
            case .finished:
                if !item.isCompleted { return false }
            }
            if !trimmed.isEmpty {
                return item.filename.lowercased().contains(trimmed)
                    || item.leafFolder.lowercased().contains(trimmed)
                    || item.id.username.lowercased().contains(trimmed)
            }
            return true
        }
    }

    private func statusRank(_ state: DownloadState) -> Int {
        switch state {
        case .transferring: return 0
        case .starting: return 1
        case .queued: return 2
        case .requesting: return 3
        case .paused: return 4
        case .failed: return 5
        case .completed: return 6
        }
    }

    private func sortItems(_ items: [DownloadItem]) -> [DownloadItem] {
        switch sortMode {
        case .newest:
            return items
        case .status:
            return items.sorted {
                let lhs = statusRank($0.state), rhs = statusRank($1.state)
                if lhs != rhs { return lhs < rhs }
                return $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
            }
        case .speed:
            return items.sorted {
                if $0.bytesPerSecond != $1.bytesPerSecond { return $0.bytesPerSecond > $1.bytesPerSecond }
                return $0.progress > $1.progress
            }
        case .progress:
            return items.sorted { $0.progress > $1.progress }
        case .size:
            return items.sorted { $0.size > $1.size }
        case .filename:
            return items.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        case .user:
            return items.sorted {
                let cmp = $0.id.username.localizedCaseInsensitiveCompare($1.id.username)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
            }
        }
    }

    private func buildGroups(_ items: [DownloadItem]) -> [TransferGroup] {
        var bucket: [String: (title: String, subtitle: String, username: String, folderPath: String, isUser: Bool, items: [DownloadItem])] = [:]
        var order: [String] = []
        for item in items {
            let key: String
            let title: String
            let subtitle: String
            let isUser: Bool
            switch groupMode {
            case .folder:
                key = "\(item.id.username)|\(item.folderPath)"
                title = item.leafFolder
                subtitle = item.id.username
                isUser = false
            case .user:
                key = "user|\(item.id.username.lowercased())"
                title = item.id.username
                subtitle = "Peer"
                isUser = true
            case .flat:
                key = "flat"
                title = "All Files"
                subtitle = ""
                isUser = false
            }
            if bucket[key] == nil {
                order.append(key)
                bucket[key] = (title: title, subtitle: subtitle, username: item.id.username, folderPath: item.folderPath, isUser: isUser, items: [])
            }
            bucket[key]?.items.append(item)
        }
        return order.compactMap { key in
            guard let g = bucket[key] else { return nil }
            return TransferGroup(
                id: key,
                title: g.title,
                subtitle: g.subtitle,
                username: g.username,
                folderPath: g.folderPath,
                isUserGroup: g.isUser,
                items: g.items
            )
        }
    }

    private func statusColor(_ status: UserStatus) -> Color {
        switch status {
        case .online: return .green
        case .away: return .orange
        case .offline: return .secondary
        }
    }

    private func groupTint(_ group: TransferGroup) -> Color? {
        if group.completedCount == group.items.count { return .green }
        if group.activeCount > 0 { return nil }
        if group.failedCount > 0 || group.pausedCount > 0 { return .orange }
        return .secondary
    }

    private func localContainerFolder(for group: TransferGroup) -> URL {
        for item in group.items {
            if case let .completed(url) = item.state {
                let parent = url.deletingLastPathComponent()
                if FileManager.default.fileExists(atPath: parent.path) {
                    return parent
                }
            }
        }
        let candidate = soulseek.otherDownloadsDirectory.appendingPathComponent(group.title, isDirectory: true)
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
    var showPeer: Bool = false
    let onPlayVideo: (URL) -> Void
    let onPreview: (URL) -> Void
    let onShowFolder: (URL) -> Void
    let onBrowsePeer: (BrowseTarget) -> Void
    @EnvironmentObject private var soulseek: SoulseekModel
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var router: AppRouter

    private var isVideo: Bool { VideoFileSupport.isVideoExtension(item.fileExtension) }
    private var isAudio: Bool { LibraryStore.audioExtensions.contains(item.fileExtension) }

    private func openCompleted(_ url: URL) {
        if isVideo {
            onPlayVideo(url)
            return
        }
        let libTrack = item.libraryURL.flatMap { library.track(at: $0) } ?? library.track(at: url)
        if let track = libTrack {
            player.play([track])
        } else {
            onPreview(url)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: iconForExtension(item.fileExtension))
                    .font(.body)
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.filename)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)

                    statusSubtitle

                    if showPeer {
                        Text("\(item.id.username) · \(item.leafFolder)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                trailingAction
            }

            if item.isActive || (item.received > 0 && item.progress < 1.0) {
                ProgressView(value: item.progress)
                    .tint(item.isActive ? nil : Color.orange)
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            if case let .completed(url) = item.state {
                Button {
                    openCompleted(url)
                } label: {
                    Label(
                        isVideo ? "Play Video" : (isAudio ? "Play Track" : "Preview / Open File"),
                        systemImage: (isVideo || isAudio) ? "play.circle" : "eye"
                    )
                }

                Button {
                    onShowFolder(url.deletingLastPathComponent())
                } label: {
                    Label("Open Container Folder", systemImage: "folder")
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
                onBrowsePeer(BrowseTarget(username: item.id.username, folder: ""))
            } label: {
                Label("Browse All Files from \(item.id.username)", systemImage: "externaldrive.connected.to.line.below")
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

            Button {
                UIPasteboard.general.string = item.filename
            } label: {
                Label("Copy Filename", systemImage: "doc.on.doc")
            }

            Button {
                UIPasteboard.general.string = item.id.username
            } label: {
                Label("Copy Username", systemImage: "person.crop.square")
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
            let placeStr = place.map { "Queued #\($0)" } ?? "Queued"
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
            Text("Paused \(pct)% · \(Formatting.bytes(item.received)) / \(Formatting.bytes(item.size))")
                .font(.caption)
                .foregroundStyle(.orange)
        case let .completed(url):
            Text("Finished · \(Formatting.bytes(item.size)) · \(url.deletingLastPathComponent().lastPathComponent)")
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
                    openCompleted(url)
                } label: {
                    Image(systemName: (isVideo || isAudio) ? "play.circle.fill" : "eye.circle.fill")
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
        if VideoFileSupport.isVideoExtension(ext) { return "film" }
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
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: Player
    @State private var entries: [LocalFileEntry] = []
    @State private var previewItem: QuickLookPreviewItem?
    @State private var videoItem: VideoPlaybackItem?

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
                        Text("On My iPhone › Seekios › \(folderURL.lastPathComponent)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
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
                            let ext = entry.url.pathExtension.lowercased()
                            let isVideo = VideoFileSupport.isVideoExtension(ext)
                            let isAudio = LibraryStore.audioExtensions.contains(ext)
                            HStack {
                                Button {
                                    if isVideo {
                                        videoItem = VideoPlaybackItem(url: entry.url)
                                    } else if isAudio, let track = library.track(at: entry.url) {
                                        player.play([track])
                                    } else {
                                        previewItem = QuickLookPreviewItem(url: entry.url)
                                    }
                                } label: {
                                    HStack {
                                        Image(systemName: isVideo ? "film" : (isAudio ? "music.note" : "doc.fill"))
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
        .fullScreenCover(item: $videoItem) { item in
            VideoPlayerSheet(url: item.url)
        }
        .fullScreenCover(item: $previewItem) { item in
            QuickLookPreview(url: item.url)
                .ignoresSafeArea()
        }
    }

    private func reloadContents() async {
        let target = folderURL
        let loaded = await Task.detached(priority: .userInitiated) { () -> [LocalFileEntry] in
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
