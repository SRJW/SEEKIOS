import Foundation
import SoulseekKit

struct LyricLine: Identifiable, Hashable {
    let id: Int
    let time: Double
    let text: String
}

enum Lyrics: Equatable {
    case synced([LyricLine])
    case plain([String])
    case instrumental
    case notFound
}

/// Where the lyrics on screen came from.
enum LyricsOrigin {
    case file, lrclib
}

/// Lyrics from a .lrc file next to the song if there is one, otherwise LRCLIB (lrclib.net):
/// free, no API key, mostly time-synced. LRCLIB answers are cached on disk.
actor LyricsService {
    static let shared = LyricsService()

    private struct Entry: Codable {
        var syncedLyrics: String?
        var plainLyrics: String?
        var instrumental: Bool?
        var duration: Double?

        var hasContent: Bool {
            (syncedLyrics?.isEmpty == false) || (plainLyrics?.isEmpty == false) || (instrumental == true)
        }
    }

    private struct Stored: Codable {
        var entry: Entry?
        var fetched: Date
    }

    private var inFlight: [String: Task<Lyrics?, Never>] = [:]

    private let directory: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static let timestampRegex = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]"#)
    private static let metadataTagRegex = try! NSRegularExpression(
        pattern: #"^\[(ti|ar|al|au|lr|length|by|offset|re|tool|ve|#):.*\]$"#,
        options: [.caseInsensitive]
    )

    /// A sidecar .lrc (or plain text saved as .lrc) next to the song.
    nonisolated static func localLyrics(at url: URL) -> Lyrics? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoded = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
        let text = normalizeNewlines(decoded).replacingOccurrences(of: "\u{FEFF}", with: "")
        let synced = parseLRC(text)
        if !synced.isEmpty { return .synced(synced) }
        // No timestamps: show it as plain text, stripping only real LRC metadata tags like [ar:...].
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !isMetadataTag($0) }
        let trimmed = lines.drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        return trimmed.isEmpty ? nil : .plain(Array(trimmed))
    }

    /// nil means the lookup failed (offline, server error), so the caller can offer a retry.
    func lyrics(title: String, artist: String, album: String?, duration: Double, cacheKey: String) async -> Lyrics? {
        guard AppSettings.lyricsLookupEnabled else { return .notFound }

        let file = directory.appendingPathComponent(MD5.hex(cacheKey) + ".json")
        if let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            // Misses are retried after a few days in case someone has added the song since.
            if (stored.entry?.hasContent == true) || Date().timeIntervalSince(stored.fetched) < 3 * 86_400 {
                return Self.lyrics(from: stored.entry)
            }
        }

        if let existing = inFlight[cacheKey] {
            return await existing.value
        }

        let task = Task<Lyrics?, Never> {
            let entry: Entry?
            do {
                entry = try await self.fetch(title: title, artist: artist, album: album, duration: duration)
            } catch {
                return nil
            }
            let validEntry = (entry?.hasContent == true) ? entry : nil
            if let data = try? JSONEncoder().encode(Stored(entry: validEntry, fetched: Date())) {
                try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }
            return Self.lyrics(from: validEntry)
        }
        inFlight[cacheKey] = task
        let result = await task.value
        if inFlight[cacheKey] == task { inFlight[cacheKey] = nil }
        return result
    }

    func forget(cacheKey: String) {
        inFlight[cacheKey]?.cancel()
        inFlight[cacheKey] = nil
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(MD5.hex(cacheKey) + ".json"))
    }

    private func fetch(title: String, artist: String, album: String?, duration: Double) async throws -> Entry? {
        let validDuration = duration.isFinite && duration > 0 && duration < Double(Int.max / 2)

        if let album, validDuration, var components = URLComponents(string: "https://lrclib.net/api/get") {
            components.queryItems = [
                URLQueryItem(name: "track_name", value: title),
                URLQueryItem(name: "artist_name", value: artist),
                URLQueryItem(name: "album_name", value: album),
                URLQueryItem(name: "duration", value: String(Int(duration.rounded()))),
            ]
            if let url = components.url {
                let (data, status) = try await get(url)
                if status == 200, let entry = try? JSONDecoder().decode(Entry.self, from: data), entry.hasContent {
                    return entry
                }
                if status != 200 && status != 404 && status != 400 { throw URLError(.badServerResponse) }
            }
        }

        guard var components = URLComponents(string: "https://lrclib.net/api/search") else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        guard let searchURL = components.url else { throw URLError(.badURL) }
        let (data, status) = try await get(searchURL)
        guard status == 200 else { throw URLError(.badServerResponse) }
        let results = try JSONDecoder().decode([Entry].self, from: data)
        let close = results.filter { entry in
            guard validDuration, let other = entry.duration, other.isFinite else { return true }
            return abs(other - duration) <= 5
        }
        return close.first(where: { $0.syncedLyrics?.isEmpty == false })
            ?? close.first(where: { $0.plainLyrics?.isEmpty == false || $0.instrumental == true })
    }

    private func get(_ url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func lyrics(from entry: Entry?) -> Lyrics {
        guard let entry else { return .notFound }
        if let synced = entry.syncedLyrics, !synced.isEmpty {
            let lines = parseLRC(synced)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let plain = entry.plainLyrics, !plain.isEmpty {
            let normalized = normalizeNewlines(plain)
            return .plain(normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        }
        return entry.instrumental == true ? .instrumental : .notFound
    }

    private nonisolated static func normalizeNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private nonisolated static func isMetadataTag(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") && trimmed.hasSuffix("]") else { return false }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return metadataTagRegex.firstMatch(in: trimmed, range: range) != nil
    }

    /// "[01:23.45] text" lines; a line may carry several timestamps.
    static func parseLRC(_ text: String) -> [LyricLine] {
        let normalized = normalizeNewlines(text)
        var lines: [(Double, String)] = []
        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let range = NSRange(raw.startIndex..., in: raw)
            let matches = timestampRegex.matches(in: raw, range: range)
            guard let last = matches.last, let textRange = Range(NSRange(location: last.range.upperBound,
                                                                         length: range.upperBound - last.range.upperBound), in: raw)
            else { continue }
            let words = raw[textRange].trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard let minutes = Range(match.range(at: 1), in: raw).flatMap({ Double(raw[$0]) }),
                      let secondsText = Range(match.range(at: 2), in: raw).map({ raw[$0].replacingOccurrences(of: ":", with: ".") }),
                      let seconds = Double(secondsText) else { continue }
                lines.append((minutes * 60 + seconds, words.isEmpty ? "♪" : words))
            }
        }
        return lines.sorted { $0.0 < $1.0 }.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }
}
