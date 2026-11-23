import Combine
import SwiftUI

/// Settings › Diagnostics & Logs: the live session log and any crash reports, with share and clear.
struct DiagnosticsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case log = "Log", crashes = "Crashes"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .log
    @State private var entries: [Diagnostics.LogLine] = []
    @State private var crashes: [Diagnostics.CrashReport] = []
    @State private var follow = true
    @State private var share: ExportFile?
    @State private var confirmClear = false

    private let logUpdates = Diagnostics.shared.didLog
        .throttle(for: .milliseconds(500), scheduler: RunLoop.main, latest: true)

    private var canShare: Bool {
        tab == .log ? !entries.isEmpty : !crashes.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab == .crashes && !crashes.isEmpty ? "Crashes (\(crashes.count))" : tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            switch tab {
            case .log: logList
            case .crashes: crashList
            }
        }
        .navigationTitle("Diagnostics & Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if tab == .log {
                    Button {
                        follow.toggle()
                    } label: {
                        Image(systemName: follow ? "arrow.down.circle.fill" : "arrow.down.circle")
                    }
                    .accessibilityLabel(follow ? "Auto-scroll on" : "Auto-scroll off")
                }
                Button {
                    shareCurrent()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(!canShare)
                Menu {
                    Button(role: .destructive) { confirmClear = true } label: {
                        Label(tab == .log ? "Clear Log" : "Delete Crash Reports", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(tab == .log ? "Clear the session log?" : "Delete all crash reports?",
                            isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if tab == .log { Diagnostics.shared.clearSession() } else { Diagnostics.shared.clearCrashes() }
                reload()
            }
        }
        .sheet(item: $share) { file in
            ActivityView(items: [file.url]).presentationDetents([.medium, .large])
        }
        .onReceive(logUpdates) { _ in
            if tab == .log { entries = Diagnostics.shared.entries }
        }
        .onAppear(perform: reload)
        .onChange(of: tab) { _, _ in reload() }
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(entries) { entry in
                    Text(entry.text)
                        .font(.caption2.monospaced())
                        .foregroundStyle(color(for: entry.text))
                        .textSelection(.enabled)
                        .listRowSeparator(.hidden)
                }
                Color.clear.frame(height: 1).id("log-bottom")
            }
            .listStyle(.plain)
            .overlay {
                if entries.isEmpty {
                    Text("No log yet.").foregroundStyle(.secondary)
                }
            }
            .onChange(of: entries.last?.id) { _, _ in
                if follow {
                    withAnimation { proxy.scrollTo("log-bottom", anchor: .bottom) }
                }
            }
            .onChange(of: follow) { _, enabled in
                if enabled {
                    withAnimation { proxy.scrollTo("log-bottom", anchor: .bottom) }
                }
            }
            .onAppear {
                if follow { proxy.scrollTo("log-bottom", anchor: .bottom) }
            }
        }
    }

    private var crashList: some View {
        List {
            if crashes.isEmpty {
                Text("No crashes recorded. 🎉").foregroundStyle(.secondary)
            }
            ForEach(crashes) { report in
                NavigationLink {
                    CrashDetailView(report: report)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.title)
                        Text(report.kind == "MetricKit" ? "Full diagnostic from iOS" : "Captured in-app")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func color(for line: String) -> Color {
        let lower = line.lowercased()
        if lower.contains("error") || lower.contains("failed") || lower.contains("[crash]") { return .red }
        if lower.contains("warning") { return .orange }
        return .primary
    }

    private func reload() {
        entries = Diagnostics.shared.entries
        crashes = Diagnostics.shared.crashReports()
    }

    private func shareCurrent() {
        if tab == .log {
            guard !entries.isEmpty else { return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("seekios-log.txt")
            try? Diagnostics.shared.exportSessionText().data(using: .utf8)?.write(to: url, options: .atomic)
            share = ExportFile(url: url)
        } else if let first = crashes.first {
            share = ExportFile(url: first.url)
        }
    }
}

struct CrashDetailView: View {
    let report: Diagnostics.CrashReport
    @State private var text: String?
    @State private var share: ExportFile?

    var body: some View {
        ScrollView {
            if let text {
                Text(text)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
            }
        }
        .navigationTitle(report.kind)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    share = ExportFile(url: report.url)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(item: $share) { file in
            ActivityView(items: [file.url]).presentationDetents([.medium, .large])
        }
        .task(id: report.id) {
            let url = report.url
            let loaded = await Task.detached(priority: .userInitiated) {
                (try? String(contentsOf: url, encoding: .utf8)) ?? "Couldn't read this report."
            }.value
            text = loaded
        }
    }
}
