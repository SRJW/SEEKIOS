import Foundation

struct Playlist: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    /// Track ids (paths relative to the Music folder), in playlist order. Duplicates are allowed.
    var trackIDs: [String]
    var created: Date
    var modified: Date
}

/// User playlists, saved as JSON in Application Support.
@MainActor
final class PlaylistStore: ObservableObject {
    @Published private(set) var playlists: [Playlist] = []

    private let saveQueue = DispatchQueue(label: "seekios.playlists")
    private let fileURL = AppDirectories.applicationSupport.appendingPathComponent("playlists.json")

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Playlist].self, from: data) {
            playlists = decoded
        }
    }

    func playlist(id: UUID) -> Playlist? { playlists.first { $0.id == id } }

    /// Tracks that still exist in the library, in order.
    func tracks(of playlist: Playlist, in library: LibraryStore) -> [Track] {
        playlist.trackIDs.compactMap { library.track(id: $0) }
    }

    @discardableResult
    func create(named name: String, with tracks: [Track] = []) -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let playlist = Playlist(id: UUID(), name: trimmed.isEmpty ? "New Playlist" : trimmed,
                                trackIDs: tracks.map(\.id), created: now, modified: now)
        playlists.insert(playlist, at: 0)
        save()
        return playlist
    }

    func rename(_ playlist: Playlist, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        edit(playlist) { $0.name = trimmed }
    }

    func delete(_ playlist: Playlist) {
        playlists.removeAll { $0.id == playlist.id }
        save()
    }

    /// Returns how many were added; songs already in the playlist are skipped.
    @discardableResult
    func add(_ tracks: [Track], to playlist: Playlist) -> Int {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return 0 }
        var present = Set(playlists[index].trackIDs)
        var added = 0
        for track in tracks where !present.contains(track.id) {
            playlists[index].trackIDs.append(track.id)
            present.insert(track.id)
            added += 1
        }
        if added > 0 {
            playlists[index].modified = Date()
            save()
        }
        return added
    }

    /// Offsets refer to the resolved (existing) track list shown on screen.
    func remove(at offsets: IndexSet, from playlist: Playlist, library: LibraryStore) {
        let visible = visibleIndices(of: playlist, library: library)
        let doomed = IndexSet(offsets.compactMap { visible.indices.contains($0) ? visible[$0] : nil })
        guard !doomed.isEmpty else { return }
        edit(playlist) { $0.trackIDs.remove(atOffsets: doomed) }
    }

    func move(from offsets: IndexSet, to destination: Int, in playlist: Playlist, library: LibraryStore) {
        let visible = visibleIndices(of: playlist, library: library)
        let visibleSet = Set(visible)
        edit(playlist) { list in
            var shown = visible.map { list.trackIDs[$0] }
            shown.move(fromOffsets: offsets, toOffset: destination)
            let hidden = list.trackIDs.indices.filter { !visibleSet.contains($0) }.map { list.trackIDs[$0] }
            list.trackIDs = shown + hidden
        }
    }

    /// Deleted songs leave every playlist, like they leave favourites.
    func forget(_ tracks: [Track]) {
        let doomed = Set(tracks.map(\.id))
        var changed = false
        let now = Date()
        for index in playlists.indices where playlists[index].trackIDs.contains(where: doomed.contains) {
            playlists[index].trackIDs.removeAll { doomed.contains($0) }
            playlists[index].modified = now
            changed = true
        }
        if changed { save() }
    }

    /// An .m3u8 file other players can read, with paths relative to the Music folder.
    func exportM3U(_ playlist: Playlist, library: LibraryStore) -> URL? {
        let headerName = playlist.name.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        var lines = ["#EXTM3U", "#PLAYLIST:\(headerName)"]
        for track in tracks(of: playlist, in: library) {
            let secs = (track.duration.isFinite && track.duration >= 0) ? Int(track.duration.rounded()) : 0
            let artist = track.artist.replacingOccurrences(of: "\n", with: " ")
            let title = track.title.replacingOccurrences(of: "\n", with: " ")
            lines.append("#EXTINF:\(secs),\(artist) - \(title)")
            lines.append(track.id)
        }
        let cleaned = String(playlist.name.map { "/:\\\0\r\n".contains($0) ? "-" : $0 })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = (cleaned.isEmpty || cleaned == "." || cleaned == "..") ? "Playlist" : cleaned
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName + ".m3u8")
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// Reads an .m3u/.m3u8 off MainActor (capped at 5 MB) and matches entries to library songs.
    func importM3U(_ url: URL, library: LibraryStore) async -> Playlist? {
        let rawText: String? = await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), !data.isEmpty, data.count <= 5 * 1024 * 1024 else { return nil }
            return String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        }.value
        guard let text = rawText else { return nil }

        let cleanedText = text.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var name = url.deletingPathExtension().lastPathComponent
        var byName: [String: Track] = [:]
        for track in library.tracks { byName[track.url.lastPathComponent.lowercased()] = track }
        var found: [Track] = []
        for raw in cleanedText.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#PLAYLIST:") {
                let candidate = String(line.dropFirst(10)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty { name = candidate }
                continue
            }
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            var normalized = line
            if normalized.lowercased().hasPrefix("file://"), let fileURL = URL(string: normalized) {
                normalized = fileURL.path
            } else if let decoded = normalized.removingPercentEncoding {
                normalized = decoded
            }
            let path = normalized.replacingOccurrences(of: "\\", with: "/")
            if let track = library.track(id: path) {
                found.append(track)
            } else if let file = path.split(separator: "/").last, let track = byName[String(file).lowercased()] {
                found.append(track)
            }
        }
        guard !found.isEmpty else { return nil }
        return create(named: name, with: found)
    }

    private func visibleIndices(of playlist: Playlist, library: LibraryStore) -> [Int] {
        guard let current = self.playlist(id: playlist.id) else { return [] }
        return current.trackIDs.indices.filter { library.track(id: current.trackIDs[$0]) != nil }
    }

    private func edit(_ playlist: Playlist, _ change: (inout Playlist) -> Void) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        change(&playlists[index])
        playlists[index].modified = Date()
        save()
    }

    private func save() {
        let snapshot = playlists
        let targetURL = fileURL
        saveQueue.async {
            AppDirectories.ensureParentDirectory(for: targetURL)
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: targetURL, options: .atomic)
            }
        }
    }
}
