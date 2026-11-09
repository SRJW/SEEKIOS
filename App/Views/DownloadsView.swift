import QuickLook
import SoulseekKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LocalFolderItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct DownloadsView: View {
    @EnvironmentObject private var soulseek: SoulseekModel
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var router: AppRouter

    @State private var selection = Set<DownloadID>()
    @State private var editMode: EditMode = .inactive
    @State private var previewURL: URL?
    @State private var folderToBrowse: LocalFolderItem?
    @State private var showFolderPicker = false
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""

    private var activeDownloads: [DownloadItem] {
        soulseek.visibleDownloads.filter(\.isActive)
    }

    private var failedDownloads: [DownloadItem] {
        soulseek.visibleDownloads.filter {
            if case .failed = $0.state { return true }
            return false
        }
    }

    private var completedDownloads: [DownloadItem] {
        soulseek.visibleDownloads.filter {
            if case .completed = $0.state { return true }
            return false
        }
    }

    private var groupedByFolder: [(folderName: String, username: String, items: [DownloadItem])] {
        var groups: [String: (folderName: String, username: String, items: [DownloadItem])] = [:]
        var order: [String] = []
        for item in soulseek.visibleDownloads {
            let folder = item.folderPath.split(separator: "\\").last.map(String.init) ?? item.id.username
            let key = "\(item.id.username)|\(folder)"
            if groups[key] == nil {
                order.append(key)
                groups[key] = (folderName: folder, username: item.id.username, items: [])
            }
            groups[key]?.items.append(item)
        }
        return order.compactMap { groups[$0] }
    }

    private func localContainerFolder(for group: (folderName: String, username: String, items: [DownloadItem])) -> URL {
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

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
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
                        Button("Choose Folder") {
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
                } footer: {
                    Text("Tip: In the iOS folder picker, open any subfolder (or tap the New Folder icon at top-right) and tap Open.")
                }

                if !soulseek.visibleDownloads.isEmpty {
                    Section {
                        HStack(spacing: 12) {
                            if !failedDownloads.isEmpty {
                                Button {
                                    soulseek.retryAllFailed()
                                } label: {
                                    Label("Resume All (\(failedDownloads.count))", systemImage: "arrow.clockwise.circle.fill")
                                        .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.orange)
                            }

                            if !completedDownloads.isEmpty {
                                Button {
                                    soulseek.clearCompleted()
                                } label: {
                                    Label("Clear Done", systemImage: "checkmark.circle")
                                        .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.bordered)
                            }

                            Spacer()
                            Text("\(activeDownloads.count) active · \(completedDownloads.count) done")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }

                if !soulseek.uploads.isEmpty {
                    Section("Uploads (\(soulseek.uploads.count))") {
                        ForEach(soulseek.uploads) { upload in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(upload.filename).lineLimit(1)
                                    Text("To \(upload.id.username) · \(Formatting.bytes(upload.sent)) / \(Formatting.bytes(upload.size))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    ProgressView(value: upload.progress)
                                }
                            }
                        }
                    }
                }

                ForEach(groupedByFolder, id: \.folderName) { group in
                    Section {
                        ForEach(group.items) { item in
                            DownloadRow(
                                item: item,
                                onPreview: { url in previewURL = url },
                                onShowFolder: { folderURL in
                                    folderToBrowse = LocalFolderItem(url: folderURL)
                                }
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
                                let targetFolder = localContainerFolder(for: group)
                                folderToBrowse = LocalFolderItem(url: targetFolder)
                            } label: {
                                Label("Show Folder", systemImage: "folder.badge.magnifyingglass")
                                    .font(.caption.weight(.semibold))
                            }
                            .textCase(nil)
                        }
                    } footer: {
                        HStack {
                            Text("From \(group.username)")
                            Spacer()
                            if group.items.contains(where: { if case .failed = $0.state { return true } else { return false } }) {
                                Button("Resume Folder") {
                                    soulseek.retryFailed(from: group.username)
                                }
                                .font(.caption2.weight(.semibold))
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Downloads")
            .environment(\.editMode, $editMode)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !soulseek.visibleDownloads.isEmpty {
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
                        if !failedDownloads.isEmpty {
                            Button {
                                soulseek.retryAllFailed()
                            } label: {
                                Label("Resume / Retry All Interrupted", systemImage: "arrow.clockwise")
                            }
                        }
                        if !completedDownloads.isEmpty {
                            Button {
                                soulseek.clearCompleted()
                            } label: {
                                Label("Clear Completed", systemImage: "checkmark.circle")
                            }
                        }
                        if !failedDownloads.isEmpty {
                            Button(role: .destructive) {
                                soulseek.clearFailed()
                            } label: {
                                Label("Remove Failed", systemImage: "xmark.circle")
                            }
                        }
                        if !activeDownloads.isEmpty {
                            Button(role: .destructive) {
                                soulseek.cancelAllActive()
                            } label: {
                                Label("Cancel All Active", systemImage: "stop.circle")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }

                if editMode == .active && !selection.isEmpty {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button("Resume (\(selection.count))") {
                            soulseek.retry(selection)
                            selection.removeAll()
                            editMode = .inactive
                        }
                        Spacer()
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
            .sheet(isPresented: $showFolderPicker) {
                FolderDocumentPicker(isPresented: $showFolderPicker) { pickedURL in
                    soulseek.setCustomDownloadFolder(pickedURL)
                }
                .ignoresSafeArea()
            }
            .alert("Create New Download Folder", isPresented: $showNewFolderAlert) {
                TextField("Folder name (e.g. Peliculas, Musica)", text: $newFolderName)
                Button("Create & Select") {
                    soulseek.createAndSelectSubfolder(named: newFolderName)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Creates a folder inside On My iPhone › Seekios and sets it as your active download folder.")
            }
            .fullScreenCover(isPresented: Binding(
                get: { previewURL != nil },
                set: { if !$0 { previewURL = nil } }
            )) {
                if let url = previewURL {
                    QuickLookPreview(url: url)
                        .ignoresSafeArea()
                }
            }
            .overlay {
                if soulseek.visibleDownloads.isEmpty && soulseek.uploads.isEmpty {
                    EmptyStateView(
                        title: "No Transfers",
                        message: "Files you download from Search appear here. Interrupted downloads are saved on disk and resume automatically.",
                        systemImage: "arrow.down.circle"
                    )
                }
            }
        }
    }
}

struct DownloadRow: View {
    let item: DownloadItem
    let onPreview: (URL) -> Void
    let onShowFolder: (URL) -> Void
    @EnvironmentObject private var soulseek: SoulseekModel
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: Player

    private var fileExtension: String {
        (item.filename as NSString).pathExtension.lowercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: iconForExtension(fileExtension))
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
                    .tint(item.isActive ? .accentColor : .orange)
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

            if case .failed = item.state {
                Button {
                    soulseek.retry(item)
                } label: {
                    Label("Resume Download", systemImage: "arrow.clockwise")
                }
            }

            Button(role: .destructive) {
                soulseek.cancel(item)
            } label: {
                Label("Remove Download", systemImage: "trash")
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
            Text("Downloading \(pct)% · \(Formatting.bytes(item.received)) / \(Formatting.bytes(item.size))")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                    if let track = library.track(at: url) {
                        player.play([track])
                    } else {
                        onPreview(url)
                    }
                } label: {
                    Image(systemName: LibraryStore.audioExtensions.contains(fileExtension) ? "play.circle.fill" : "eye.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
            }

        case .failed:
            Button {
                soulseek.retry(item)
            } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.borderless)

        default:
            Button {
                soulseek.cancel(item)
            } label: {
                Image(systemName: "xmark.circle.fill")
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

struct LocalFolderBrowserView: View {
    let folderURL: URL
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var soulseek: SoulseekModel
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: Player
    @State private var contents: [URL] = []
    @State private var previewURL: URL?

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

            Section("Files in Folder (\(contents.count))") {
                if contents.isEmpty {
                    Text("This folder is empty.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(contents, id: \.path) { itemURL in
                        let isDir = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                        if isDir {
                            NavigationLink {
                                LocalFolderBrowserView(folderURL: itemURL)
                            } label: {
                                Label(itemURL.lastPathComponent, systemImage: "folder.fill")
                            }
                        } else {
                            HStack {
                                Button {
                                    let ext = itemURL.pathExtension.lowercased()
                                    if LibraryStore.audioExtensions.contains(ext), let track = library.track(at: itemURL) {
                                        player.play([track])
                                    } else {
                                        previewURL = itemURL
                                    }
                                } label: {
                                    HStack {
                                        Image(systemName: "doc.fill")
                                            .foregroundStyle(.tint)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(itemURL.lastPathComponent)
                                                .foregroundStyle(.primary)
                                                .lineLimit(2)
                                            if let size = (try? FileManager.default.attributesOfItem(atPath: itemURL.path)[.size] as? UInt64) {
                                                Text(Formatting.bytes(size))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                                .buttonStyle(.plain)

                                Spacer()

                                ShareLink(item: itemURL) {
                                    Image(systemName: "square.and.arrow.up")
                                }
                                .buttonStyle(.borderless)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    try? FileManager.default.removeItem(at: itemURL)
                                    reloadContents()
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
        .onAppear { reloadContents() }
        .fullScreenCover(isPresented: Binding(
            get: { previewURL != nil },
            set: { if !$0 { previewURL = nil } }
        )) {
            if let url = previewURL {
                QuickLookPreview(url: url)
                    .ignoresSafeArea()
            }
        }
    }

    private func reloadContents() {
        _ = folderURL.startAccessingSecurityScopedResource()
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        contents = items.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func openInSystemFilesApp(_ url: URL) {
        if let sharedURL = URL(string: "shareddocuments://\(url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path)") {
            UIApplication.shared.open(sharedURL)
        }
    }
}

/// Selector nativo de carpetas de iOS con cierre automático al pulsar "Open"
struct FolderDocumentPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var onPick: (URL) -> Void

    init(isPresented: Binding<Bool> = .constant(true), onPick: @escaping (URL) -> Void) {
        self._isPresented = isPresented
        self.onPick = onPick
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        // Inicia directamente en la carpeta Documents de la app para que el botón Open esté habilitado de inmediato
        picker.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: FolderDocumentPicker

        init(parent: FolderDocumentPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let first = urls.first else {
                DispatchQueue.main.async { self.parent.isPresented = false }
                return
            }
            DispatchQueue.main.async {
                self.parent.onPick(first)
                self.parent.isPresented = false
                controller.dismiss(animated: true)
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            DispatchQueue.main.async {
                self.parent.isPresented = false
                controller.dismiss(animated: true)
            }
        }
    }
}
