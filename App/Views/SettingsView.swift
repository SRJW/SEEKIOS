import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var soulseek: SoulseekModel
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var server: WiFiTransferServer

    @AppStorage(AppSettings.artworkLookupKey) private var artworkLookup = true
    @AppStorage(AppSettings.lyricsLookupKey) private var lyricsLookup = true
    @AppStorage(AppSettings.backgroundTransfersKey) private var backgroundTransfers = true
    @AppStorage(AppSettings.transferActivityKey) private var transferActivity = true
    @AppStorage(AppSettings.showMissingKey) private var showMissing = true
    @AppStorage(AppSettings.musicBrainzKey) private var musicBrainz = true
    @AppStorage(AppSettings.seedingKey) private var seeding = false
    @AppStorage(AppSettings.sharingEnabledKey) private var sharingEnabled = false
    @AppStorage(AppSettings.shareOnWiFiOnlyKey) private var shareOnWiFiOnly = true
    @AppStorage(AppSettings.distributedSearchKey) private var distributedSearch = true
    @AppStorage(AppSettings.downloadFolderStructureKey) private var folderStructureRaw = DownloadFolderStructure.album.rawValue
    @AppStorage(AppSettings.maxConcurrentDownloadsKey) private var maxConcurrentDownloads = 4
    @AppStorage(AppSettings.maxConcurrentUploadsKey) private var maxConcurrentUploads = 2
    @AppStorage(AppSettings.maxQueuedPerPeerKey) private var maxQueuedPerPeer = 10

    @State private var username = ""
    @State private var didSeedUsername = false
    @State private var password = ""
    @State private var showDownloadsFolderSheet = false
    @State private var showPeersSheet = false
    @State private var storage: StorageBreakdown?
    @State private var cleanupMessage: String?

    private var folderStructure: Binding<DownloadFolderStructure> {
        Binding(
            get: { DownloadFolderStructure(rawValue: folderStructureRaw) ?? .album },
            set: { folderStructureRaw = $0.rawValue }
        )
    }

    private var appVersionText: String {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        if !buildNumber.isEmpty && !shortVersion.hasSuffix(".\(buildNumber)") {
            return "v\(shortVersion) (\(buildNumber))"
        }
        return "v\(shortVersion)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Version") {
                    HStack {
                        Label("Seekios", systemImage: "info.circle")
                        Spacer()
                        Text(appVersionText)
                            .foregroundStyle(.secondary)
                    }
                    Link(destination: URL(string: "https://github.com/SRJW/SEEKIOS/releases")!) {
                        HStack {
                            Label("View Releases on GitHub", systemImage: "globe")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Section {
                    NavigationLink { StatsView() } label: { StatsPreview() }
                }

                soulseekSection

                Section {
                    LabeledContent("Listen Port") {
                        Text(soulseek.listeningPort > 0 ? "TCP \(soulseek.listeningPort)" : "Closed")
                            .foregroundStyle(soulseek.listeningPort > 0 ? .green : .secondary)
                    }
                    Stepper(value: $maxConcurrentDownloads, in: 1...16) {
                        LabeledContent("Max Concurrent Downloads", value: "\(maxConcurrentDownloads)")
                    }
                    Stepper(value: $maxQueuedPerPeer, in: 1...50) {
                        LabeledContent("Max Queued per Peer", value: "\(maxQueuedPerPeer)")
                    }
                    Button {
                        showPeersSheet = true
                    } label: {
                        LabeledContent("Favorite & Blocked Users", value: "\(soulseek.favoriteUsers.count) / \(soulseek.blockedUsers.count)")
                    }
                } header: {
                    Text("Soulseek Transfers")
                } footer: {
                    Text("Opening a TCP listen port lets Seekios receive indirect transfers from firewalled peers (just like Nicotine+).")
                }
                .onChange(of: maxConcurrentDownloads) { _, _ in soulseek.applyClientSettings() }
                .onChange(of: maxQueuedPerPeer) { _, _ in soulseek.applyClientSettings() }

                Section {
                    Toggle("Share Music Library", isOn: $sharingEnabled)
                    LabeledContent("Status") {
                        Text(soulseek.sharingStatusSummary)
                            .foregroundStyle(soulseek.isEffectivelySharing ? .green : .secondary)
                    }
                    if sharingEnabled {
                        Toggle("Wi-Fi Only (Protect Cellular Data)", isOn: $shareOnWiFiOnly)
                        Toggle("Distributed Search Network", isOn: $distributedSearch)
                        Stepper(value: $maxConcurrentUploads, in: 1...8) {
                            LabeledContent("Upload Slots", value: "\(maxConcurrentUploads)")
                        }
                        Toggle("Seeding Mode (Keep Alive)", isOn: $seeding)
                    }
                } header: {
                    Text("Sharing & Privacy")
                } footer: {
                    Text("Off by default to protect your iPhone's battery, mobile data, and privacy. Because of iOS sandboxing, enabling this only ever exposes audio files inside Seekios's own Music folder — never Photos, iCloud, or other apps. Note: some Soulseek peers automatically block users who share 0 files.")
                }
                .onChange(of: sharingEnabled) { _, _ in soulseek.applyClientSettings() }
                .onChange(of: shareOnWiFiOnly) { _, _ in soulseek.applyClientSettings() }
                .onChange(of: maxConcurrentUploads) { _, _ in soulseek.applyClientSettings() }
                .onChange(of: distributedSearch) { _, _ in soulseek.applyClientSettings() }

                Section("Accent Colour") {
                    AccentPicker()
                }

                Section {
                    NavigationLink {
                        EqualizerView(equalizer: player.equalizer, showDone: false)
                    } label: {
                        EqualizerSettingsRow(equalizer: player.equalizer, bitPerfect: player.bitPerfect)
                    }
                    Toggle("Bit-Perfect Mode", isOn: $player.bitPerfect)
                    if player.bitPerfect {
                        BitPerfectStatus()
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    Text("For USB DACs: switches the output to each song's sample rate and skips the EQ and all volume processing. Bluetooth, AirPlay and the built-in speaker can't be bit-perfect.")
                }

                Section {
                    Toggle("Look Up Missing Artwork", isOn: $artworkLookup)
                    Toggle("Fetch Lyrics", isOn: $lyricsLookup)
                    Toggle("Show Missing Album Songs", isOn: $showMissing)
                    Toggle("Look Up Tracklists on MusicBrainz", isOn: $musicBrainz)
                        .disabled(!showMissing)
                } header: {
                    Text("Online")
                } footer: {
                    Text("Artwork comes from the iTunes Search API when a song has none of its own; lyrics come from LRCLIB. Missing songs come from the Soulseek folder an album was downloaded from, or from MusicBrainz otherwise.")
                }

                Section {
                    LabeledContent("Music", value: "Seekios › Music")
                    LabeledContent("Videos & Files", value: "Seekios › Downloads")
                    Picker("Downloads Subfolders", selection: folderStructure) {
                        ForEach(DownloadFolderStructure.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    Button {
                        showDownloadsFolderSheet = true
                    } label: {
                        Label("Browse Downloaded Files", systemImage: "folder.badge.magnifyingglass")
                    }
                } header: {
                    Text("App Folders")
                } footer: {
                    Text("Audio goes straight to your Library in On My iPhone › Seekios › Music. Videos and other files are saved to On My iPhone › Seekios › Downloads (\((DownloadFolderStructure(rawValue: folderStructureRaw) ?? .album).example)) and are visible in the iOS Files app.")
                }

                Section {
                    Toggle("Keep Transfers Running in Background", isOn: $backgroundTransfers)
                    Toggle("Show Transfers in Dynamic Island", isOn: $transferActivity)
                    Button {
                        router.showWiFiTransfer = true
                    } label: {
                        HStack {
                            Label("Wi-Fi Transfer", systemImage: "wifi")
                            Spacer()
                            if server.isRunning {
                                Text("On").foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Background & Transfer Tools")
                } footer: {
                    Text("Plays silent audio when no music is playing so iOS doesn't freeze sideloaded transfers in the background. Lock Screen controls remain intact when music is paused.")
                }

                Section {
                    LabeledContent("Songs", value: "\(library.tracks.count)")
                    LabeledContent("Albums", value: "\(library.albums.count)")
                    if let storage {
                        LabeledContent("Music Library", value: Formatting.bytes(storage.musicBytes))
                        if storage.downloadsBytes > 0 {
                            LabeledContent("Other Downloads", value: Formatting.bytes(storage.downloadsBytes))
                        }
                        LabeledContent("Incomplete Partials", value: "\(Formatting.bytes(storage.incompleteBytes)) (\(storage.incompleteCount))")
                        LabeledContent("Artwork Cache", value: Formatting.bytes(storage.artworkCacheBytes))
                    }
                    Button("Rescan Library") { library.rescan() }
                    Button("Clean Orphaned Partial Files") {
                        Task {
                            let removed = await soulseek.cleanOrphanedPartials()
                            cleanupMessage = removed == 0 ? "No orphaned partial files found." : "Removed \(removed) orphaned partial file\(removed == 1 ? "" : "s")."
                            storage = await soulseek.computeStorageBreakdown()
                        }
                    }
                    Button("Clear Artwork Cache") {
                        Task {
                            await ArtworkStore.shared.clearDisk()
                            library.bumpArtwork()
                            storage = await soulseek.computeStorageBreakdown()
                        }
                    }
                    if let cleanupMessage {
                        Text(cleanupMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Library & Storage")
                }

                Section {
                    NavigationLink("Diagnostics & Logs") { DiagnosticsView() }
                    NavigationLink("Connection Log") { LogView() }
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(isPresented: $router.showWiFiTransfer) { WiFiTransferView() }
            .sheet(isPresented: $showDownloadsFolderSheet) {
                NavigationStack {
                    LocalFolderBrowserView(folderURL: soulseek.otherDownloadsDirectory)
                }
            }
            .sheet(isPresented: $showPeersSheet) {
                PeersManagerSheet()
            }
            .onAppear {
                if !didSeedUsername {
                    didSeedUsername = true
                    username = soulseek.username
                }
            }
            .task {
                storage = await soulseek.computeStorageBreakdown()
            }
        }
    }

    private var soulseekSection: some View {
        Section {
            if soulseek.isLoggedIn {
                Label("Logged in as \(soulseek.username)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                ConnectionBanner()
            }
            if !soulseek.isLoggedIn && soulseek.hasCredentials {
                Button("Reconnect as \(soulseek.username)") {
                    soulseek.reconnectIfNeeded()
                }
                .fontWeight(.semibold)
            }
            TextField("Username", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password", text: $password)
            Button(soulseek.isLoggedIn ? "Switch Account / Reconnect" : "Log In") {
                soulseek.logIn(username: username, password: password)
                password = ""
            }
            .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
            if soulseek.isLoggedIn {
                Button("Disconnect", role: .destructive) { soulseek.logOut() }
            }
        } header: {
            Text("Soulseek Account")
        } footer: {
            Text("Logging in with an unused username registers it. There's no password reset, so pick something you'll remember.")
        }
    }
}

private struct EqualizerSettingsRow: View {
    @ObservedObject var equalizer: Equalizer
    let bitPerfect: Bool

    var body: some View {
        LabeledContent(
            "Equalizer",
            value: bitPerfect ? "Bypassed" : (equalizer.isEnabled ? equalizer.displayName : "Off")
        )
    }
}

struct BitPerfectStatus: View {
    @EnvironmentObject private var player: Player

    var body: some View {
        let output = player.output
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Output", value: output.routeName.isEmpty ? "–" : output.routeName)
            LabeledContent("Hardware Rate", value: Formatting.sampleRate(output.hardwareRate))
            if output.fileRate > 0 {
                LabeledContent("Song Rate", value: Formatting.sampleRate(output.fileRate))
            }
            if player.current != nil {
                if output.isBitPerfect(enabled: true) {
                    Label("Bit-perfect", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else if let reason = output.blocker(enabled: true) {
                    Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
        }
        .font(.subheadline)
        .onAppear { player.refreshOutputInfo() }
    }
}

struct LogView: View {
    @EnvironmentObject private var soulseek: SoulseekModel

    var body: some View {
        List(soulseek.logLines.reversed()) { entry in
            Text(entry.text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        .navigationTitle("Connection Log")
        .navigationBarTitleDisplayMode(.inline)
    }
}
