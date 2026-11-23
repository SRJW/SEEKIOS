import Foundation

/// One audio file in the library. `id` is the path relative to the Music folder, which stays
/// stable across app updates (the absolute container path doesn't).
struct Track: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    var title: String
    var artist: String
    var albumArtist: String?
    var album: String?
    var trackNumber: Int?
    var discNumber: Int?
    var year: Int?
    var duration: Double
    var addedAt: Date
    /// Multichannel or Dolby (E-AC-3) audio: played through AVPlayer with spatial audio, no EQ.
    var isSpatial: Bool
    var hasEmbeddedArt: Bool
    var musicBrainzAlbumID: String?

    var folder: URL { url.deletingLastPathComponent() }
    var fileExtension: String { url.pathExtension.lowercased() }
}

struct Album: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let artist: String
    let year: Int?
    let tracks: [Track]
    let folder: URL
    let addedAt: Date

    var duration: Double { tracks.reduce(0) { $0 + $1.duration } }
    var isSpatial: Bool { tracks.contains(where: \.isSpatial) }
}

/// What the library grid shows: albums, plus songs that don't belong to one.
enum LibraryItem: Identifiable, Hashable, Sendable {
    case album(Album)
    case single(Track)

    var id: String {
        switch self {
        case let .album(album): return "a:" + album.id
        case let .single(track): return "t:" + track.id
        }
    }

    var title: String {
        switch self {
        case let .album(album): return album.title
        case let .single(track): return track.title
        }
    }

    var artist: String {
        switch self {
        case let .album(album): return album.artist
        case let .single(track): return track.artist
        }
    }

    var addedAt: Date {
        switch self {
        case let .album(album): return album.addedAt
        case let .single(track): return track.addedAt
        }
    }

    var tracks: [Track] {
        switch self {
        case let .album(album): return album.tracks
        case let .single(track): return [track]
        }
    }

    var artwork: ArtworkSource {
        switch self {
        case let .album(album): return .album(album)
        case let .single(track): return .track(track)
        }
    }
}

struct ArtistEntry: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let albums: [Album]
    let singles: [Track]

    var trackCount: Int { albums.reduce(singles.count) { $0 + $1.tracks.count } }
    var mostRecentDate: Date {
        let maxAlbum = albums.map(\.addedAt).max() ?? .distantPast
        let maxSingle = singles.map(\.addedAt).max() ?? .distantPast
        return max(maxAlbum, maxSingle)
    }
    var artwork: ArtworkSource? {
        if let album = albums.first { return .album(album) }
        return singles.first.map { .track($0) }
    }
}

enum ArtworkSource: Hashable, Sendable {
    case album(Album)
    case track(Track)
    /// A free-text "artist album" query, looked up online (search results, downloads).
    case remote(String)

    var key: String {
        switch self {
        case let .album(album): return "album:" + album.id
        case let .track(track): return "track:" + track.id
        case let .remote(query): return "remote:" + query.lowercased()
        }
    }
}

enum SortKey {
    /// First letter for A–Z sections; everything else (digits, symbols, other scripts) goes under "#".
    static func section(for text: String) -> String {
        let sortBase = sortable(text)
        let folded = sortBase.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        guard let first = folded.first, first.isASCII, first.isLetter else { return "#" }
        return String(first).uppercased()
    }

    /// Ignores a leading ASCII "The " the way Apple Music does (preserving diacritics like "Thé").
    static func sortable(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 4 {
            let prefix = trimmed.prefix(4)
            if prefix == "The " || prefix == "the " || prefix == "THE " {
                let remainder = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)
                if !remainder.isEmpty { return remainder }
            }
        }
        return trimmed
    }

    static func less(_ lhs: String, _ rhs: String) -> Bool {
        let left = section(for: lhs), right = section(for: rhs)
        if left != right {
            if left == "#" { return false }
            if right == "#" { return true }
            return left < right
        }
        return sortable(lhs).localizedStandardCompare(sortable(rhs)) == .orderedAscending
    }

    static let alphabet: [String] = (65...90).map { String(UnicodeScalar($0)!) } + ["#"]
}
