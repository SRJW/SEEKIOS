import SwiftUI
import UIKit

struct WiFiTransferView: View {
    @EnvironmentObject private var server: WiFiTransferServer
    @State private var userStopped = false
    @State private var copied = false

    var body: some View {
        List {
            Section {
                Toggle("Wi-Fi Transfer", isOn: Binding(
                    get: { server.isRunning },
                    set: { enabled in
                        userStopped = !enabled
                        if enabled { server.start() } else { server.stop() }
                    }
                ))
            } footer: {
                Text("Open the address in a browser on a computer on the same Wi-Fi to add music or download files. Keep this screen open while transferring.")
            }

            if server.isRunning, let address = server.address {
                Section("On your computer, open") {
                    Text(address)
                        .font(.title3.monospaced().weight(.semibold))
                        .textSelection(.enabled)
                    LabeledContent("Access Code") {
                        Text(server.accessCode)
                            .font(.title3.monospaced().weight(.bold))
                            .foregroundStyle(.tint)
                            .textSelection(.enabled)
                    }
                    if let url = server.url {
                        Button {
                            UIPasteboard.general.string = url
                            copied = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                copied = false
                            }
                        } label: {
                            Label(copied ? "Copied!" : "Copy Link with Code",
                                  systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        ShareLink(item: url) {
                            Label("Send Link to Computer…", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button("New Access Code") { server.newCode() }
                }
            }

            if let error = server.lastError {
                Section {
                    Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
                }
            }

            if !server.log.isEmpty {
                Section("Activity") {
                    ForEach(server.log) { entry in
                        Text(entry.text).font(.caption.monospaced()).lineLimit(2)
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Seekios's Music folder is also shared over a cable:")
                    Text("• Mac: Finder › iPhone › Files › Seekios\n• Windows: Apple Devices app › Files\n• Linux: libimobiledevice + ifuse")
                        .foregroundStyle(.secondary)
                    Text("ifuse --documents com.srjw.seekios ~/iphone")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                .font(.subheadline)
                .padding(.vertical, 4)
            } header: {
                Text("Wired")
            } footer: {
                Text("Wired needs the iPhone to trust the computer. After copying files in, pull down on the library or tap Rescan.")
            }
        }
        .navigationTitle("Wi-Fi Transfer")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !userStopped, !server.isRunning {
                server.start()
            }
            UIApplication.shared.isIdleTimerDisabled = server.isRunning
        }
        .onChange(of: server.isRunning) { _, running in
            UIApplication.shared.isIdleTimerDisabled = running
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}
