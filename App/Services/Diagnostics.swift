import Combine
import Foundation
import MetricKit
import UIKit

/// App-wide logging and crash capture, all kept on the phone. A rolling in-memory buffer feeds
/// the Logs screen; the same lines are appended to a session file. MetricKit delivers reliable
/// crash diagnostics on the next launch without unsafe POSIX signal handlers.
final class Diagnostics: NSObject, @unchecked Sendable {
    static let shared = Diagnostics()

    struct LogLine: Identifiable, Hashable, Sendable {
        let id: Int
        let text: String
    }

    /// Fires on the main queue when new lines arrive, so an open Logs screen can refresh.
    let didLog = PassthroughSubject<Void, Never>()

    private let lock = NSLock()
    private var buffer: [LogLine] = []
    private var nextLineID = 1
    private var isStarted = false
    private let maxLines = 3000
    private let maxSessionFileBytes: UInt64 = 3 * 1024 * 1024
    private let writeQueue = DispatchQueue(label: "seekios.diagnostics")
    private var sessionHandle: FileHandle?
    private var sessionBytesWritten: UInt64 = 0

    let logsDirectory: URL
    let crashesDirectory: URL
    private let sessionFile: URL

    /// Protected by `lock`.
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private override init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
        var crashes = AppDirectories.applicationSupport
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("Crashes", isDirectory: true)
        logsDirectory = caches
        crashesDirectory = crashes
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: crashes, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? crashes.setResourceValues(values)
        sessionFile = caches.appendingPathComponent("session.log")
        super.init()
    }

    /// Call once, early. Opens the session file and registers MetricKit.
    func start() {
        lock.lock()
        if isStarted {
            lock.unlock()
            return
        }
        isStarted = true
        lock.unlock()

        writeQueue.sync {
            let fm = FileManager.default
            try? fm.createDirectory(at: self.logsDirectory, withIntermediateDirectories: true)
            let previous = self.logsDirectory.appendingPathComponent("session-previous.log")
            try? fm.removeItem(at: previous)
            if fm.fileExists(atPath: self.sessionFile.path) {
                try? fm.moveItem(at: self.sessionFile, to: previous)
            }
            fm.createFile(atPath: self.sessionFile.path, contents: nil)
            self.sessionHandle = try? FileHandle(forWritingTo: self.sessionFile)
            self.sessionBytesWritten = 0
        }

        let device = UIDevice.current
        log("Seekios \(Bundle.appVersion) on \(device.systemName) \(device.systemVersion)", category: "app")
        MXMetricManager.shared.add(self)
    }

    // MARK: Logging

    func log(_ message: String, category: String = "app") {
        lock.lock()
        let timestamp = Self.stamp.string(from: Date())
        let formatted = "\(timestamp) [\(category)] \(message)"
        let entry = LogLine(id: nextLineID, text: formatted)
        nextLineID += 1
        buffer.append(entry)
        if buffer.count > maxLines {
            buffer.removeFirst(buffer.count - maxLines)
        }
        lock.unlock()

        writeQueue.async { [weak self] in
            self?.appendToSessionFile(formatted + "\n")
        }
        DispatchQueue.main.async { [weak self] in
            self?.didLog.send()
        }
    }

    private func appendToSessionFile(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if sessionBytesWritten + UInt64(data.count) > maxSessionFileBytes {
            rotateSessionFile()
        }
        guard let handle = sessionHandle else { return }
        do {
            try handle.write(contentsOf: data)
            sessionBytesWritten += UInt64(data.count)
        } catch {
            // Disk full or closed fd: close handle safely instead of raising Obj-C NSException.
            try? handle.close()
            sessionHandle = nil
        }
    }

    private func rotateSessionFile() {
        try? sessionHandle?.close()
        sessionHandle = nil
        let fm = FileManager.default
        let previous = logsDirectory.appendingPathComponent("session-previous.log")
        try? fm.removeItem(at: previous)
        try? fm.moveItem(at: sessionFile, to: previous)
        fm.createFile(atPath: sessionFile.path, contents: nil)
        sessionHandle = try? FileHandle(forWritingTo: sessionFile)
        sessionBytesWritten = 0
    }

    var entries: [LogLine] {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    var lines: [String] {
        entries.map(\.text)
    }

    func clearSession() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
        writeQueue.async { [weak self] in
            guard let self, let handle = self.sessionHandle else { return }
            do {
                try handle.truncate(atOffset: 0)
                try handle.seek(toOffset: 0)
                self.sessionBytesWritten = 0
            } catch {
                try? handle.close()
                self.sessionHandle = nil
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.didLog.send()
        }
    }

    /// The whole session log as text, for sharing.
    func exportSessionText() -> String {
        lines.joined(separator: "\n")
    }

    // MARK: Crash reports

    struct CrashReport: Identifiable {
        let url: URL
        let date: Date
        let kind: String
        var id: String { url.lastPathComponent }
        var title: String {
            DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short) + " · " + kind
        }
    }

    func crashReports() -> [CrashReport] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: crashesDirectory, includingPropertiesForKeys: keys)) ?? []
        return files
            .filter { $0.pathExtension == "txt" || $0.pathExtension == "json" }
            .map { url in
                let date = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
                let kind = url.pathExtension == "json" ? "MetricKit" : "Crash"
                return CrashReport(url: url, date: date, kind: kind)
            }
            .sorted { $0.date > $1.date }
    }

    func readCrash(_ report: CrashReport) -> String {
        (try? String(contentsOf: report.url, encoding: .utf8)) ?? "Couldn't read this report."
    }

    func clearCrashes() {
        for file in (try? FileManager.default.contentsOfDirectory(at: crashesDirectory, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

extension Diagnostics: MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXMetricPayload]) {}

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads where !payload.crashDiagnostics.isNilOrEmpty {
            let date = payload.timeStampEnd
            let suffix = UUID().uuidString.prefix(8)
            let name = "metrickit-\(Int(date.timeIntervalSince1970))-\(suffix).json"
            try? FileManager.default.createDirectory(at: crashesDirectory, withIntermediateDirectories: true)
            try? payload.jsonRepresentation().write(to: crashesDirectory.appendingPathComponent(name), options: .atomic)
        }
    }
}

private extension Optional where Wrapped == [MXCrashDiagnostic] {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}

extension Bundle {
    static var appVersion: String {
        let version = main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(version) (\(build))"
    }
}
