import PhotosUI
import SwiftUI

/// The pickers and sheets AppRouter can ask for. Attached twice: to the tab view, and to the
/// Now Playing sheet (a sheet can't be presented from under another one). `active` makes sure
/// only the frontmost copy reacts.
struct RouterPresenters: ViewModifier {
    let active: Bool

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playlists: PlaylistStore
    @State private var photoItem: PhotosPickerItem?

    func body(content: Content) -> some View {
        content
            .sheet(item: active ? $router.playlistRequest : .constant(nil)) { request in
                AddToPlaylistSheet(request: request)
            }
            .fileImporter(isPresented: active ? $router.showImporter : .constant(false),
                          allowedContentTypes: router.importKind.types,
                          allowsMultipleSelection: router.importKind.allowsMultiple) { result in
                switch result {
                case let .success(urls) where !urls.isEmpty:
                    handleImport(urls, kind: router.importKind)
                case .success:
                    break
                case let .failure(error):
                    router.message = "Couldn't open the selected file: \(error.localizedDescription)"
                }
            }
            .photosPicker(isPresented: active ? $router.showPhotoPicker : .constant(false),
                          selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                guard active, let item, let target = router.photoTarget else { return }
                photoItem = nil
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self) else {
                        router.message = "Couldn't read that photo."
                        return
                    }
                    if !(await library.setCustomArtwork(data, for: target)) {
                        router.message = "That image couldn't be used."
                    }
                }
            }
            .alert(router.message ?? "",
                   isPresented: Binding(get: { active && router.message != nil },
                                        set: { if !$0 { router.message = nil } })) {
                Button("OK", role: .cancel) {}
            }
    }

    private func handleImport(_ urls: [URL], kind: ImportKind) {
        switch kind {
        case .music:
            let lyricsOnly = urls.allSatisfy { $0.pathExtension.lowercased() == "lrc" }
            Task {
                let count = await library.importItems(urls)
                if lyricsOnly {
                    router.lyricsChanged()
                    router.message = "Lyrics files were matched to songs with the same file name."
                } else {
                    router.message = count == 0 ? "No audio files found." : "Imported \(count) song\(count == 1 ? "" : "s")."
                }
            }

        case .playlist:
            let url = urls[0]
            Task {
                if let playlist = await playlists.importM3U(url, library: library) {
                    let count = playlist.trackIDs.count
                    router.message = "Imported “\(playlist.name)” with \(count) song\(count == 1 ? "" : "s")."
                } else {
                    router.message = "None of the playlist's songs are in your library."
                }
            }

        case let .lyrics(track):
            let url = urls[0]
            Task {
                if await library.importLyrics(from: url, for: track) {
                    await LyricsService.shared.forget(cacheKey: track.id)
                    router.lyricsChanged()
                } else {
                    router.message = "Couldn't read that lyrics file."
                }
            }

        case let .artwork(target):
            let url = urls[0]
            Task {
                let data: Data? = await Task.detached(priority: .userInitiated) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return try? Data(contentsOf: url)
                }.value
                guard let data, await library.setCustomArtwork(data, for: target) else {
                    router.message = "That image couldn't be used."
                    return
                }
            }
        }
    }
}
