import SoulseekKit
import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var soulseek: SoulseekModel
    @EnvironmentObject private var router: AppRouter
    @State private var query = ""
    @State private var keywordFilter = ""
    @State private var isSearchFocused = false
    @State private var showFilters = false

    /// Resultados filtrados en tiempo real por el segundo mini-buscador
    private var displayedResults: [FolderResult] {
        let trimmed = keywordFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return soulseek.results }
        let terms = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        return soulseek.results.filter { folder in
            let folderText = "\(folder.folder) \(folder.username)".lowercased()
            return terms.allSatisfy { term in
                if folderText.contains(term) { return true }
                return folder.files.contains { $0.filename.lowercased().contains(term) }
            }
        }
    }

    /// Historial filtrado mientras escribes en el buscador principal
    private var matchingHistory: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return soulseek.searchHistory }
        return soulseek.searchHistory.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Muestra el historial cuando pulsas el buscador o cuando aún no hay una búsqueda activa
    private var shouldShowHistory: Bool {
        !soulseek.searchHistory.isEmpty && (isSearchFocused || soulseek.currentQuery.isEmpty)
    }

    var body: some View {
        NavigationStack {
            List {
                if !soulseek.isLoggedIn {
                    Section { ConnectionBanner() }
                }

                // Desplegable de historial de búsqueda al pulsar buscar
                if shouldShowHistory && !matchingHistory.isEmpty {
                    Section {
                        ForEach(matchingHistory, id: \.self) { item in
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
                                    Image(systemName: "arrow.up.left")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
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

                if !soulseek.currentQuery.isEmpty && !isSearchFocused {
                    Section {
                        FilterChips(showAll: $showFilters)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }

                    // Segundo mini-buscador para filtrar por palabras clave dentro de los resultados
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "line.3.horizontal.decrease")
                                .foregroundStyle(.secondary)
                            TextField("Filter results by keyword, file or user…", text: $keywordFilter)
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
                        }
                        .padding(.vertical, 2)
                    }

                    Section {
                        HStack {
                            Text("\(soulseek.responseCount) users · \(displayedResults.count) folders")
                            if soulseek.hiddenCount > 0 {
                                Text("· \(soulseek.hiddenCount) filtered out")
                            }
                            Spacer()
                            if soulseek.filters.activeCount > 0 || soulseek.audioOnly || !keywordFilter.isEmpty {
                                Button("Clear Filters") {
                                    soulseek.audioOnly = false
                                    keywordFilter = ""
                                    soulseek.filters = ResultFilters(sort: soulseek.filters.sort)
                                }
                                .font(.footnote.weight(.semibold))
                            }
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    ForEach(displayedResults) { folder in
                        NavigationLink(value: folder.id) {
                            FolderRow(folder: folder)
                        }
                        .contextMenu {
                            NavigationLink(value: BrowseTarget(username: folder.username, folder: folder.folder)) {
                                Label("Browse Full Folder", systemImage: "folder")
                            }
                            if let parent = folder.parentFolderPath {
                                NavigationLink(value: BrowseTarget(username: folder.username, folder: parent)) {
                                    Label("Browse Parent Folder", systemImage: "folder.badge.gearshape")
                                }
                            }
                            Button {
                                soulseek.downloadFolder(folder)
                            } label: {
                                Label("Download Folder", systemImage: "arrow.down.circle")
                            }
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
                soulseek.search(query)
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
                FolderDetailView(folderID: id)
            }
            .navigationDestination(for: BrowseTarget.self) { target in
                RemoteFolderBrowserView(target: target)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showFilters = true
                    } label: {
                        Image(systemName: (soulseek.filters.activeCount > 0 || soulseek.audioOnly)
                              ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .sheet(isPresented: $showFilters) {
                SearchFiltersView()
                    .presentationDetents([.medium, .large])
            }
            .overlay {
                if soulseek.currentQuery.isEmpty && soulseek.searchHistory.isEmpty && soulseek.isLoggedIn && !isSearchFocused {
                    EmptyStateView(title: "Search Soulseek",
                                   message: "Search for music, videos, archives, books or any file. Results arrive over ~30 seconds.",
                                   systemImage: "magnifyingglass")
                }
            }
        }
    }
}

struct FolderRow: View {
    let folder: FolderResult

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ArtworkView(source: .remote(folder.coverQuery), size: 60, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name)
                    .font(.headline)
                    .lineLimit(2)
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
                    Label(folder.username, systemImage: "person")
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
}

struct FolderDetailView: View {
    let folderID: String
    @EnvironmentObject private var soulseek: SoulseekModel
    @State private var fileFilter = ""

    var body: some View {
        if let folder = soulseek.folder(withID: folderID) {
            let filteredFiles = folder.files.filter {
                fileFilter.trimmingCharacters(in: .whitespaces).isEmpty ||
                $0.filename.localizedCaseInsensitiveContains(fileFilter.trimmingCharacters(in: .whitespaces))
            }

            List {
                Section {
                    HStack(spacing: 16) {
                        ArtworkView(source: .remote(folder.coverQuery), size: 110, cornerRadius: 10)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(folder.name).font(.headline)
                            Text(folder.formatSummary).font(.subheadline).foregroundStyle(.secondary)
                            Text("\(folder.files.count) files · \(Formatting.bytes(folder.totalSize))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Color.clear)
                }

                // Navegador de Carpeta Raíz y Carpetas Contenedoras (pulsando sobre cualquier nivel)
                Section("Container & Root Folders (Tap to Browse)") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(folder.pathLevels.enumerated()), id: \.offset) { index, level in
                                if index > 0 {
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                NavigationLink(value: BrowseTarget(username: folder.username, folder: level.fullPath)) {
                                    Label(level.name, systemImage: index == 0 ? "externaldrive.fill" : "folder.fill")
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
                        NavigationLink(value: BrowseTarget(username: folder.username, folder: parent)) {
                            Label("Go Up to Parent Folder", systemImage: "arrow.turn.left.up")
                        }
                    }

                    NavigationLink(value: BrowseTarget(username: folder.username, folder: folder.folder)) {
                        Label("Explore Full Container Folder from Peer", systemImage: "folder.badge.magnifyingglass")
                    }
                }

                Section {
                    Button {
                        soulseek.downloadFolder(folder)
                    } label: {
                        Label("Download All (\(folder.files.count) files)", systemImage: "arrow.down.circle.fill")
                    }
                    .disabled(!soulseek.isLoggedIn)
                } footer: {
                    Text("From \(folder.username) · \(folder.folder). Tap any folder badge above to navigate through its root/parent directories.")
                }

                Section {
                    if folder.files.count > 5 {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("Filter files in this folder…", text: $fileFilter)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            if !fileFilter.isEmpty {
                                Button {
                                    fileFilter = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    ForEach(filteredFiles, id: \.path) { file in
                        FileRow(file: file, username: folder.username, folderImages: folder.images, showBrowseParent: false)
                    }
                }
            }
            .navigationTitle(folder.name)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            Text("This result is no longer available.")
                .foregroundStyle(.secondary)
        }
    }
}

/// Vista completa para explorar cualquier carpeta contenedora o raíz de un usuario
struct RemoteFolderBrowserView: View {
    let target: BrowseTarget
    @EnvironmentObject private var soulseek: SoulseekModel
    @State private var allPeerFiles: [SharedFile] = []
    @State private var isLoading = true
    @State private var filterText = ""

    private var currentPath: String {
        target.folder
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
        var current = ""
        return parts.map { part in
            current = current.isEmpty ? part : "\(current)\\\(part)"
            return (name: part, fullPath: current)
        }
    }

    /// Subcarpetas inmediatas dentro de esta carpeta contenedora
    private var subfolders: [(name: String, fullPath: String, fileCount: Int)] {
        let prefix = currentPath.isEmpty ? "" : currentPath + "\\"
        let prefixLower = prefix.lowercased()
        var counts: [String: Int] = [:]
        var originalNames: [String: String] = [:]

        for file in allPeerFiles {
            let folder = file.folder
            if currentPath.isEmpty {
                if let first = folder.split(separator: "\\").first.map(String.init) {
                    let key = first.lowercased()
                    counts[key, default: 0] += 1
                    if originalNames[key] == nil { originalNames[key] = first }
                }
            } else if folder.lowercased().hasPrefix(prefixLower) {
                let remainder = folder.dropFirst(prefix.count)
                if let nextSegment = remainder.split(separator: "\\").first.map(String.init), !nextSegment.isEmpty {
                    let key = nextSegment.lowercased()
                    counts[key, default: 0] += 1
                    if originalNames[key] == nil { originalNames[key] = nextSegment }
                }
            }
        }

        let trimmed = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        return counts.keys.compactMap { key -> (name: String, fullPath: String, fileCount: Int)? in
            guard let name = originalNames[key], let count = counts[key] else { return nil }
            if !trimmed.isEmpty && !name.lowercased().contains(trimmed) { return nil }
            let full = currentPath.isEmpty ? name : "\(currentPath)\\\(name)"
            return (name: name, fullPath: full, fileCount: count)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Archivos que están directamente dentro de esta carpeta
    private var directFiles: [SharedFile] {
        let trimmed = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        return allPeerFiles.filter { file in
            guard file.folder.caseInsensitiveCompare(currentPath) == .orderedSame else { return false }
            if !trimmed.isEmpty {
                return file.filename.lowercased().contains(trimmed)
            }
            return true
        }
        .sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
    }

    var body: some View {
        List {
            // Barra de ruta interactiva (migas de pan) para saltar a cualquier carpeta superior o a la raíz
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        NavigationLink(value: BrowseTarget(username: target.username, folder: "")) {
                            Label(target.username, systemImage: "person.crop.square.fill")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                        }
                        .buttonStyle(.plain)

                        ForEach(Array(pathLevels.enumerated()), id: \.offset) { _, level in
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            NavigationLink(value: BrowseTarget(username: target.username, folder: level.fullPath)) {
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
                    NavigationLink(value: BrowseTarget(username: target.username, folder: parent)) {
                        Label("Up to Parent Folder", systemImage: "arrow.turn.left.up")
                    }
                } else if !currentPath.isEmpty {
                    NavigationLink(value: BrowseTarget(username: target.username, folder: "")) {
                        Label("Up to User Root (\(target.username))", systemImage: "arrow.turn.left.up")
                    }
                }
            } header: {
                Text("Path Navigation")
            }

            // Mini-buscador dentro del explorador de carpetas
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter folders or files here…", text: $filterText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !filterText.isEmpty {
                        Button {
                            filterText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if isLoading {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Requesting folder contents from \(target.username)…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }

            if !subfolders.isEmpty {
                Section("Subfolders (\(subfolders.count))") {
                    ForEach(subfolders, id: \.fullPath) { sub in
                        NavigationLink(value: BrowseTarget(username: target.username, folder: sub.fullPath)) {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill")
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(sub.name)
                                        .font(.body.weight(.medium))
                                        .lineLimit(2)
                                    Text("\(sub.fileCount) files inside")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }

            if !directFiles.isEmpty {
                Section {
                    Button {
                        soulseek.downloadFiles(directFiles, from: target.username)
                    } label: {
                        Label("Download All Files in This Folder (\(directFiles.count))", systemImage: "arrow.down.circle.fill")
                    }
                    .disabled(!soulseek.isLoggedIn)

                    ForEach(directFiles, id: \.path) { file in
                        FileRow(file: file, username: target.username, folderImages: [], showBrowseParent: false)
                    }
                } header: {
                    Text("Files (\(directFiles.count))")
                }
            }

            if !isLoading && subfolders.isEmpty && directFiles.isEmpty {
                Section {
                    Text("No files or subfolders found at this level.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(folderTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    loadFolder(force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .task(id: target.id) {
            loadFolder(force: false)
        }
    }

    private func loadFolder(force: Bool) {
        let fallback = soulseek.knownFiles(for: target.username)
        if !fallback.isEmpty {
            allPeerFiles = fallback
        }
        isLoading = true
        soulseek.browseUserFolder(username: target.username, folder: target.folder, forceRefresh: force) { files in
            if let files, !files.isEmpty {
                allPeerFiles = files
            } else if allPeerFiles.isEmpty {
                allPeerFiles = soulseek.knownFiles(for: target.username)
            }
            isLoading = false
        }
    }
}

struct FileRow: View {
    let file: SharedFile
    let username: String
    let folderImages: [SharedFile]
    var showBrowseParent: Bool = true
    @EnvironmentObject private var soulseek: SoulseekModel

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.filename)
                    .lineLimit(2)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusButton
        }
        .contextMenu {
            Button {
                soulseek.download(file, from: username, knownImages: folderImages)
            } label: {
                Label("Download File", systemImage: "arrow.down.circle")
            }
            NavigationLink(value: BrowseTarget(username: username, folder: file.folder)) {
                Label("Open Container Folder", systemImage: "folder")
            }
        }
    }

    private var details: String {
        var parts: [String] = []
        let ext = file.fileExtension.uppercased()
        if !ext.isEmpty {
            parts.append(ext)
        }
        parts.append(Formatting.bytes(file.size))
        if let duration = file.attributes.duration { parts.append(Formatting.duration(Double(duration))) }
        if let bitrate = file.attributes.bitrate { parts.append("\(bitrate) kbps") }
        if let depth = file.attributes.bitDepth, let rate = file.attributes.sampleRate {
            parts.append("\(depth)-bit/\(Formatting.kilohertz(rate)) kHz")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusButton: some View {
        switch soulseek.state(of: file, from: username) {
        case .none, .some(.failed):
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
    @EnvironmentObject private var soulseek: SoulseekModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Sort By", selection: $soulseek.filters.sort) {
                        ForEach(ResultFilters.Sort.allCases) { sort in
                            Label(sort.rawValue, systemImage: sort.systemImage).tag(sort)
                        }
                    }
                }

                Section("File Type & Quality") {
                    Picker("Category", selection: $soulseek.filters.fileType) {
                        ForEach(ResultFilters.FileType.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Minimum Bitrate", selection: $soulseek.filters.minBitrate) {
                        ForEach(ResultFilters.bitrateChoices, id: \.self) { kbps in
                            Text(kbps == 0 ? "Any" : "\(kbps) kbps").tag(kbps)
                        }
                    }
                    Toggle("Audio Formats Only", isOn: $soulseek.audioOnly)
                }

                Section {
                    Toggle("Free Upload Slot Only", isOn: $soulseek.filters.freeSlotOnly)
                    Stepper(value: $soulseek.filters.minFiles, in: 1...30) {
                        LabeledContent("Minimum Files", value: soulseek.filters.minFiles == 1 ? "Any" : "\(soulseek.filters.minFiles)")
                    }
                } header: {
                    Text("Availability")
                } footer: {
                    Text("A minimum of around 6 files skips single files and finds larger folders/packs.")
                }

                Section {
                    TextField("live, remix, sample", text: $soulseek.filters.excludeWords)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Exclude Words")
                } footer: {
                    Text("Hides folders whose path contains any of these.")
                }

                if !soulseek.filters.isDefault || soulseek.audioOnly {
                    Section {
                        Button("Reset Filters", role: .destructive) {
                            soulseek.audioOnly = false
                            soulseek.filters = ResultFilters()
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

/// One-tap sort and filter controls above the results.
struct FilterChips: View {
    @Binding var showAll: Bool
    @EnvironmentObject private var soulseek: SoulseekModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Sort By", selection: $soulseek.filters.sort) {
                        ForEach(ResultFilters.Sort.allCases) { sort in
                            Label(sort.rawValue, systemImage: sort.systemImage).tag(sort)
                        }
                    }
                } label: {
                    chip(soulseek.filters.sort.rawValue, systemImage: "arrow.up.arrow.down", active: true)
                }

                Menu {
                    Picker("File Type", selection: $soulseek.filters.fileType) {
                        ForEach(ResultFilters.FileType.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    chip(soulseek.filters.fileType.shortLabel, systemImage: "doc", active: soulseek.filters.fileType != .any)
                }

                Button {
                    soulseek.audioOnly.toggle()
                } label: {
                    chip("Audio Only", systemImage: "music.note", active: soulseek.audioOnly)
                }

                Button {
                    soulseek.filters.freeSlotOnly.toggle()
                } label: {
                    chip("Free Slot", systemImage: "checkmark.circle", active: soulseek.filters.freeSlotOnly)
                }

                Button {
                    showAll = true
                } label: {
                    chip("More", systemImage: "slider.horizontal.3", active: false)
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
