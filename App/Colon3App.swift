import SwiftUI

/// Single owner of the app's service graph, held in `@StateObject` so SwiftUI never recreates
/// services or leaks `TransferMonitor` across `App` struct re-evaluations.
@MainActor
final class AppContainer: ObservableObject {
    let library: LibraryStore
    let soulseek: SoulseekModel
    let player: Player
    let favorites = FavoritesStore()
    let playlists = PlaylistStore()
    let completeness = AlbumCompletenessStore()
    let stats = StatsStore()
    let router = AppRouter()
    let wifi: WiFiTransferServer
    let transferMonitor: TransferMonitor

    init() {
        Diagnostics.shared.start()
        let library = LibraryStore()
        let player = Player(equalizer: Equalizer())
        player.library = library
        player.stats = stats

        let soulseek = SoulseekModel(library: library)
        soulseek.completeness = completeness
        soulseek.stats = stats

        let wifi = WiFiTransferServer(root: library.root)
        wifi.onFilesChanged = { [weak library] in library?.rescan() }

        self.library = library
        self.soulseek = soulseek
        self.player = player
        self.wifi = wifi
        self.transferMonitor = TransferMonitor(soulseek: soulseek, library: library, player: player, stats: stats)
    }
}

@main
struct Colon3App: App {
    @StateObject private var app = AppContainer()
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasInBackground = false

    var body: some Scene {
        WindowGroup {
            ContentView(app: app)
                .environmentObject(app.soulseek)
                .environmentObject(app.soulseek.transfers)
                .environmentObject(app.soulseek.searchStore)
                .environmentObject(app.library)
                .environmentObject(app.player)
                .environmentObject(app.player.clock)
                .environmentObject(app.favorites)
                .environmentObject(app.playlists)
                .environmentObject(app.completeness)
                .environmentObject(app.stats)
                .environmentObject(app.router)
                .environmentObject(app.wifi)
                .onAppear {
                    app.soulseek.start()
                }
                .onOpenURL { url in
                    if let scheme = url.scheme?.lowercased(), scheme == "colon3" || scheme == "seekios" {
                        app.router.handle(url)
                        return
                    }
                    guard url.isFileURL else { return }
                    let inboxURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("Inbox", isDirectory: true)
                    Task {
                        let imported = await app.library.importItems([url])
                        if imported > 0 && url.isContained(in: inboxURL) {
                            try? FileManager.default.removeItem(at: url)
                        }
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                app.soulseek.reconnectIfNeeded()
                if wasInBackground {
                    wasInBackground = false
                    app.library.rescan()
                }
            case .background:
                wasInBackground = true
                app.stats.save()
                app.soulseek.transfers.persistNow()
                if app.wifi.isRunning {
                    app.wifi.stop()
                }
            default:
                break
            }
        }
    }
}
