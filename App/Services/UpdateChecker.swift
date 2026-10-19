import Foundation
import SwiftUI

@MainActor
final class UpdateChecker: ObservableObject {
    enum Channel: String, CaseIterable, Identifiable {
        case stable, beta
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    struct Remote: Equatable {
        var version: String = ""
        var build: Int = 0
        var builtDate: Date? = nil
        var size: Int64? = nil
        var cleanNotes: String = ""
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Remote)
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var channel: Channel = .stable
    @Published var automatic: Bool = false
    @Published var lastChecked: Date? = nil

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var builtChannel: Channel { .stable }
    var source: String { "github.com/SRJW/SEEKIOS" }

    /// Propiedades que Colon3App.swift y ContentView.swift consultan
    var hasUpdate: Bool { false }
    var isUpdateAvailable: Bool { false }
    var availableUpdate: Remote? { nil }

    init() {}

    func checkForUpdate() async {}
    func checkIfNeeded() async {}
    func check() async {}
    func install(_ remote: Remote) {}
    func openPage() {
        if let url = URL(string: "https://github.com/SRJW/SEEKIOS/releases") {
            UIApplication.shared.open(url)
        }
    }
}
