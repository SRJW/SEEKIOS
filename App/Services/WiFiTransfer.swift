import Foundation
import Network
import UIKit

/// Wi-Fi Transfer: a small web server on the phone, like VLC's "Sharing via WiFi". Open the
/// address on a computer on the same network to drop music in or pull files out. Every request
/// needs the access code shown in the app, so other people on the network can't browse.
@MainActor
final class WiFiTransferServer: ObservableObject {
    struct LogEntry: Identifiable, Hashable {
        let id = UUID()
        let text: String
    }

    @Published private(set) var isRunning = false
    @Published private(set) var address: String?
    @Published private(set) var accessCode = WiFiTransferServer.makeCode()
    @Published private(set) var log: [LogEntry] = []
    @Published private(set) var lastError: String?

    /// Called (debounced) after files were added or removed.
    var onFilesChanged: (() -> Void)?

    private let root: URL
    private let queue = DispatchQueue(label: "seekios.wifi-transfer")
    private let ioQueue = DispatchQueue(label: "seekios.wifi-transfer.io", qos: .userInitiated, attributes: .concurrent)
    private var listener: NWListener?
    private let sessionRegistry = SessionRegistry()
    private var rescanPending = false

    init(root: URL) {
        self.root = root
    }

    var url: String? {
        address.map { "\($0)/?k=\(accessCode)" }
    }

    func start() {
        guard listener == nil else { return }
        lastError = nil
        let deviceName = UIDevice.current.name
        openListener(port: NWEndpoint.Port(rawValue: 8080)!, deviceName: deviceName)
    }

    /// Tries 8080 first (easy to type), then any free port.
    private func openListener(port: NWEndpoint.Port?, deviceName: String) {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let made: NWListener?
        if let port {
            made = try? NWListener(using: parameters, on: port)
        } else {
            made = try? NWListener(using: parameters)
        }
        guard let listener = made else {
            if port != nil { return openListener(port: nil, deviceName: deviceName) }
            lastError = "Couldn't open a port."
            return
        }
        self.listener = listener
        let root = self.root
        let code = accessCode
        let queue = self.queue
        let ioQueue = self.ioQueue
        let registry = self.sessionRegistry

        listener.newConnectionHandler = { [weak self] connection in
            let session = HTTPSession(
                connection: connection,
                root: root,
                code: code,
                deviceName: deviceName,
                queue: queue,
                ioQueue: ioQueue,
                registry: registry
            ) { event in
                Task { @MainActor in self?.handle(event) }
            }
            if registry.register(session) {
                session.start()
            } else {
                connection.cancel()
            }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    if let ip = Self.localIPv4(), let port = listener.port {
                        self.address = "http://\(ip):\(port.rawValue)"
                        self.lastError = nil
                        self.isRunning = true
                    } else {
                        self.address = nil
                        self.lastError = "Connect to Wi-Fi (or turn on Personal Hotspot) first."
                        self.isRunning = false
                    }
                case let .waiting(error):
                    self.lastError = "Waiting for local network permission: \(error.localizedDescription)"
                    self.isRunning = false
                case let .failed(error):
                    listener.cancel()
                    self.listener = nil
                    if port != nil {
                        self.openListener(port: nil, deviceName: deviceName)  // 8080 taken: use any port
                    } else {
                        self.lastError = error.localizedDescription
                        self.isRunning = false
                    }
                case .cancelled:
                    self.listener = nil
                    self.isRunning = false
                default:
                    break
                }
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        sessionRegistry.cancelAll()
        isRunning = false
        address = nil
    }

    func newCode() {
        accessCode = Self.makeCode()
        sessionRegistry.resetAuthFailures()
        if listener != nil {
            stop()
            start()
        }
    }

    private func handle(_ event: HTTPSession.Event) {
        switch event {
        case let .log(line):
            log.insert(LogEntry(text: Formatting.time.string(from: Date()) + "  " + line), at: 0)
            if log.count > 30 { log.removeLast(log.count - 30) }
        case .filesChanged:
            guard !rescanPending else { return }
            rescanPending = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.rescanPending = false
                self.onFilesChanged?()
            }
        }
    }

    private static func makeCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }

    /// The phone's address on Wi-Fi (en0) or its own hotspot (bridge*).
    nonisolated static func localIPv4() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var found: [String: String] = [:]
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = entry.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                found[name] = String(cString: host)
            }
        }
        return found["en0"] ?? found.first(where: { $0.key.hasPrefix("bridge") })?.value
            ?? found.first(where: { $0.key.hasPrefix("en") })?.value
    }
}

private final class SessionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [ObjectIdentifier: HTTPSession] = [:]
    private let maxSessions = 16
    private var failedAttempts = 0
    private var lockedUntil = Date.distantPast

    func register(_ session: HTTPSession) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard sessions.count < maxSessions else { return false }
        sessions[ObjectIdentifier(session)] = session
        return true
    }

    func unregister(_ session: HTTPSession) {
        lock.lock(); defer { lock.unlock() }
        sessions.removeValue(forKey: ObjectIdentifier(session))
    }

    func cancelAll() {
        lock.lock()
        let active = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        active.forEach { $0.forceCancel() }
    }

    func isAuthLocked() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return Date() < lockedUntil
    }

    func recordAuthFailure() {
        lock.lock(); defer { lock.unlock() }
        failedAttempts += 1
        if failedAttempts >= 5 {
            let backoff = min(Double(1 << min(failedAttempts - 5, 5)) * 5.0, 120.0)
            lockedUntil = Date().addingTimeInterval(backoff)
        }
    }

    func resetAuthFailures() {
        lock.lock(); defer { lock.unlock() }
        failedAttempts = 0
        lockedUntil = Date.distantPast
    }
}

/// One HTTP/1.1 request per connection (Connection: close keeps it simple).
private final class HTTPSession: @unchecked Sendable {
    enum Event {
        case log(String)
        case filesChanged
    }

    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
    }

    private let connection: NWConnection
    private let root: URL
    private let code: String
    private let deviceName: String
    private let queue: DispatchQueue
    private let ioQueue: DispatchQueue
    private let registry: SessionRegistry
    private let onEvent: (Event) -> Void
    private var buffer = Data()
    private var idleTimer: DispatchSourceTimer?
    private var isFinished = false
    private var activeTempFile: URL?
    private var activeUploadHandle: FileHandle?

    private static let allowedExtensions = LibraryStore.audioExtensions.union(LibraryStore.sidecarExtensions)
    private static let maxUploadBytes = 2 * 1024 * 1024 * 1024  // 2 GiB safety cap

    init(
        connection: NWConnection,
        root: URL,
        code: String,
        deviceName: String,
        queue: DispatchQueue,
        ioQueue: DispatchQueue,
        registry: SessionRegistry,
        onEvent: @escaping (Event) -> Void
    ) {
        self.connection = connection
        self.root = root
        self.code = code
        self.deviceName = deviceName
        self.queue = queue
        self.ioQueue = ioQueue
        self.registry = registry
        self.onEvent = onEvent
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        resetIdleTimer()
        connection.start(queue: queue)
        readHead()
    }

    func forceCancel() {
        queue.async { [weak self] in
            self?.finish()
        }
    }

    private func resetIdleTimer() {
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30)
        timer.setEventHandler { [weak self] in
            self?.finish()
        }
        timer.resume()
        idleTimer = timer
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        idleTimer?.cancel()
        idleTimer = nil
        if let handle = activeUploadHandle {
            try? handle.close()
            activeUploadHandle = nil
        }
        if let temp = activeTempFile {
            try? FileManager.default.removeItem(at: temp)
            activeTempFile = nil
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
        registry.unregister(self)
    }

    // MARK: Parsing

    private func readHead() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.isFinished else { return }
            self.resetIdleTimer()
            if let data { self.buffer.append(data) }
            if let end = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: self.buffer[..<end.lowerBound], as: UTF8.self)
                let rest = Data(self.buffer[end.upperBound...])
                self.buffer = Data()
                guard let request = Self.parse(head) else { return self.respond(400, text: "Bad request") }
                self.route(request, body: rest)
            } else if self.buffer.count > 32 * 1024 {
                self.respond(431, text: "Headers too large")
            } else if isComplete || error != nil {
                self.finish()
            } else {
                self.readHead()
            }
        }
    }

    private static func parse(_ head: String) -> Request? {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let target = String(parts[1])
        let pieces = target.split(separator: "?", maxSplits: 1).map(String.init)
        var query: [String: String] = [:]
        if pieces.count == 2 {
            for pair in pieces[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                let key = kv[0].removingPercentEncoding ?? kv[0]
                query[key] = kv.count > 1 ? (kv[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? kv[1]) : ""
            }
        }
        let path = pieces[0].removingPercentEncoding ?? pieces[0]
        return Request(method: String(parts[0]).uppercased(), path: path, query: query, headers: headers)
    }

    // MARK: Auth & Routing

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    private func isCookieAuthorized(_ request: Request) -> Bool {
        let cookies = request.headers["cookie"] ?? ""
        for part in cookies.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("c3k=") {
                let value = String(trimmed.dropFirst(4))
                if Self.constantTimeEqual(value, code) { return true }
            }
        }
        return false
    }

    private func route(_ request: Request, body: Data) {
        if request.method == "POST", request.path == "/login" {
            handleLogin(request: request, body: body)
            return
        }

        let cookieAuth = isCookieAuthorized(request)
        let queryCode = request.query["k"]?.uppercased()
        let queryAuth: Bool = {
            guard let queryCode, !registry.isAuthLocked() else { return false }
            let ok = Self.constantTimeEqual(queryCode, code)
            if ok { registry.resetAuthFailures() } else { registry.recordAuthFailure() }
            return ok
        }()
        let authorized = cookieAuth || queryAuth

        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            if queryAuth && !cookieAuth {
                // Set HttpOnly cookie and redirect to "/" so the code doesn't linger in browser URL/history.
                let head = Self.head(303, headers: [
                    "Location": "/",
                    "Set-Cookie": "c3k=\(code); Path=/; HttpOnly; SameSite=Strict; Max-Age=86400",
                    "Content-Length": "0",
                ])
                connection.send(content: head, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { [weak self] _ in self?.finish() })
                return
            }
            if authorized {
                respond(200, contentType: "text/html; charset=utf-8", body: Data(WebPage.html.utf8),
                        extraHeaders: ["Set-Cookie": "c3k=\(code); Path=/; HttpOnly; SameSite=Strict; Max-Age=86400"])
            } else {
                let locked = registry.isAuthLocked()
                respond(queryCode == nil ? 200 : (locked ? 429 : 403), contentType: "text/html; charset=utf-8",
                        body: Data(WebPage.login(failed: queryCode != nil, locked: locked).utf8))
            }
            return
        case ("GET", "/favicon.ico"):
            respond(404, text: "")
            return
        default:
            break
        }
        guard authorized else { return respond(401, text: "Enter the access code shown in Seekios.") }

        if request.method == "GET", request.path == "/api/list" {
            ioQueue.async { [weak self] in
                guard let self else { return }
                let data = self.listing()
                self.queue.async { [weak self] in
                    guard let self, !self.isFinished else { return }
                    self.respond(200, contentType: "application/json", body: data)
                }
            }
            return
        }
        guard request.path.hasPrefix("/file/") else { return respond(404, text: "Not found") }
        let relative = String(request.path.dropFirst("/file/".count))
        guard let target = safeURL(relative) else { return respond(400, text: "Bad path") }

        switch request.method {
        case "GET": download(target)
        case "PUT": upload(to: target, relative: relative, request: request, body: body)
        case "DELETE": delete(target, relative: relative)
        default: respond(405, text: "Method not allowed")
        }
    }

    private func handleLogin(request: Request, body: Data) {
        guard !registry.isAuthLocked() else {
            respond(429, contentType: "text/html; charset=utf-8", body: Data(WebPage.login(failed: true, locked: true).utf8))
            return
        }
        let expected = min(Int(request.headers["content-length"] ?? "") ?? body.count, 4096)
        var collected = body
        func process() {
            let text = String(decoding: collected.prefix(expected), as: UTF8.self)
            var submitted = ""
            for pair in text.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv[0] == "k", kv.count == 2 {
                    submitted = (kv[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? kv[1])
                        .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                }
            }
            if Self.constantTimeEqual(submitted, code) {
                registry.resetAuthFailures()
                let head = Self.head(303, headers: [
                    "Location": "/",
                    "Set-Cookie": "c3k=\(code); Path=/; HttpOnly; SameSite=Strict; Max-Age=86400",
                    "Content-Length": "0",
                ])
                connection.send(content: head, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { [weak self] _ in self?.finish() })
            } else {
                registry.recordAuthFailure()
                let locked = registry.isAuthLocked()
                respond(locked ? 429 : 403, contentType: "text/html; charset=utf-8",
                        body: Data(WebPage.login(failed: true, locked: locked).utf8))
            }
        }
        if collected.count >= expected {
            process()
        } else {
            connection.receive(minimumIncompleteLength: 1, maximumLength: expected - collected.count) { [weak self] data, _, _, _ in
                guard let self, !self.isFinished else { return }
                if let data { collected.append(data) }
                process()
            }
        }
    }

    /// Keeps every path inside the Music folder and to music-related files, resolving symlinks.
    private func safeURL(_ relative: String) -> URL? {
        let components = relative.split(separator: "/").map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") && !$0.contains("\0") }),
              let last = components.last,
              Self.allowedExtensions.contains((last as NSString).pathExtension.lowercased()) else { return nil }
        let url = components.reduce(root) { $0.appendingPathComponent($1) }
        let resolvedRoot = root.canonicalPath
        let resolvedTarget = url.canonicalPath
        let resolvedParent = url.deletingLastPathComponent().canonicalPath
        guard resolvedTarget.hasPrefix(resolvedRoot + "/"),
              resolvedParent == resolvedRoot || resolvedParent.hasPrefix(resolvedRoot + "/") else { return nil }
        return url
    }

    private func listing() -> Data {
        let rootPath = root.canonicalPath
        var files: [[String: Any]] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                guard Self.allowedExtensions.contains(url.pathExtension.lowercased()),
                      let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                let path = url.canonicalPath
                guard path.hasPrefix(rootPath + "/") else { continue }
                let relative = String(path.dropFirst(rootPath.count + 1))
                files.append([
                    "path": relative,
                    "size": values.fileSize ?? 0,
                    "modified": Int(values.contentModificationDate?.timeIntervalSince1970 ?? 0),
                ])
            }
        }
        let free = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let object: [String: Any] = ["files": files, "free": free, "device": deviceName]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    // MARK: Download

    private func download(_ url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else {
            return respond(404, text: "Not found")
        }
        let name = url.lastPathComponent
        // Printable ASCII only (excludes CR/LF/control chars, quotes and backslashes).
        let ascii = name.unicodeScalars.map { scalar -> String in
            let v = scalar.value
            if v >= 0x20 && v <= 0x7E && scalar != "\"" && scalar != "\\" {
                return String(scalar)
            }
            return "_"
        }.joined()
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/;,\r\n"))) ?? ascii
        let head = Self.head(200, headers: [
            "Content-Type": "application/octet-stream",
            "Content-Length": size.stringValue,
            "Content-Disposition": "attachment; filename=\"\(ascii)\"; filename*=UTF-8''\(encoded)",
        ])
        onEvent(.log("Sent \(name)"))
        connection.send(content: head, completion: .contentProcessed { [weak self] error in
            guard let self, !self.isFinished, error == nil else {
                try? handle.close()
                self?.finish()
                return
            }
            self.stream(handle)
        })
    }

    private func stream(_ handle: FileHandle) {
        guard !isFinished else { try? handle.close(); return }
        resetIdleTimer()
        let chunk: Data
        do {
            chunk = try autoreleasepool {
                try handle.read(upToCount: 256 * 1024) ?? Data()
            }
        } catch {
            try? handle.close()
            finish()
            return
        }
        guard !chunk.isEmpty else {
            try? handle.close()
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                self?.finish()
            })
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self, !self.isFinished, error == nil else {
                try? handle.close()
                self?.finish()
                return
            }
            self.stream(handle)
        })
    }

    // MARK: Upload

    private func upload(to target: URL, relative: String, request: Request, body: Data) {
        guard let lengthText = request.headers["content-length"], let length = Int(lengthText), length >= 0 else {
            return respond(411, text: "Content-Length required")
        }
        guard length <= Self.maxUploadBytes else {
            return respond(413, text: "File too large")
        }
        if let free = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage,
           Int64(length) > free - 32 * 1024 * 1024 {
            return respond(507, text: "Insufficient storage on iPhone")
        }

        if request.headers["expect"]?.lowercased().contains("100-continue") == true {
            connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
        }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("upload-" + UUID().uuidString)
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: temp) else {
            try? FileManager.default.removeItem(at: temp)
            return respond(500, text: "Can't write")
        }
        activeTempFile = temp
        activeUploadHandle = handle

        var written = 0
        let first = body.prefix(length)
        if !first.isEmpty {
            do {
                try handle.write(contentsOf: first)
                written = first.count
            } catch {
                return respond(507, text: "Couldn't write file (disk full?)")
            }
        }
        receiveUploadChunk(handle: handle, temp: temp, target: target, relative: relative, length: length, written: written)
    }

    private func receiveUploadChunk(handle: FileHandle, temp: URL, target: URL, relative: String, length: Int, written: Int) {
        guard !isFinished else { return }
        if written >= length {
            finishUpload(handle: handle, temp: temp, target: target, relative: relative)
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: min(1 << 20, length - written)) { [weak self] data, _, isComplete, error in
            guard let self, !self.isFinished else { return }
            self.resetIdleTimer()
            var nextWritten = written
            if let data, !data.isEmpty {
                do {
                    try handle.write(contentsOf: data)
                    nextWritten += data.count
                } catch {
                    self.respond(507, text: "Couldn't write file (disk full?)")
                    return
                }
            }
            if nextWritten >= length {
                self.finishUpload(handle: handle, temp: temp, target: target, relative: relative)
            } else if error != nil || isComplete {
                self.finish()
            } else {
                self.receiveUploadChunk(handle: handle, temp: temp, target: target, relative: relative, length: length, written: nextWritten)
            }
        }
    }

    private func finishUpload(handle: FileHandle, temp: URL, target: URL, relative: String) {
        try? handle.close()
        activeUploadHandle = nil
        ioQueue.async { [weak self] in
            guard let self else { return }
            let destination = self.placement(for: target, relative: relative)
            let fm = FileManager.default
            try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

            let result: (Int, String, Data?) = {
                do {
                    if destination.pathExtension.lowercased() == "lrc", fm.fileExists(atPath: destination.path) {
                        _ = try fm.replaceItemAt(destination, withItemAt: temp)
                        return (200, destination.lastPathComponent, Data("{\"ok\":true}".utf8))
                    }
                    let final = Self.unique(destination)
                    try fm.moveItem(at: temp, to: final)
                    return (200, final.lastPathComponent, Data("{\"ok\":true}".utf8))
                } catch {
                    try? fm.removeItem(at: temp)
                    return (500, "", nil)
                }
            }()

            self.queue.async { [weak self] in
                guard let self, !self.isFinished else { return }
                self.activeTempFile = nil
                if result.0 == 200, let payload = result.2 {
                    self.onEvent(.log("Received \(result.1)"))
                    self.onEvent(.filesChanged)
                    self.respond(200, contentType: "application/json", body: payload)
                } else {
                    self.respond(500, text: "Couldn't save the file")
                }
            }
        }
    }

    /// Loose files go into "Imported"; a loose .lrc goes next to the song with the same name.
    private func placement(for target: URL, relative: String) -> URL {
        guard !relative.contains("/") else { return target }
        if target.pathExtension.lowercased() == "lrc" {
            let base = target.deletingPathExtension().lastPathComponent.lowercased()
            if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for case let url as URL in enumerator
                where LibraryStore.audioExtensions.contains(url.pathExtension.lowercased())
                    && url.deletingPathExtension().lastPathComponent.lowercased() == base {
                    return url.deletingPathExtension().appendingPathExtension("lrc")
                }
            }
        }
        return root.appendingPathComponent("Imported", isDirectory: true).appendingPathComponent(target.lastPathComponent)
    }

    private static func unique(_ url: URL) -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 2
        while true {
            let candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) \(counter).\(ext)")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }

    // MARK: Delete

    private func delete(_ url: URL, relative: String) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return respond(404, text: "Not found") }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            return respond(500, text: "Couldn't delete")
        }
        // Remove folders left empty without ever escaping root.
        let resolvedRoot = root.canonicalPath
        var folder = url.deletingLastPathComponent()
        while true {
            let folderPath = folder.canonicalPath
            guard folderPath != resolvedRoot, folderPath.hasPrefix(resolvedRoot + "/") else { break }
            guard (try? fileManager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true else { break }
            try? fileManager.removeItem(at: folder)
            folder = folder.deletingLastPathComponent()
        }
        onEvent(.log("Deleted \(relative)"))
        onEvent(.filesChanged)
        respond(200, contentType: "application/json", body: Data("{\"ok\":true}".utf8))
    }

    // MARK: Responses

    private static func head(_ status: Int, headers: [String: String]) -> Data {
        let reason: [Int: String] = [
            200: "OK", 303: "See Other", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
            404: "Not Found", 405: "Method Not Allowed", 411: "Length Required", 413: "Payload Too Large",
            429: "Too Many Requests", 431: "Request Header Fields Too Large", 500: "Internal Server Error",
            507: "Insufficient Storage",
        ]
        var text = "HTTP/1.1 \(status) \(reason[status] ?? "OK")\r\n"
        var all = headers
        all["Connection"] = "close"
        all["Cache-Control"] = "no-store"
        for (key, value) in all { text += "\(key): \(value)\r\n" }
        return Data((text + "\r\n").utf8)
    }

    private func respond(_ status: Int, contentType: String = "text/plain; charset=utf-8", body: Data,
                         extraHeaders: [String: String] = [:]) {
        var headers = extraHeaders
        headers["Content-Type"] = contentType
        headers["Content-Length"] = String(body.count)
        connection.send(content: Self.head(status, headers: headers) + body, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in self?.finish() })
    }

    private func respond(_ status: Int, text: String) {
        respond(status, body: Data(text.utf8))
    }
}

private enum WebPage {
    static func login(failed: Bool, locked: Bool = false) -> String {
        let msg = locked
            ? "Too many attempts. Try again shortly."
            : (failed ? "That code didn't match." : "Enter the code shown on your iPhone.")
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Seekios</title><style>
        :root{color-scheme:light dark;--bg:#f5f5f7;--card:#fff;--fg:#1d1d1f;--muted:#6e6e73;--accent:#ff2d55}
        @media (prefers-color-scheme:dark){:root{--bg:#000;--card:#1c1c1e;--fg:#f5f5f7;--muted:#98989d}}
        body{margin:0;font:16px -apple-system,system-ui,sans-serif;background:var(--bg);color:var(--fg);display:grid;place-items:center;min-height:100vh}
        form{background:var(--card);padding:32px;border-radius:18px;text-align:center;max-width:320px;width:calc(100% - 32px);box-sizing:border-box}
        h1{margin:0 0 4px;font-size:28px}p{color:var(--muted);margin:0 0 20px}
        input{font:600 24px ui-monospace,monospace;letter-spacing:6px;text-transform:uppercase;text-align:center;width:100%;box-sizing:border-box;padding:12px;border-radius:12px;border:1px solid var(--muted);background:transparent;color:var(--fg)}
        button{margin-top:14px;width:100%;padding:12px;border:0;border-radius:12px;background:var(--accent);color:#fff;font:600 17px -apple-system,system-ui,sans-serif}
        .err{color:#ff3b30}</style></head><body>
        <form method="post" action="/login"><h1>Seekios</h1>
        <p class="\(failed || locked ? "err" : "")">\(msg)</p>
        <input name="k" maxlength="6" autocomplete="off" autofocus><button>Open</button></form></body></html>
        """
    }

    static let html = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Seekios Wi-Fi Transfer</title><style>
    :root{color-scheme:light dark;--bg:#f5f5f7;--card:#fff;--fg:#1d1d1f;--muted:#6e6e73;--line:#e5e5ea;--accent:#ff2d55}
    @media (prefers-color-scheme:dark){:root{--bg:#000;--card:#1c1c1e;--fg:#f5f5f7;--muted:#98989d;--line:#2c2c2e}}
    *{box-sizing:border-box}body{margin:0;font:15px -apple-system,system-ui,sans-serif;background:var(--bg);color:var(--fg)}
    main{max-width:900px;margin:0 auto;padding:24px 16px 80px}
    header{display:flex;align-items:baseline;gap:12px;flex-wrap:wrap;margin-bottom:16px}h1{margin:0;font-size:30px}
    .muted{color:var(--muted)}
    #drop{border:2px dashed var(--line);border-radius:18px;padding:28px 16px;text-align:center;background:var(--card);transition:.15s}
    #drop.over{border-color:var(--accent);background:color-mix(in srgb,var(--accent) 10%,var(--card))}
    #drop b{display:block;font-size:18px;margin-bottom:6px}
    .btn{display:inline-block;margin:10px 4px 0;padding:9px 16px;border-radius:999px;border:0;background:var(--accent);color:#fff;font:600 14px inherit;cursor:pointer}
    .btn.alt{background:transparent;color:var(--accent);border:1px solid var(--accent)}
    #queue{margin:12px 0 0;display:grid;gap:6px}.job{background:var(--card);border-radius:12px;padding:10px 12px}
    .job .name{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.bar{height:4px;border-radius:2px;background:var(--line);margin-top:6px;overflow:hidden}
    .bar i{display:block;height:100%;width:0;background:var(--accent)}.job.done .bar i{background:#34c759}.job.err .bar i{background:#ff3b30}
    .tools{display:flex;gap:10px;align-items:center;margin:26px 0 10px;flex-wrap:wrap}
    #filter{flex:1;min-width:200px;padding:10px 14px;border-radius:12px;border:1px solid var(--line);background:var(--card);color:var(--fg);font:inherit}
    details{background:var(--card);border-radius:14px;margin-bottom:8px;overflow:hidden}
    summary{padding:12px 14px;cursor:pointer;font-weight:600;display:flex;gap:8px}summary span{margin-left:auto;font-weight:400}
    .file{display:flex;align-items:center;gap:10px;padding:8px 14px;border-top:1px solid var(--line)}
    .file .n{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .file a,.file button{color:var(--accent);background:none;border:0;font:inherit;cursor:pointer;text-decoration:none;padding:4px}
    .file button{color:var(--muted)}.file button:hover{color:#ff3b30}
    </style></head><body><main>
    <header><h1>Seekios</h1><span class="muted" id="info">Wi-Fi Transfer</span></header>
    <div id="drop"><b>Drop music here</b><span class="muted">Files or whole album folders. Covers and .lrc lyrics come along.</span><br>
    <label class="btn">Choose Files<input type="file" id="files" multiple hidden></label>
    <label class="btn alt">Choose Folder<input type="file" id="folder" webkitdirectory hidden></label></div>
    <div id="queue"></div>
    <div class="tools"><input id="filter" placeholder="Filter your library"><span class="muted" id="count"></span></div>
    <div id="list"></div></main>
    <script>
    const allowed=/\\.(mp3|m4a|m4b|mp4|aac|alac|flac|wav|aif|aiff|caf|jpe?g|png|webp|heic|lrc)$/i;
    const enc=p=>p.split('/').map(encodeURIComponent).join('/');
    const size=b=>b>1e9?(b/1e9).toFixed(1)+' GB':b>1e6?(b/1e6).toFixed(1)+' MB':Math.round(b/1e3)+' KB';
    const esc=s=>s.replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
    let files=[],jobs=[],running=0;
    async function load(){const r=await fetch('/api/list');if(r.status==401){location='/';return}
      const j=await r.json();files=j.files;document.getElementById('info').textContent=j.device+' · '+size(j.free)+' free';render()}
    function render(){const q=document.getElementById('filter').value.toLowerCase();const groups={};
      for(const f of files){if(q&&!f.path.toLowerCase().includes(q))continue;const i=f.path.lastIndexOf('/');
        const dir=i<0?'(Music)':f.path.slice(0,i);(groups[dir]=groups[dir]||[]).push(f)}
      const dirs=Object.keys(groups).sort((a,b)=>a.localeCompare(b));let n=0;
      document.getElementById('list').innerHTML=dirs.map(d=>{const g=groups[d].sort((a,b)=>a.path.localeCompare(b.path,undefined,{numeric:true}));n+=g.length;
        return '<details'+(q?' open':'')+'><summary>'+esc(d)+'<span class="muted">'+g.length+' · '+size(g.reduce((s,f)=>s+f.size,0))+'</span></summary>'+
        g.map(f=>'<div class="file"><span class="n">'+esc(f.path.slice(f.path.lastIndexOf('/')+1))+'</span><span class="muted">'+size(f.size)+
        '</span><a href="/file/'+enc(f.path)+'" download>Download</a><button data-p="'+esc(f.path)+'">Delete</button></div>').join('')+'</details>'}).join('');
      document.getElementById('count').textContent=n+' files'}
    document.getElementById('list').addEventListener('click',async e=>{const p=e.target.dataset&&e.target.dataset.p;if(!p)return;
      if(!confirm('Delete '+p+' from the iPhone?'))return;await fetch('/file/'+enc(p),{method:'DELETE'});load()});
    document.getElementById('filter').oninput=render;
    function add(list){for(const {file,path} of list){if(!allowed.test(file.name))continue;
      const el=document.createElement('div');el.className='job';el.innerHTML='<div class="name">'+esc(path)+'</div><div class="bar"><i></i></div>';
      document.getElementById('queue').prepend(el);jobs.push({file,path,el})}pump()}
    function pump(){while(running<2&&jobs.length){const j=jobs.shift();running++;send(j).finally(()=>{running--;pump();if(!running&&!jobs.length)load()})}}
    function send(j){return new Promise(res=>{const x=new XMLHttpRequest();x.open('PUT','/file/'+enc(j.path));
      x.upload.onprogress=e=>{if(e.lengthComputable)j.el.querySelector('i').style.width=(100*e.loaded/e.total)+'%'};
      x.onload=()=>{j.el.classList.add(x.status==200?'done':'err');j.el.querySelector('i').style.width='100%';res()};
      x.onerror=()=>{j.el.classList.add('err');res()};x.send(j.file)})}
    document.getElementById('files').onchange=e=>add([...e.target.files].map(f=>({file:f,path:f.name})));
    document.getElementById('folder').onchange=e=>add([...e.target.files].map(f=>({file:f,path:f.webkitRelativePath||f.name})));
    const drop=document.getElementById('drop');
    ['dragenter','dragover'].forEach(t=>drop.addEventListener(t,e=>{e.preventDefault();drop.classList.add('over')}));
    ['dragleave','drop'].forEach(t=>drop.addEventListener(t,e=>{e.preventDefault();drop.classList.remove('over')}));
    async function walk(entry,prefix,out){if(entry.isFile){await new Promise(r=>entry.file(f=>{out.push({file:f,path:prefix+f.name});r()},r))}
      else if(entry.isDirectory){const reader=entry.createReader();let batch;do{batch=await new Promise(r=>reader.readEntries(r,()=>r([])));
        for(const c of batch)await walk(c,prefix+entry.name+'/',out)}while(batch.length)}}
    drop.addEventListener('drop',async e=>{const out=[];const items=[...e.dataTransfer.items].map(i=>i.webkitGetAsEntry&&i.webkitGetAsEntry()).filter(Boolean);
      if(items.length){for(const it of items)await walk(it,'',out)}else{for(const f of e.dataTransfer.files)out.push({file:f,path:f.name})}add(out)});
    load();
    </script></body></html>
    """
}
