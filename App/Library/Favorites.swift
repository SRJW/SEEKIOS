import Foundation

/// Favourite songs (by track id) and albums (by album id), saved as JSON.
@MainActor
final class FavoritesStore: ObservableObject {
    @Published private(set) var songs: Set<String> = []
    @Published private(set) var albums: Set<String> = []

    private struct Stored: Codable, Sendable {
        var songs: [String]
        var albums: [String]
    }

    private let saveQueue = DispatchQueue(label: "seekios.favorites")
    private let fileURL = AppDirectories.applicationSupport.appendingPathComponent("favorites.json")

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            songs = Set(stored.songs)
            albums = Set(stored.albums)
        }
    }

    func isFavorite(_ track: Track) -> Bool { songs.contains(track.id) }
    func isFavorite(_ album: Album) -> Bool { albums.contains(album.id) }

    func isFavorite(_ item: LibraryItem) -> Bool {
        switch item {
        case let .album(album): return isFavorite(album)
        case let .single(track): return isFavorite(track)
        }
    }

    func toggle(_ track: Track) { set(track, favorite: !isFavorite(track)) }
    func toggle(_ album: Album) { set(album, favorite: !isFavorite(album)) }

    func set(_ track: Track, favorite: Bool) {
        let changed = favorite ? songs.insert(track.id).inserted : (songs.remove(track.id) != nil)
        if changed { save() }
    }

    func set(_ album: Album, favorite: Bool) {
        let changed = favorite ? albums.insert(album.id).inserted : (albums.remove(album.id) != nil)
        if changed { save() }
    }

    func set(_ items: [LibraryItem], favorite: Bool) {
        var changed = false
        for item in items {
            switch item {
            case let .album(album):
                if favorite ? albums.insert(album.id).inserted : (albums.remove(album.id) != nil) { changed = true }
            case let .single(track):
                if favorite ? songs.insert(track.id).inserted : (songs.remove(track.id) != nil) { changed = true }
            }
        }
        if changed { save() }
    }

    func forget(_ tracks: [Track], keepingAlbumIDs validAlbumIDs: Set<String>? = nil) {
        var changed = false
        for track in tracks {
            if songs.remove(track.id) != nil { changed = true }
        }
        if let validAlbumIDs {
            let before = albums.count
            albums = albums.intersection(validAlbumIDs)
            if albums.count != before { changed = true }
        }
        if changed { save() }
    }

    private func save() {
        let stored = Stored(songs: songs.sorted(), albums: albums.sorted())
        let targetURL = fileURL
        saveQueue.async {
            AppDirectories.ensureParentDirectory(for: targetURL)
            if let data = try? JSONEncoder().encode(stored) {
                try? data.write(to: targetURL, options: .atomic)
            }
        }
    }
}
