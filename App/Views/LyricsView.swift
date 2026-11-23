import SwiftUI

private final class ScrollTimestampBox {
    var lastScrolled: Date?
}

/// Apple Music-style lyrics: the current line bright, the rest dimmed and softly blurred,
/// auto-scrolling with playback. Only re-renders the line list when `activeLineID` changes.
struct LyricsView: View {
    let track: Track
    let albumTitle: String?
    let position: Double
    let onSeek: (Double) -> Void

    @EnvironmentObject private var router: AppRouter
    @State private var lyrics: Lyrics?
    @State private var isLoading = true
    @State private var retryTrigger = 0
    @State private var scrollTracker = ScrollTimestampBox()

    var body: some View {
        Group {
            if isLoading {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch lyrics {
                case let .synced(lines):
                    SyncedLyricsList(
                        lines: lines,
                        active: activeLine(in: lines),
                        scrollTracker: scrollTracker,
                        onSeek: onSeek
                    )
                    .equatable()
                    .mask(fade)
                case let .plain(lines):
                    plain(lines)
                case .instrumental:
                    message("Instrumental", systemImage: "music.note")
                case .notFound:
                    VStack(spacing: 12) {
                        message("No lyrics found on LRCLIB", systemImage: "quote.bubble")
                            .frame(maxHeight: 120)
                        Button("Import .lrc File…") { router.importLyrics(for: track) }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case nil:
                    VStack(spacing: 12) {
                        message("Couldn't load lyrics", systemImage: "wifi.exclamationmark")
                        Button("Try Again") { retryTrigger += 1 }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: "\(track.id)#\(router.lyricsRevision)#\(retryTrigger)") { await load() }
    }

    private func load() async {
        isLoading = true
        let file = LibraryStore.lyricsURL(for: track)
        let local = await Task.detached(priority: .userInitiated) {
            LyricsService.localLyrics(at: file)
        }.value
        guard !Task.isCancelled else { return }
        if let local {
            lyrics = local
        } else {
            let remote = await LyricsService.shared.lyrics(
                title: track.title,
                artist: track.artist,
                album: albumTitle,
                duration: track.duration,
                cacheKey: track.id
            )
            guard !Task.isCancelled else { return }
            lyrics = remote
        }
        isLoading = false
    }

    private func activeLine(in lines: [LyricLine]) -> Int {
        let now = position + 0.25
        var active = -1
        for line in lines {
            if line.time <= now { active = line.id } else { break }
        }
        return active
    }

    private func plain(_ lines: [String]) -> some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 40)
        }
        .mask(fade)
    }

    private func message(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.largeTitle)
            Text(text).font(.headline)
        }
        .foregroundStyle(.white.opacity(0.6))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fade: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.1),
            .init(color: .black, location: 0.85),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }
}

private struct SyncedLyricsList: View, Equatable {
    let lines: [LyricLine]
    let active: Int
    let scrollTracker: ScrollTimestampBox
    let onSeek: (Double) -> Void

    static func == (lhs: SyncedLyricsList, rhs: SyncedLyricsList) -> Bool {
        lhs.active == rhs.active && lhs.lines == rhs.lines
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(lines) { line in
                        let distance = active < 0 ? 1 : abs(line.id - active)
                        let blurRadius: Double = (line.id == active || distance > 6) ? 0 : min(Double(distance) * 0.6, 2.4)
                        Text(line.text)
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(.white.opacity(line.id == active ? 1 : 0.32))
                            .blur(radius: blurRadius)
                            .scaleEffect(line.id == active ? 1 : 0.97, anchor: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .id(line.id)
                            .onTapGesture { onSeek(line.time) }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 140)
                .animation(.easeOut(duration: 0.35), value: active)
            }
            .simultaneousGesture(DragGesture().onChanged { _ in scrollTracker.lastScrolled = Date() })
            .onChange(of: active) { _, newValue in
                if let scrolled = scrollTracker.lastScrolled, Date().timeIntervalSince(scrolled) < 4 { return }
                withAnimation(.spring(response: 0.6, dampingFraction: 0.9)) {
                    proxy.scrollTo(max(newValue, 0), anchor: UnitPoint(x: 0, y: 0.3))
                }
            }
            .onAppear { proxy.scrollTo(max(active, 0), anchor: UnitPoint(x: 0, y: 0.3)) }
        }
    }
}
