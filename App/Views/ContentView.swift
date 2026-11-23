import Combine
import SwiftUI
import UIKit

struct ContentView: View {
    let app: AppContainer
    @EnvironmentObject private var router: AppRouter
    @AppStorage(AccentPalette.storageKey) private var accentHex = AccentPalette.defaultHex

    @State private var activeDownloadCount = 0
    @State private var hasCurrentTrack = false

    var body: some View {
        TabView(selection: $router.tab) {
            Tab("Library", systemImage: "music.note.house", value: AppTab.library) {
                LibraryView().modifier(FallbackMiniPlayer(open: openPlayer))
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) {
                SearchView().modifier(FallbackMiniPlayer(open: openPlayer))
            }
            Tab("Downloads", systemImage: "arrow.down.circle", value: AppTab.downloads) {
                DownloadsView().modifier(FallbackMiniPlayer(open: openPlayer))
            }
            .badge(activeDownloadCount)
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView().modifier(FallbackMiniPlayer(open: openPlayer))
            }
        }
        .modifier(TabAccessoryMiniPlayer(isVisible: hasCurrentTrack, open: openPlayer))
        .modifier(RouterPresenters(active: !router.showPlayer))
        .sheet(isPresented: $router.showPlayer) {
            NowPlayingView()
                .modifier(RouterPresenters(active: true))
                .tint(Color(hex: accentHex))
        }
        .onReceive(app.soulseek.transfers.$activeDownloadCount.removeDuplicates()) { count in
            activeDownloadCount = count
        }
        .onReceive(app.player.$entries.map { !$0.isEmpty }.removeDuplicates()) { hasTrack in
            hasCurrentTrack = hasTrack
        }
        .onReceive(app.library.$artworkRevision.dropFirst()) { _ in
            app.player.reloadArtwork()
        }
        .onChange(of: accentHex) { _, newHex in
            syncAppIcon(with: newHex)
        }
        .tint(Color(hex: accentHex))
    }

    private func openPlayer() {
        guard hasCurrentTrack else { return }
        router.showPlayer = true
    }

    private func syncAppIcon(with hex: String) {
        guard UIApplication.shared.supportsAlternateIcons else { return }
        let cleanHex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased()
        let iconName = "AppIcon_\(cleanHex)"
        // Only request alternate icons that actually exist in Info.plist (avoids ColorPicker frame spam).
        let bundleIcons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any]
        let alternates = bundleIcons?["CFBundleAlternateIcons"] as? [String: Any]
        if alternates?[iconName] != nil {
            if UIApplication.shared.alternateIconName != iconName {
                UIApplication.shared.setAlternateIconName(iconName, completionHandler: nil)
            }
        } else if UIApplication.shared.alternateIconName != nil {
            UIApplication.shared.setAlternateIconName(nil, completionHandler: nil)
        }
    }
}

/// Banner shown on screens that need the Soulseek connection, with one-tap reconnect or Settings link.
struct ConnectionBanner: View {
    @EnvironmentObject private var soulseek: SoulseekModel
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        switch soulseek.connection {
        case .loggedIn:
            EmptyView()
        case .connecting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Connecting to Soulseek…")
                    .foregroundStyle(.secondary)
            }
        case let .failed(message):
            HStack {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.subheadline)
                Spacer()
                if soulseek.hasCredentials {
                    Button("Retry") { soulseek.reconnectIfNeeded() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        case .disconnected:
            HStack {
                Label(soulseek.hasCredentials ? "Disconnected" : "Log in under Settings to search Soulseek",
                      systemImage: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                Spacer()
                if soulseek.hasCredentials {
                    Button("Reconnect") { soulseek.reconnectIfNeeded() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Button("Settings") { router.tab = .settings }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }
}
