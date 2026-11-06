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

    @State private var username = ""
    @State private var password = ""
    @State private var showFolderPicker = false
    @State private var showDownloadsFolderSheet = false

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

                Section("Accent Colour") {
                    AccentPicker()
                }

                Section {
                    NavigationLink {
                        EqualizerView(equalizer: player.equalizer)
                    } label: {
                        LabeledContent("Equalizer", value: player.bitPerfect ? "Bypassed"
                                       : (player.equalizer.isEnabled ? player.equalizer.displayName : "Off"))
                    }
                    Toggle("Bit-Perfect Mode", isOn: $player.bitPerfect)
                    if player.bitPerfect {
                        BitPerfectStatus()
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    Text("For USB DACs: switches the output to each song's sample rate and skips the EQ and all volume processing, so the DAC gets the file's exact samples. Turn the iPhone volume all the way up and use the DAC's volume. Bluetooth, AirPlay and the speaker can't be bit-perfect.")
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
                    HStack {
                        Label("Download Folder", systemImage: "folder.fill")
                        Spacer()
                        Text(soulseek.currentDownloadFolderDisplayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Button {
                        showFolderPicker = true
                    } label: {
                        Label("Choose Where to Save Downloads…", systemImage: "folder.badge.gearshape")
                    }
                    Button {
                        showDownloadsFolderSheet = true
                    } label: {
                        Label("Show Downloads Folder", systemImage: "folder.badge.magnifyingglass")
                    }
                    if soulseek.customDownloadDirectory != nil {
                        Toggle("Also Save Music to Chosen Folder", isOn: $soulseek.saveAllToCustomFolder)
                        Button("Reset Download Folder to Default", role: .destructive) {
                            soulseek.resetDownloadFolderToDefault()
                        }
                    }
                } header: {
                    Text("Download Location")
                } footer: {
                    Text("Choose any folder in On My iPhone or iCloud Drive to automatically store downloaded files.")
                }

                Section {
                    Toggle("Keep Transfers Running in Background", isOn: $backgroundTransfers)
                    Toggle("Show Transfers in Dynamic Island", isOn: $transferActivity)
                    Toggle("Seeding Mode", isOn: $seeding)
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
                    Text("Transfers")
                } footer: {
                    Text("When nothing is playing, Seekios plays silence (mixed under other audio) so iOS doesn't freeze transfers in the background, like iTorrent does. It costs some battery and stops when transfers finish. Seeding Mode keeps it running all the time so people can keep downloading from you, and reconnects if Soulseek drops.")
                }

                Section {
                    LabeledContent("Songs", value: "\(library.tracks.count)")
                    LabeledContent("Albums", value: "\(library.albums.count)")
                    Button("Rescan Library") { library.rescan() }
                    Button("Clear Artwork Cache") {
                        Task {
                            await ArtworkStore.shared.clearDisk()
                            library.bumpArtwork()
                        }
                    }
                } header: {
                    Text("Library")
                } footer: {
                    Text("Your music is also shared back on Soulseek while the app runs, so peers don't treat you as a leecher.")
                }

                Section {
                    NavigationLink("Diagnostics & Logs") { DiagnosticsView() }
                    NavigationLink("Connection Log") { LogView() }
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(isPresented: $router.showWiFiTransfer) { WiFiTransferView() }
            .sheet(isPresented: $showFolderPicker) {
                FolderDocumentPicker { pickedURL in
                    soulseek.setCustomDownloadFolder(pickedURL)
                }
            }
            .sheet(isPresented: $showDownloadsFolderSheet) {
                NavigationStack {
                    LocalFolderBrowserView(folderURL: soulseek.otherDownloadsDirectory)
                }
            }
            .onAppear { username = soulseek.username }
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
            TextField("Username", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password", text: $password)
            Button(soulseek.isLoggedIn ? "Reconnect" : "Log In") {
                soulseek.logIn(username: username, password: password)
                password = ""
            }
            .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
            if soulseek.isLoggedIn {
                Button("Disconnect", role: .destructive) { soulseek.logOut() }
            }
        } header: {
            Text("Soulseek")
        } footer: {
            Text("Logging in with an unused username registers it. There's no password reset, so pick something you'll remember.")
        }
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
        List(Array(soulseek.logLines.indices.reversed()), id: \.self) { index in
            Text(soulseek.logLines[index])
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        .navigationTitle("Log")
        .navigationBarTitleDisplayMode(.inline)
    }
}
