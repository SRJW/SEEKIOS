#if canImport(Network)
import Foundation
import Network

public struct DownloadID: Hashable, Sendable {
    public let username: String
    public let path: String

    public init(username: String, path: String) {
        self.username = username
        self.path = path
    }
}

public enum DownloadState: Equatable, Sendable {
    /// Connecting to the peer to send QueueUpload.
    case requesting
    /// Peer accepted the request (or waiting for a local peer-queue slot).
    case queued(place: UInt32?)
    /// Peer sent TransferRequest; waiting for their file connection.
    case starting
    case transferring
    /// Paused by the user; partial bytes are preserved on disk for resume.
    case paused
    case completed(URL)
    case failed(String)
}

public struct DownloadUpdate: Sendable {
    public let id: DownloadID
    public let state: DownloadState
    public let received: UInt64
    public let size: UInt64
    public let bytesPerSecond: Double

    public init(id: DownloadID, state: DownloadState, received: UInt64, size: UInt64, bytesPerSecond: Double = 0) {
        self.id = id
        self.state = state
        self.received = received
        self.size = size
        self.bytesPerSecond = bytesPerSecond
    }
}

public enum ClientState: Equatable, Sendable {
    case disconnected
    case connecting
    case loggedIn
    case failed(String)
}

/// A local file we share. `virtualPath` is what peers see, backslash-separated.
public struct LocalShare: Sendable {
    public let virtualPath: String
    public let url: URL
    public let size: UInt64

    public init(virtualPath: String, url: URL, size: UInt64) {
        self.virtualPath = virtualPath
        self.url = url
        self.size = size
    }
}

public enum UploadState: Equatable, Sendable {
    case queued
    case transferring
    case completed
    case failed
}

/// Progress of a file we're sending to a peer. `id.username` is the downloader.
public struct UploadUpdate: Sendable {
    public let id: DownloadID
    public let state: UploadState
    public let sent: UInt64
    public let size: UInt64
    public let bytesPerSecond: Double

    public init(id: DownloadID, state: UploadState, sent: UInt64, size: UInt64, bytesPerSecond: Double = 0) {
        self.id = id
        self.state = state
        self.sent = sent
        self.size = size
        self.bytesPerSecond = bytesPerSecond
    }
}

public enum ClientEvent: Sendable {
    case state(ClientState)
    case listeningPort(UInt16)
    case wishlistInterval(UInt32)
    case userStatus(username: String, status: UserStatus)
    case searchResponse(SearchResponse)
    case download(DownloadUpdate)
    case upload(UploadUpdate)
    case log(String)
}

public final class SoulseekClient: @unchecked Sendable {
    public var onEvent: ((ClientEvent) -> Void)?

    public var serverHost = "server.slsknet.org"
    public var serverPort: UInt16 = 2242
    public var advertisedPort: UInt32 = 2234

    public var downloadDirectory: URL
    public let incompleteDirectory: URL

    private let queue = DispatchQueue(label: "seekios.soulseek-client")
    private var server: NWConnection?
    private var serverFrames = FrameBuffer()
    private var listener: NWListener?
    private var activeListenPort: UInt16 = 0
    private var incomingConnections: [ObjectIdentifier: IncomingConnection] = [:]

    private var username = ""
    private var isLoggedIn = false
    private var activeSearches: [UInt32: Date] = [:]

    // Tunable Nicotine+-style limits
    private var maxConcurrentDownloads = 4
    private var maxConcurrentUploads = 2
    private var maxQueuedPerPeer = 10
    private var sharingEnabled = false
    private var distributedSearchEnabled = false

    // Peer & address management
    private var peers: [String: PeerLink] = [:]
    private var addressCache: [String: CachedAddress] = [:]
    private var addressWaiters: [String: [(PeerAddress?) -> Void]] = [:]
    private var pendingIndirectPeers: [UInt32: PeerLink] = [:]
    private var pendingIndirectFiles: [UInt32: UploadJob] = [:]
    private var watchedUsers = Set<String>()
    private var userStatuses: [String: UserStatus] = [:]

    // Transfers
    private var fileLinks: [ObjectIdentifier: FileLink] = [:]
    private var downloads: [DownloadID: DownloadRecord] = [:]
    private var downloadsByToken: [String: DownloadID] = [:]
    private var stagedDownloadQueue: [DownloadID] = []

    // Sharing & uploads
    private var shares: [String: LocalShare] = [:]
    private var shareWordIndex: [String: [String]] = [:]
    private var uploadQueue: [UploadJob] = []
    private var activeUploads: [UInt32: UploadJob] = [:]
    private var completedUploads: UInt32 = 0
    private var averageUploadSpeed: UInt32 = 100_000

    // Folder & user share browsing (strictly separated)
    private var folderBrowses: [UInt32: FolderBrowse] = [:]
    private var shareListBrowses: [String: [([SharedFile]?) -> Void]] = [:]

    // Distributed network (D)
    private var parentConnection: NWConnection?
    private var parentFrames = FrameBuffer()
    private var parentUsername: String?
    private var lastDistribReplyAt = Date.distantPast
    private var distribRepliesThisMinute = 0

    // Maintenance & keepalive
    public var serverPingInterval: TimeInterval = 90
    private var maintenanceTimer: DispatchSourceTimer?
    private var lastServerPingSent: Date?
    private var lastQueuePollAt = Date.distantPast

    public init(downloadDirectory: URL, incompleteDirectory: URL) {
        self.downloadDirectory = downloadDirectory
        self.incompleteDirectory = incompleteDirectory
    }

    deinit {
        maintenanceTimer?.cancel()
        listener?.cancel()
        server?.cancel()
        parentConnection?.cancel()
    }

    // MARK: - Public API

    public func setDownloadDirectory(_ url: URL) {
        queue.async {
            self.downloadDirectory = url
        }
    }

    public func configure(
        maxConcurrentDownloads: Int,
        maxConcurrentUploads: Int,
        maxQueuedPerPeer: Int,
        sharingEnabled: Bool = false,
        distributedSearchEnabled: Bool
    ) {
        queue.async {
            let wasSharing = self.sharingEnabled
            self.maxConcurrentDownloads = max(1, min(maxConcurrentDownloads, 16))
            self.maxConcurrentUploads = max(1, min(maxConcurrentUploads, 8))
            self.maxQueuedPerPeer = max(1, min(maxQueuedPerPeer, 50))
            self.sharingEnabled = sharingEnabled
            self.distributedSearchEnabled = sharingEnabled && distributedSearchEnabled

            if !self.distributedSearchEnabled {
                self.closeDistributedParent()
            }
            if !self.sharingEnabled {
                let queued = self.uploadQueue
                self.uploadQueue.removeAll()
                for job in queued {
                    self.emitUpload(username: job.username, path: job.path, state: .failed, sent: 0, size: job.share.size, speed: 0)
                }
                let activeTokens = Array(self.activeUploads.keys)
                for token in activeTokens {
                    for link in Array(self.fileLinks.values) {
                        if case let .uploading(t) = link.role, t == token {
                            self.closeFile(link, reason: nil)
                        }
                    }
                    self.finishUpload(token: token, succeeded: false)
                }
            }
            if self.isLoggedIn && wasSharing != self.sharingEnabled {
                self.sendShareCounts()
                self.sendServer(.haveNoParent(self.distributedSearchEnabled))
            }
            self.pumpDownloads()
            if self.sharingEnabled {
                self.startNextUploads()
            }
        }
    }

    public func connect(username: String, password: String) {
        queue.async { self.openServer(username: username, password: password) }
    }

    public func disconnect() {
        queue.async { self.tearDown(.disconnected) }
    }

    @discardableResult
    public func search(_ query: String) -> UInt32 {
        let token = nextToken()
        queue.async {
            guard self.isLoggedIn else { return }
            self.activeSearches[token] = Date()
            self.sendServer(.fileSearch(token: token, query: query))
        }
        return token
    }

    @discardableResult
    public func wishlistSearch(_ query: String) -> UInt32 {
        let token = nextToken()
        queue.async {
            guard self.isLoggedIn else { return }
            self.activeSearches[token] = Date()
            self.sendServer(.wishlistSearch(token: token, query: query))
        }
        return token
    }

    public func stopSearch(_ token: UInt32) {
        queue.async {
            self.activeSearches.removeValue(forKey: token)
        }
    }

    public func watchUser(_ username: String) {
        queue.async {
            guard self.isLoggedIn, !username.isEmpty else { return }
            self.ensureWatching(username)
        }
    }

    public func requestUserStatus(_ username: String) {
        queue.async {
            guard self.isLoggedIn, !username.isEmpty else { return }
            self.sendServer(.getUserStatus(username: username))
        }
    }

    /// Registers a previously incomplete download so it can resume from disk offset.
    public func restoreInterruptedDownload(username: String, path: String, size: UInt64, folderName: String? = nil) {
        queue.async {
            let id = DownloadID(username: username, path: path)
            guard self.downloads[id] == nil else { return }
            let partURL = self.partialURL(for: id)
            let savedBytes = (try? FileManager.default.attributesOfItem(atPath: partURL.path)[.size] as? UInt64) ?? 0
            let validReceived = size > 0 ? min(savedBytes, size) : savedBytes
            self.downloads[id] = DownloadRecord(
                id: id,
                state: .paused,
                size: size,
                received: validReceived,
                token: nil,
                retries: 0,
                folderName: folderName,
                sentToPeer: false
            )
            self.emitDownload(id)
        }
    }

    /// Returns how many partial bytes currently exist on disk for this transfer.
    public func partialBytesOnDisk(username: String, path: String) -> UInt64 {
        let id = DownloadID(username: username, path: path)
        let partURL = partialURL(for: id)
        return (try? FileManager.default.attributesOfItem(atPath: partURL.path)[.size] as? UInt64) ?? 0
    }

    public func download(username: String, file: SharedFile, folderName: String? = nil) {
        queue.async {
            let id = DownloadID(username: username, path: file.path)
            if let existing = self.downloads[id] {
                switch existing.state {
                case .failed, .paused: break
                default: return
                }
            }
            let partURL = self.partialURL(for: id)
            let savedBytes = (try? FileManager.default.attributesOfItem(atPath: partURL.path)[.size] as? UInt64) ?? 0
            self.downloads[id] = DownloadRecord(
                id: id,
                state: .queued(place: nil),
                size: file.size,
                received: file.size > 0 ? min(savedBytes, file.size) : savedBytes,
                folderName: folderName,
                sentToPeer: false
            )
            if !self.stagedDownloadQueue.contains(id) {
                self.stagedDownloadQueue.append(id)
            }
            self.ensureWatching(username)
            self.emitDownload(id)
            self.pumpDownloads()
        }
    }

    /// Pauses an active or queued download while keeping its `.part` file on disk for later resume.
    public func pause(_ id: DownloadID) {
        queue.async {
            guard var record = self.downloads[id] else { return }
            switch record.state {
            case .completed, .paused:
                return
            default:
                break
            }
            self.stagedDownloadQueue.removeAll { $0 == id }
            if let token = record.token {
                self.downloadsByToken[self.tokenKey(id.username, token)] = nil
                record.token = nil
            }
            record.state = .paused
            record.sentToPeer = false
            record.bytesPerSecond = 0
            self.downloads[id] = record
            for link in Array(self.fileLinks.values) {
                if case let .downloading(linkID) = link.role, linkID == id {
                    self.closeFile(link, reason: nil)
                }
            }
            self.emitDownload(id)
            self.pumpDownloads()
        }
    }

    public func retry(_ id: DownloadID, size: UInt64 = 0, folderName: String? = nil) {
        queue.async {
            let partURL = self.partialURL(for: id)
            let savedBytes = (try? FileManager.default.attributesOfItem(atPath: partURL.path)[.size] as? UInt64) ?? 0
            if var record = self.downloads[id] {
                if case .completed = record.state { return }
                record.state = .queued(place: nil)
                record.retries = 0
                record.sentToPeer = false
                record.bytesPerSecond = 0
                if size > 0 && record.size == 0 { record.size = size }
                if let folderName { record.folderName = folderName }
                record.received = record.size > 0 ? min(savedBytes, record.size) : savedBytes
                self.downloads[id] = record
            } else {
                self.downloads[id] = DownloadRecord(
                    id: id,
                    state: .queued(place: nil),
                    size: size,
                    received: size > 0 ? min(savedBytes, size) : savedBytes,
                    token: nil,
                    retries: 0,
                    folderName: folderName,
                    sentToPeer: false
                )
            }
            if !self.stagedDownloadQueue.contains(id) {
                self.stagedDownloadQueue.append(id)
            }
            self.ensureWatching(id.username)
            self.emitDownload(id)
            self.pumpDownloads()
        }
    }

    public func cancel(_ id: DownloadID, deletePartial: Bool = false) {
        queue.async {
            self.stagedDownloadQueue.removeAll { $0 == id }
            if let token = self.downloads[id]?.token {
                self.downloadsByToken[self.tokenKey(id.username, token)] = nil
            }
            self.downloads[id] = nil
            for link in Array(self.fileLinks.values) {
                if case let .downloading(linkID) = link.role, linkID == id {
                    self.closeFile(link, reason: nil)
                }
            }
            if deletePartial {
                try? FileManager.default.removeItem(at: self.partialURL(for: id))
            }
            self.pumpDownloads()
        }
    }

    public func abortUpload(_ id: DownloadID) {
        queue.async {
            self.uploadQueue.removeAll { $0.username == id.username && $0.path == id.path }
            if let (token, job) = self.activeUploads.first(where: { $0.value.username == id.username && $0.value.path == id.path }) {
                for link in Array(self.fileLinks.values) {
                    if case let .uploading(linkToken) = link.role, linkToken == token {
                        self.closeFile(link, reason: nil)
                    }
                }
                self.activeUploads.removeValue(forKey: token)
                if self.isLoggedIn {
                    self.sendToPeer(job.username, [.uploadDenied(filename: job.path, reason: "Cancelled")])
                }
                self.emitUpload(username: job.username, path: job.path, state: .failed, sent: 0, size: job.share.size, speed: 0)
                self.startNextUploads()
            } else {
                if self.isLoggedIn {
                    self.sendToPeer(id.username, [.uploadDenied(filename: id.path, reason: "Cancelled")])
                }
                self.emitUpload(username: id.username, path: id.path, state: .failed, sent: 0, size: 0, speed: 0)
            }
        }
    }

    /// Requests ONLY a specific folder's contents (`FolderContentsRequest`, code 36),
    /// matching Nicotine+'s lightweight behavior (never pulls the entire user share list).
    public func browseFolder(username: String, folder: String, completion: @escaping ([SharedFile]?) -> Void) {
        if folder.isEmpty {
            browseUserShares(username: username, completion: completion)
            return
        }
        queue.async {
            guard self.isLoggedIn else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let token = self.nextToken()
            self.folderBrowses[token] = FolderBrowse(username: username, folder: folder, completion: completion)
            self.sendToPeer(
                username,
                [.folderContentsRequest(token: token, folder: folder)],
                onFailure: { [weak self] in self?.finishFolderBrowse(token: token, files: nil) }
            )
            self.queue.asyncAfter(deadline: .now() + 20) { [weak self] in
                self?.finishFolderBrowse(token: token, files: nil)
            }
        }
    }

    /// Explicitly requests a user's entire shared tree (`SharedFileListRequest`, code 4).
    public func browseUserShares(username: String, completion: @escaping ([SharedFile]?) -> Void) {
        queue.async {
            guard self.isLoggedIn else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let key = username.lowercased()
            let isFirst = self.shareListBrowses[key] == nil
            self.shareListBrowses[key, default: []].append(completion)
            guard isFirst else { return }

            self.sendToPeer(
                username,
                [.sharedFileListRequest],
                onFailure: { [weak self] in self?.finishShareListBrowse(usernameKey: key, files: nil) }
            )
            self.queue.asyncAfter(deadline: .now() + 35) { [weak self] in
                self?.finishShareListBrowse(usernameKey: key, files: nil)
            }
        }
    }

    public func updateShares(_ list: [LocalShare]) {
        queue.async {
            var map: [String: LocalShare] = [:]
            var index: [String: [String]] = [:]
            map.reserveCapacity(list.count)
            for share in list {
                map[share.virtualPath] = share
                for token in Self.searchTokens(share.virtualPath) {
                    index[token, default: []].append(share.virtualPath)
                }
            }
            self.shares = map
            self.shareWordIndex = index
            if self.isLoggedIn { self.sendShareCounts() }
        }
    }

    // MARK: - Incoming TCP Listener (enables Direct incoming + Indirect PierceFirewall)

    private func startListener() {
        stopListener()
        let preferredPort = NWEndpoint.Port(rawValue: UInt16(truncatingIfNeeded: advertisedPort))
        openListener(on: preferredPort)
    }

    private func openListener(on port: NWEndpoint.Port?) {
        let params = Self.tcpParameters(timeout: 12)
        params.allowLocalEndpointReuse = true
        let created: NWListener?
        if let port {
            created = try? NWListener(using: params, on: port)
        } else {
            created = try? NWListener(using: params)
        }
        guard let listener = created else {
            if port != nil {
                openListener(on: nil)
            } else {
                activeListenPort = 0
                emit(.listeningPort(0))
                if isLoggedIn { sendServer(.setWaitPort(0)) }
            }
            return
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.acceptIncoming(connection)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, self.listener === listener else { return }
            switch state {
            case .ready:
                let actual = listener.port?.rawValue ?? 0
                self.activeListenPort = actual
                self.emit(.listeningPort(actual))
                if self.isLoggedIn {
                    self.sendServer(.setWaitPort(UInt32(actual)))
                }
                self.log("Listening for peer connections on TCP port \(actual)")
            case .failed:
                listener.cancel()
                self.listener = nil
                if port != nil {
                    self.openListener(on: nil)
                } else {
                    self.activeListenPort = 0
                    self.emit(.listeningPort(0))
                    if self.isLoggedIn { self.sendServer(.setWaitPort(0)) }
                }
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    private func stopListener() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        activeListenPort = 0
        for incoming in Array(incomingConnections.values) {
            incoming.cancel()
        }
        incomingConnections.removeAll()
    }

    private func acceptIncoming(_ connection: NWConnection) {
        let wrapper = IncomingConnection(connection: connection)
        let key = ObjectIdentifier(wrapper)
        incomingConnections[key] = wrapper

        connection.stateUpdateHandler = { [weak self, weak wrapper] state in
            guard let self, let wrapper else { return }
            switch state {
            case .ready:
                self.readIncomingInit(wrapper)
            case .failed, .cancelled:
                self.incomingConnections.removeValue(forKey: ObjectIdentifier(wrapper))
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak wrapper] in
            guard let self, let wrapper, self.incomingConnections.removeValue(forKey: ObjectIdentifier(wrapper)) != nil else { return }
            wrapper.cancel()
        }
    }

    private func readIncomingInit(_ wrapper: IncomingConnection) {
        wrapper.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak wrapper] data, _, isComplete, error in
            guard let self, let wrapper else { return }
            guard self.incomingConnections[ObjectIdentifier(wrapper)] != nil else { return }
            if let data, !data.isEmpty { wrapper.frames.append(data) }

            do {
                if let body = try wrapper.frames.nextFrame() {
                    let initMsg = try PeerInitMessage.decode(body)
                    let leftover = wrapper.frames.drain()
                    self.incomingConnections.removeValue(forKey: ObjectIdentifier(wrapper))
                    self.routeIncoming(connection: wrapper.connection, initMessage: initMsg, leftover: leftover)
                    return
                }
            } catch {
                self.incomingConnections.removeValue(forKey: ObjectIdentifier(wrapper))
                wrapper.cancel()
                return
            }

            if isComplete || error != nil {
                self.incomingConnections.removeValue(forKey: ObjectIdentifier(wrapper))
                wrapper.cancel()
            } else {
                self.readIncomingInit(wrapper)
            }
        }
    }

    private func routeIncoming(connection: NWConnection, initMessage: PeerInitMessage, leftover: Data) {
        switch initMessage {
        case let .pierceFirewall(token):
            if let link = pendingIndirectPeers.removeValue(forKey: token), !link.isClosed {
                attachReadyPeer(link, connection: connection, sendFirstFrame: nil, leftover: leftover)
                return
            }
            if let job = pendingIndirectFiles.removeValue(forKey: token), activeUploads[job.token] != nil {
                attachUploadConnection(job: job, connection: connection, sendPeerInit: false, leftover: leftover)
                return
            }
            connection.cancel()

        case let .peerInit(remoteUser, type):
            switch type {
            case ConnectionType.peer.rawValue:
                let link: PeerLink
                if let existing = peers[remoteUser], !existing.isReady, !existing.isClosed {
                    link = existing
                    link.connection?.stateUpdateHandler = nil
                    link.connection?.cancel()
                } else {
                    if let existing = peers[remoteUser] {
                        closePeer(existing, failed: false)
                    }
                    link = PeerLink(username: remoteUser)
                    peers[remoteUser] = link
                }
                attachReadyPeer(link, connection: connection, sendFirstFrame: nil, leftover: leftover)

            case ConnectionType.file.rawValue:
                let link = FileLink(username: remoteUser, connection: connection, role: .awaitingToken)
                fileLinks[ObjectIdentifier(link)] = link
                connection.stateUpdateHandler = { [weak self, weak link] state in
                    guard let self, let link, !link.isClosed else { return }
                    if case .failed = state { self.closeFile(link, reason: "File connection failed") }
                }
                if !leftover.isEmpty { handleFileData(link, leftover) }
                if !link.isClosed {
                    receive(on: connection, onData: { [weak self, weak link] data in
                        guard let self, let link else { return }
                        self.handleFileData(link, data)
                    }, onClose: { [weak self, weak link] error in
                        guard let self, let link else { return }
                        self.closeFile(link, reason: error == nil ? nil : "Connection closed early")
                    })
                }

            default:
                connection.cancel()
            }
        }
    }

    // MARK: - Server Connection & Maintenance

    private func openServer(username: String, password: String) {
        tearDown(.connecting)
        self.username = username
        startListener()
        guard let port = NWEndpoint.Port(rawValue: serverPort) else { return }

        let connection = NWConnection(host: NWEndpoint.Host(serverHost), port: port, using: Self.tcpParameters(timeout: 15))
        server = connection
        serverFrames = FrameBuffer()

        var serverBecameReady = false
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.server === connection else { return }
            switch state {
            case .ready:
                serverBecameReady = true
                self.log("Connected to \(self.serverHost), logging in as \(username)")
                self.sendServer(.login(username: username, password: password,
                                       majorVersion: ServerRequest.majorVersion,
                                       minorVersion: ServerRequest.minorVersion))
                self.receive(on: connection, onData: { [weak self] data in
                    guard let self, self.server === connection else { return }
                    self.handleServerData(data)
                }, onClose: { [weak self] _ in
                    guard let self, self.server === connection else { return }
                    self.tearDown(.failed("Disconnected from server"))
                })
            case let .waiting(error):
                // Transient iOS network transition: allow up to 15s for route recovery before giving up.
                let waitingSince = Date()
                self.queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                    guard let self, self.server === connection, !serverBecameReady else { return }
                    if Date().timeIntervalSince(waitingSince) >= 14.5 {
                        self.tearDown(.failed("Can't reach server: \(error.localizedDescription)"))
                    }
                }
            case let .failed(error):
                self.tearDown(.failed("Can't reach server: \(error.localizedDescription)"))
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func startMaintenanceTimer() {
        maintenanceTimer?.cancel()
        lastServerPingSent = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            self?.runMaintenanceTick()
        }
        timer.resume()
        maintenanceTimer = timer
    }

    private func runMaintenanceTick() {
        guard isLoggedIn else { return }
        let now = Date()

        // 1. One-way ServerPing keepalive (official server does NOT send a pong back).
        let pingInterval = max(serverPingInterval, 60)
        if lastServerPingSent == nil || now.timeIntervalSince(lastServerPingSent!) >= pingInterval {
            lastServerPingSent = now
            sendServer(.serverPing)
        }

        // 2. Stall detection on active downloads (60s without bytes, matching Nicotine+).
        for link in Array(fileLinks.values) {
            if case let .downloading(id) = link.role, now.timeIntervalSince(link.lastDataAt) > 60 {
                if let record = downloads[id], record.retries < 3 {
                    log("Download stalled for \(id.path), retrying (\(record.retries + 1)/3)")
                    // Detach role before closing so closeFile does not emit a spurious .failed state.
                    link.role = .awaitingToken
                    closeFile(link, reason: nil)
                    if let token = record.token {
                        downloadsByToken.removeValue(forKey: tokenKey(id.username, token))
                        downloads[id]?.token = nil
                    }
                    downloads[id]?.retries += 1
                    downloads[id]?.state = .queued(place: nil)
                    downloads[id]?.sentToPeer = false
                    downloads[id]?.bytesPerSecond = 0
                    if !stagedDownloadQueue.contains(id) { stagedDownloadQueue.append(id) }
                    emitDownload(id)
                } else {
                    log("Download stalled for \(id.path)")
                    closeFile(link, reason: "Transfer stalled")
                }
            }
        }

        // 3. Periodic PlaceInQueueRequest refresh every 45s for remotely queued downloads.
        if now.timeIntervalSince(lastQueuePollAt) >= 45 {
            lastQueuePollAt = now
            for (id, record) in downloads where record.sentToPeer {
                if case .queued = record.state {
                    sendToPeer(id.username, [.placeInQueueRequest(filename: id.path)])
                }
            }
        }

        // 4. Expire old search tokens (> 90s) so late responses stop burning CPU/zlib.
        activeSearches = activeSearches.filter { now.timeIntervalSince($0.value) < 90 }

        // 5. Reap idle PeerLinks (> 120s without traffic and no active transfers/browses).
        let busyUsers = Set(
            downloads.values.filter {
                switch $0.state {
                case .requesting, .queued, .starting, .transferring: return true
                default: return false
                }
            }.map(\.id.username)
            + activeUploads.values.map(\.username)
            + uploadQueue.map(\.username)
            + folderBrowses.values.map(\.username)
        )
        for link in Array(peers.values) where link.isReady && !busyUsers.contains(link.username) {
            if now.timeIntervalSince(link.lastActivity) > 120 {
                closePeer(link, failed: false)
            }
        }

        // 6. Evict expired PeerAddress cache entries (> 5 min).
        addressCache = addressCache.filter { now.timeIntervalSince($0.value.cachedAt) < 300 }

        // 7. Pump staged downloads & uploads.
        pumpDownloads()
        startNextUploads()
    }

    private func tearDown(_ newState: ClientState) {
        isLoggedIn = false
        maintenanceTimer?.cancel()
        maintenanceTimer = nil
        lastServerPingSent = nil
        activeSearches.removeAll()
        watchedUsers.removeAll()
        userStatuses.removeAll()
        pendingIndirectPeers.removeAll()
        pendingIndirectFiles.removeAll()

        closeDistributedParent()
        stopListener()

        if let server {
            server.stateUpdateHandler = nil
            server.cancel()
        }
        server = nil

        for link in Array(peers.values) { closePeer(link, failed: true) }
        for link in Array(fileLinks.values) { closeFile(link, reason: "Disconnected") }
        for waiters in addressWaiters.values { waiters.forEach { $0(nil) } }
        addressWaiters.removeAll()
        addressCache.removeAll()

        stagedDownloadQueue.removeAll()
        for (id, record) in downloads {
            switch record.state {
            case .requesting, .queued, .starting, .transferring:
                downloads[id]?.state = .failed("Disconnected")
                downloads[id]?.sentToPeer = false
                downloads[id]?.bytesPerSecond = 0
                emitDownload(id)
            default:
                break
            }
        }
        for job in uploadQueue + Array(activeUploads.values) {
            emitUpload(username: job.username, path: job.path, state: .failed, sent: 0, size: job.share.size, speed: 0)
        }
        uploadQueue.removeAll()
        activeUploads.removeAll()

        for token in Array(folderBrowses.keys) { finishFolderBrowse(token: token, files: nil) }
        for key in Array(shareListBrowses.keys) { finishShareListBrowse(usernameKey: key, files: nil) }
        emit(.state(newState))
    }

    private func handleServerData(_ data: Data) {
        serverFrames.append(data)
        while server != nil {
            let body: Data
            do {
                guard let next = try serverFrames.nextFrame() else { return }
                body = next
            } catch {
                tearDown(.failed("Server sent an invalid frame"))
                return
            }
            do {
                let event = try ServerEvent.decode(body)
                handleServerEvent(event)
            } catch {
                log("Couldn't decode server message: \(error)")
            }
        }
    }

    private func handleServerEvent(_ event: ServerEvent) {
        switch event {
        case let .loginSucceeded(greeting, ownIP):
            isLoggedIn = true
            log("Logged in (public IP \(ownIP)). \(greeting)")
            sendServer(.setWaitPort(UInt32(activeListenPort)))
            sendServer(.setStatus(2))
            sendServer(.haveNoParent(sharingEnabled && distributedSearchEnabled))
            sendServer(.branchRoot(username))
            sendServer(.branchLevel(0))
            sendServer(.acceptChildren(false))
            sendShareCounts()
            startMaintenanceTimer()
            emit(.state(.loggedIn))

        case let .loginFailed(reason, detail):
            tearDown(.failed(Self.describeLoginFailure(reason, detail)))

        case let .peerAddress(username, ip, port):
            let waiters = addressWaiters.removeValue(forKey: username) ?? []
            let address: PeerAddress? = (ip == "0.0.0.0" || port == 0) ? nil : PeerAddress(ip: ip, port: port)
            if let address {
                addressCache[username] = CachedAddress(address: address, cachedAt: Date())
            }
            waiters.forEach { $0(address) }

        case let .watchUser(username, exists, status):
            let resolved = exists ? (status ?? .offline) : .offline
            handleUserStatusUpdate(username: username, status: resolved)

        case let .userStatus(username, status):
            handleUserStatusUpdate(username: username, status: status)

        case let .connectToPeer(username, type, ip, port, token):
            switch type {
            case ConnectionType.peer.rawValue:
                openPiercedPeer(username: username, ip: ip, port: port, token: token)
            case ConnectionType.file.rawValue:
                openPiercedFile(username: username, ip: ip, port: port, token: token)
            default:
                sendServer(.cantConnectToPeer(token: token, username: username))
            }

        case .serverPing:
            break

        case let .embeddedMessage(distribCode, payload):
            if sharingEnabled, distributedSearchEnabled,
               let msg = try? DistributedMessage.decodePayload(code: distribCode, payload: payload) {
                handleDistributedMessage(msg)
            }

        case let .possibleParents(parents):
            if sharingEnabled, distributedSearchEnabled, !shares.isEmpty, parentConnection == nil, !parents.isEmpty {
                connectDistributedParent(from: parents)
            }

        case let .wishlistInterval(seconds):
            emit(.wishlistInterval(seconds))

        case let .cantConnectToPeer(token):
            if let link = pendingIndirectPeers.removeValue(forKey: token) {
                closePeer(link, failed: true)
            }
            if let job = pendingIndirectFiles.removeValue(forKey: token) {
                finishUpload(token: job.token, succeeded: false)
            }

        case .relogged:
            tearDown(.failed("Logged in from somewhere else"))

        case .other:
            break
        }
    }

    private func handleUserStatusUpdate(username: String, status: UserStatus) {
        let previous = userStatuses[username]
        userStatuses[username] = status
        emit(.userStatus(username: username, status: status))

        // Nicotine+-style: when a peer transitions back online, immediately re-queue failed downloads from them.
        if status == .online, previous != .online {
            var requeued = 0
            for (id, record) in downloads where id.username == username {
                if case .failed = record.state {
                    downloads[id]?.state = .queued(place: nil)
                    downloads[id]?.retries = 0
                    downloads[id]?.sentToPeer = false
                    if !stagedDownloadQueue.contains(id) { stagedDownloadQueue.append(id) }
                    emitDownload(id)
                    requeued += 1
                }
            }
            if requeued > 0 {
                log("\(username) came online — re-queuing \(requeued) transfer(s)")
                pumpDownloads()
            }
        }
    }

    private func ensureWatching(_ username: String) {
        guard isLoggedIn, !username.isEmpty, watchedUsers.insert(username).inserted else { return }
        sendServer(.watchUser(username: username))
    }

    private static func describeLoginFailure(_ reason: String, _ detail: String?) -> String {
        switch reason {
        case "INVALIDPASS": return "Wrong password for this username"
        case "INVALIDUSERNAME": return "Invalid username" + (detail.map { ": \($0)" } ?? "")
        case "EMPTYPASSWORD": return "Password can't be empty"
        case "INVALIDVERSION": return "Server rejected this client version"
        case "SVRFULL": return "Server is full, try again later"
        case "SVRPRIVATE": return "Server isn't accepting new accounts"
        default: return "Login failed: \(reason)"
        }
    }

    private func sendServer(_ request: ServerRequest) {
        server?.send(content: request.frame, completion: .contentProcessed { _ in })
    }

    private func sendShareCounts() {
        guard sharingEnabled else {
            sendServer(.sharedFoldersFiles(folders: 0, files: 0))
            return
        }
        let folders = Set(shares.keys.map { Self.splitVirtualPath($0).folder })
        sendServer(.sharedFoldersFiles(folders: UInt32(folders.count), files: UInt32(shares.count)))
    }

    private func resolveAddress(_ username: String, forceRefresh: Bool = false, completion: @escaping (PeerAddress?) -> Void) {
        if !forceRefresh, let cached = addressCache[username], Date().timeIntervalSince(cached.cachedAt) < 300 {
            completion(cached.address)
            return
        }
        let isFirst = addressWaiters[username] == nil
        addressWaiters[username, default: []].append(completion)
        guard isFirst else { return }
        sendServer(.getPeerAddress(username: username))
        queue.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, let waiters = self.addressWaiters.removeValue(forKey: username) else { return }
            waiters.forEach { $0(nil) }
        }
    }

    // MARK: - Distributed Network (D) for Share Search Visibility

    private func connectDistributedParent(from parents: [DistributedParent]) {
        guard let candidate = parents.first(where: { $0.port > 0 && $0.ip != "0.0.0.0" }),
              let port = NWEndpoint.Port(rawValue: UInt16(truncatingIfNeeded: candidate.port)) else { return }
        closeDistributedParent()
        let connection = NWConnection(host: NWEndpoint.Host(candidate.ip), port: port, using: Self.tcpParameters(timeout: 8))
        parentConnection = connection
        parentFrames = FrameBuffer()
        parentUsername = candidate.username

        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.parentConnection === connection else { return }
            switch state {
            case .ready:
                connection.send(
                    content: PeerInitMessage.peerInit(username: self.username, type: ConnectionType.distributed.rawValue).frame,
                    completion: .contentProcessed { _ in }
                )
                self.sendServer(.haveNoParent(false))
                self.receive(on: connection, onData: { [weak self] data in
                    guard let self, self.parentConnection === connection else { return }
                    self.handleParentData(data)
                }, onClose: { [weak self] _ in
                    guard let self, self.parentConnection === connection else { return }
                    self.closeDistributedParent()
                    if self.isLoggedIn { self.sendServer(.haveNoParent(true)) }
                })
            case .waiting, .failed:
                self.closeDistributedParent()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func closeDistributedParent() {
        parentConnection?.stateUpdateHandler = nil
        parentConnection?.cancel()
        parentConnection = nil
        parentUsername = nil
        parentFrames = FrameBuffer()
    }

    private func handleParentData(_ data: Data) {
        parentFrames.append(data)
        while parentConnection != nil {
            do {
                guard let body = try parentFrames.nextFrame() else { return }
                let msg = try DistributedMessage.decode(body)
                handleDistributedMessage(msg)
            } catch {
                closeDistributedParent()
                if isLoggedIn { sendServer(.haveNoParent(true)) }
                return
            }
        }
    }

    private func handleDistributedMessage(_ message: DistributedMessage) {
        switch message {
        case let .branchLevel(level):
            sendServer(.branchLevel(level + 1))
        case let .branchRoot(root):
            sendServer(.branchRoot(root))
        case let .searchRequest(requester, token, query):
            respondToDistributedSearch(requester: requester, token: token, query: query)
        case .ping, .unknown:
            break
        }
    }

    private func respondToDistributedSearch(requester: String, token: UInt32, query: String) {
        guard sharingEnabled, distributedSearchEnabled, !shares.isEmpty, requester != username else { return }
        let now = Date()
        if now.timeIntervalSince(lastDistribReplyAt) > 60 {
            distribRepliesThisMinute = 0
            lastDistribReplyAt = now
        }
        // Protect mobile battery & bandwidth: cap outgoing distributed replies to 15/min.
        guard distribRepliesThisMinute < 15 else { return }

        let terms = Self.searchTokens(query)
        guard !terms.isEmpty else { return }

        // Intersect inverted word index starting from the smallest posting list.
        var lists: [[String]] = []
        for term in terms {
            guard let paths = shareWordIndex[term], !paths.isEmpty else { return }
            lists.append(paths)
        }
        lists.sort { $0.count < $1.count }
        var matches = Set(lists[0])
        for list in lists.dropFirst() {
            matches.formIntersection(list)
            if matches.isEmpty { return }
        }

        let matchedFiles: [SharedFile] = matches.prefix(50).compactMap { path in
            guard let share = shares[path] else { return nil }
            return SharedFile(path: share.virtualPath, size: share.size)
        }
        guard !matchedFiles.isEmpty else { return }

        distribRepliesThisMinute += 1
        let response = SearchResponse(
            username: username,
            token: token,
            files: matchedFiles,
            slotFree: activeUploads.count < maxConcurrentUploads,
            averageSpeed: averageUploadSpeed,
            queueLength: UInt32(uploadQueue.count)
        )
        sendToPeer(requester, [.fileSearchResponse(response)])
    }

    private static func searchTokens(_ text: String) -> [String] {
        text.lowercased()
            .folding(options: [.diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 2 }
    }

    // MARK: - Peer (P) Connections (Direct + Indirect ConnectToPeer Fallback)

    private func sendToPeer(_ username: String, _ messages: [PeerMessage],
                            onSent: (() -> Void)? = nil, onFailure: (() -> Void)? = nil) {
        var frames: [Data] = []
        do {
            for message in messages { frames.append(try message.frame()) }
        } catch {
            log("Couldn't encode message for \(username): \(error)")
            onFailure?()
            return
        }

        if let link = peers[username], !link.isClosed {
            link.lastActivity = Date()
            if link.isReady, let connection = link.connection {
                frames.forEach { connection.send(content: $0, completion: .contentProcessed { _ in }) }
                onSent?()
            } else {
                link.outbox += frames
                if let onSent { link.sentHandlers.append(onSent) }
                if let onFailure { link.failureHandlers.append(onFailure) }
            }
            return
        }

        let link = PeerLink(username: username)
        link.outbox = frames
        if let onSent { link.sentHandlers.append(onSent) }
        if let onFailure { link.failureHandlers.append(onFailure) }
        peers[username] = link

        resolveAddress(username) { [weak self] address in
            guard let self, !link.isClosed else { return }
            guard let address else {
                self.log("\(username) is offline or unknown")
                self.closePeer(link, failed: true)
                return
            }
            self.startPeerConnection(
                link,
                address: address,
                firstFrame: PeerInitMessage.peerInit(username: self.username, type: "P").frame,
                allowIndirectFallback: true
            )
        }
    }

    private func openPiercedPeer(username: String, ip: String, port: UInt32, token: UInt32) {
        let link = PeerLink(username: username)
        if let existing = peers[username] {
            if !existing.isReady {
                link.outbox = existing.outbox
                link.sentHandlers = existing.sentHandlers
                link.failureHandlers = existing.failureHandlers
                existing.outbox.removeAll()
                existing.sentHandlers.removeAll()
                existing.failureHandlers.removeAll()
            }
            closePeer(existing, failed: false)
        }
        peers[username] = link
        startPeerConnection(
            link,
            address: PeerAddress(ip: ip, port: port),
            firstFrame: PeerInitMessage.pierceFirewall(token: token).frame,
            pierceToken: token,
            allowIndirectFallback: false
        )
    }

    private func startPeerConnection(
        _ link: PeerLink,
        address: PeerAddress,
        firstFrame: Data,
        pierceToken: UInt32? = nil,
        allowIndirectFallback: Bool
    ) {
        guard let port = NWEndpoint.Port(rawValue: UInt16(truncatingIfNeeded: address.port)) else {
            attemptIndirectPeerOrFail(link, allowIndirectFallback: allowIndirectFallback)
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(address.ip), port: port, using: Self.tcpParameters(timeout: 8))
        link.connection = connection

        let handleConnectFailure: () -> Void = { [weak self, weak link] in
            guard let self, let link, !link.isClosed, !link.isReady, link.connection === connection else { return }
            if let pierceToken {
                self.sendServer(.cantConnectToPeer(token: pierceToken, username: link.username))
                self.closePeer(link, failed: true)
            } else {
                // Direct failed: invalidate cached address and try indirect ConnectToPeer if possible.
                self.addressCache.removeValue(forKey: link.username)
                connection.stateUpdateHandler = nil
                connection.cancel()
                link.connection = nil
                self.attemptIndirectPeerOrFail(link, allowIndirectFallback: allowIndirectFallback)
            }
        }

        connection.stateUpdateHandler = { [weak self, weak link] state in
            guard let self, let link, !link.isClosed, link.connection === connection else { return }
            switch state {
            case .ready:
                self.attachReadyPeer(link, connection: connection, sendFirstFrame: firstFrame, leftover: Data())
            case .waiting:
                self.queue.asyncAfter(deadline: .now() + 4) {
                    handleConnectFailure()
                }
            case .failed:
                handleConnectFailure()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func attemptIndirectPeerOrFail(_ link: PeerLink, allowIndirectFallback: Bool) {
        guard allowIndirectFallback, !link.triedIndirect, isLoggedIn, activeListenPort > 0 else {
            closePeer(link, failed: true)
            return
        }
        link.triedIndirect = true
        let token = nextToken()
        link.indirectToken = token
        pendingIndirectPeers[token] = link
        sendServer(.connectToPeer(token: token, username: link.username, type: .peer))

        queue.asyncAfter(deadline: .now() + 12) { [weak self, weak link] in
            guard let self, let link, self.pendingIndirectPeers.removeValue(forKey: token) != nil else { return }
            if !link.isReady {
                self.closePeer(link, failed: true)
            }
        }
    }

    private func attachReadyPeer(_ link: PeerLink, connection: NWConnection, sendFirstFrame: Data?, leftover: Data) {
        guard !link.isClosed else {
            connection.cancel()
            return
        }
        if let token = link.indirectToken {
            pendingIndirectPeers.removeValue(forKey: token)
            link.indirectToken = nil
        }
        link.connection = connection
        link.isReady = true
        link.lastActivity = Date()

        connection.stateUpdateHandler = { [weak self, weak link] state in
            guard let self, let link, !link.isClosed, link.connection === connection else { return }
            if case .failed = state {
                self.closePeer(link, failed: false)
            }
        }

        if let sendFirstFrame {
            connection.send(content: sendFirstFrame, completion: .contentProcessed { _ in })
        }
        link.outbox.forEach { connection.send(content: $0, completion: .contentProcessed { _ in }) }
        link.outbox.removeAll()
        link.failureHandlers.removeAll()
        let sent = link.sentHandlers
        link.sentHandlers.removeAll()
        sent.forEach { $0() }

        if !leftover.isEmpty {
            handlePeerData(link, leftover)
        }
        guard !link.isClosed else { return }
        receive(on: connection, onData: { [weak self, weak link] data in
            guard let self, let link else { return }
            self.handlePeerData(link, data)
        }, onClose: { [weak self, weak link] _ in
            guard let self, let link else { return }
            self.closePeer(link, failed: false)
        })
    }

    private func closePeer(_ link: PeerLink, failed: Bool) {
        guard !link.isClosed else { return }
        link.isClosed = true
        if let token = link.indirectToken {
            pendingIndirectPeers.removeValue(forKey: token)
            link.indirectToken = nil
        }
        link.connection?.stateUpdateHandler = nil
        link.connection?.cancel()
        link.connection = nil
        if peers[link.username] === link { peers[link.username] = nil }
        if failed {
            let handlers = link.failureHandlers
            link.failureHandlers.removeAll()
            handlers.forEach { $0() }
        }
    }

    private func handlePeerData(_ link: PeerLink, _ data: Data) {
        link.lastActivity = Date()
        link.frames.append(data)
        while !link.isClosed {
            let body: Data
            do {
                guard let next = try link.frames.nextFrame() else { return }
                body = next
            } catch {
                log("Bad frame from \(link.username): \(error)")
                closePeer(link, failed: false)
                return
            }
            do {
                let message = try PeerMessage.decode(body)
                handlePeerMessage(from: link.username, message)
            } catch {
                log("Couldn't decode message from \(link.username): \(error)")
            }
        }
    }

    private func handlePeerMessage(from username: String, _ message: PeerMessage) {
        switch message {
        case let .fileSearchResponse(response):
            guard activeSearches[response.token] != nil else { return }
            emit(.searchResponse(response))

        case let .transferRequest(direction, token, filename, size):
            if direction == .upload {
                acceptIncomingTransfer(from: username, token: token, filename: filename, size: size)
            } else {
                sendToPeer(username, [.transferResponse(token: token, allowed: false, reason: "Queued", size: nil)])
                enqueueUpload(for: username, path: filename)
            }

        case let .transferResponse(token, allowed, reason, _):
            handleUploadResponse(from: username, token: token, allowed: allowed, reason: reason)

        case let .queueUpload(filename):
            enqueueUpload(for: username, path: filename)

        case let .placeInQueueResponse(filename, place):
            let id = DownloadID(username: username, path: filename)
            guard let record = downloads[id] else { return }
            switch record.state {
            case .requesting, .queued:
                downloads[id]?.state = .queued(place: place)
                emitDownload(id)
            default:
                break
            }

        case let .uploadDenied(filename, reason):
            let id = DownloadID(username: username, path: filename)
            guard downloads[id] != nil else { return }
            downloads[id]?.state = .failed(reason.isEmpty ? "Denied by peer" : reason)
            downloads[id]?.sentToPeer = false
            downloads[id]?.bytesPerSecond = 0
            emitDownload(id)
            pumpDownloads()

        case let .uploadFailed(filename):
            let id = DownloadID(username: username, path: filename)
            guard let record = downloads[id] else { return }
            switch record.state {
            case .completed, .paused: return
            default: break
            }
            if record.retries < 2 {
                downloads[id]?.retries += 1
                downloads[id]?.state = .queued(place: nil)
                downloads[id]?.sentToPeer = false
                if !stagedDownloadQueue.contains(id) { stagedDownloadQueue.append(id) }
                emitDownload(id)
                pumpDownloads()
            } else {
                downloads[id]?.state = .failed("Upload failed on \(username)'s side")
                downloads[id]?.sentToPeer = false
                downloads[id]?.bytesPerSecond = 0
                emitDownload(id)
                pumpDownloads()
            }

        case .sharedFileListRequest:
            sendToPeer(username, [.sharedFileListResponse(folders: sharedFolders())])

        case .userInfoRequest:
            sendToPeer(username, [.userInfoResponse(
                description: "Seekios (iOS)",
                totalUploads: completedUploads,
                queueSize: UInt32(uploadQueue.count),
                slotsFree: sharingEnabled && activeUploads.count < maxConcurrentUploads
            )])

        case let .placeInQueueRequest(filename):
            if let index = uploadQueue.firstIndex(where: { $0.username == username && $0.path == filename }) {
                sendToPeer(username, [.placeInQueueResponse(filename: filename, place: UInt32(index + 1))])
            }

        case let .folderContentsRequest(token, folder):
            let folders = sharedFolders().filter { $0.name == folder || $0.name.hasPrefix(folder + "\\") }
            sendToPeer(username, [.folderContentsResponse(token: token, folder: folder, folders: folders)])

        case let .folderContentsResponse(token, _, folders):
            let files = Self.flattenSharedFolders(folders)
            if let browse = folderBrowses[token], browse.username.caseInsensitiveCompare(username) == .orderedSame {
                finishFolderBrowse(token: token, files: files)
            }

        case let .sharedFileListResponse(folders):
            let files = Self.flattenSharedFolders(folders)
            finishShareListBrowse(usernameKey: username.lowercased(), files: files)

        case .userInfoResponse, .unknown:
            break
        }
    }

    private func finishFolderBrowse(token: UInt32, files: [SharedFile]?) {
        guard let browse = folderBrowses.removeValue(forKey: token) else { return }
        DispatchQueue.main.async { browse.completion(files) }
    }

    private func finishShareListBrowse(usernameKey: String, files: [SharedFile]?) {
        guard let callbacks = shareListBrowses.removeValue(forKey: usernameKey) else { return }
        DispatchQueue.main.async {
            for cb in callbacks { cb(files) }
        }
    }

    private static func flattenSharedFolders(_ folders: [SharedFolder]) -> [SharedFile] {
        folders.flatMap { entry in
            entry.files.map { file in
                var full = file
                if !entry.name.isEmpty && !file.path.contains("\\") {
                    full.path = entry.name + "\\" + file.path
                }
                return full
            }
        }
    }

    // MARK: - Downloads & Queue Scheduling

    private func pumpDownloads() {
        guard isLoggedIn, !stagedDownloadQueue.isEmpty else { return }

        let totalRemoteLimit = max(maxConcurrentDownloads * 4, 16)
        var totalRemoteActive = downloads.values.filter { record in
            record.sentToPeer && {
                switch record.state {
                case .requesting, .queued, .starting, .transferring: return true
                default: return false
                }
            }()
        }.count

        var perPeerCount: [String: Int] = [:]
        for record in downloads.values where record.sentToPeer {
            switch record.state {
            case .requesting, .queued, .starting, .transferring:
                perPeerCount[record.id.username, default: 0] += 1
            default:
                break
            }
        }

        var remaining: [DownloadID] = []
        for id in stagedDownloadQueue {
            guard let record = downloads[id], !record.sentToPeer else { continue }
            guard case .queued = record.state else { continue }
            let peerCount = perPeerCount[id.username, default: 0]
            if totalRemoteActive < totalRemoteLimit && peerCount < maxQueuedPerPeer {
                totalRemoteActive += 1
                perPeerCount[id.username] = peerCount + 1
                downloads[id]?.state = .requesting
                downloads[id]?.sentToPeer = true
                emitDownload(id)
                requestQueuePlace(id)
            } else {
                remaining.append(id)
            }
        }
        stagedDownloadQueue = remaining
    }

    private func requestQueuePlace(_ id: DownloadID) {
        sendToPeer(
            id.username,
            [.queueUpload(filename: id.path), .placeInQueueRequest(filename: id.path)],
            onSent: { [weak self] in
                guard let self, self.downloads[id]?.state == .requesting else { return }
                self.downloads[id]?.state = .queued(place: nil)
                self.emitDownload(id)
            },
            onFailure: { [weak self] in
                guard let self, self.downloads[id]?.state == .requesting else { return }
                self.downloads[id]?.state = .failed("Couldn't connect to \(id.username)")
                self.downloads[id]?.sentToPeer = false
                self.emitDownload(id)
                self.pumpDownloads()
            }
        )
    }

    private func acceptIncomingTransfer(from username: String, token: UInt32, filename: String, size: UInt64?) {
        let id = DownloadID(username: username, path: filename)
        guard var record = downloads[id] else {
            sendToPeer(username, [.transferResponse(token: token, allowed: false, reason: "Cancelled", size: nil)])
            return
        }
        switch record.state {
        case .completed, .transferring, .paused:
            sendToPeer(username, [.transferResponse(token: token, allowed: false, reason: "Cancelled", size: nil)])
            return
        case .failed:
            // Accept late offers from a peer whose queue finally opened for us.
            break
        default:
            break
        }

        if let size { record.size = size }
        if let oldToken = record.token { downloadsByToken[tokenKey(username, oldToken)] = nil }
        record.token = token
        record.state = .starting
        record.sentToPeer = true
        downloads[id] = record
        downloadsByToken[tokenKey(username, token)] = id
        sendToPeer(username, [.transferResponse(token: token, allowed: true, reason: nil, size: nil)])
        emitDownload(id)

        queue.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, let current = self.downloads[id], current.token == token, current.state == .starting else { return }
            self.downloadsByToken.removeValue(forKey: self.tokenKey(username, token))
            self.downloads[id]?.token = nil
            self.downloads[id]?.sentToPeer = false
            self.downloads[id]?.state = .failed("\(username) never opened the file connection")
            self.emitDownload(id)
            self.pumpDownloads()
        }
    }

    private func openPiercedFile(username: String, ip: String, port: UInt32, token: UInt32) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(truncatingIfNeeded: port)) else {
            sendServer(.cantConnectToPeer(token: token, username: username))
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(ip), port: nwPort, using: Self.tcpParameters(timeout: 10))
        let link = FileLink(username: username, connection: connection, role: .awaitingToken)
        fileLinks[ObjectIdentifier(link)] = link
        var becameReady = false

        connection.stateUpdateHandler = { [weak self, weak link] state in
            guard let self, let link, !link.isClosed else { return }
            switch state {
            case .ready:
                becameReady = true
                connection.send(content: PeerInitMessage.pierceFirewall(token: token).frame,
                                completion: .contentProcessed { _ in })
                self.receive(on: connection, onData: { [weak self, weak link] data in
                    guard let self, let link else { return }
                    self.handleFileData(link, data)
                }, onClose: { [weak self, weak link] error in
                    guard let self, let link else { return }
                    self.closeFile(link, reason: error == nil ? nil : "Connection closed early")
                })
            case .waiting:
                self.queue.asyncAfter(deadline: .now() + 6) { [weak self, weak link] in
                    guard let self, let link, !link.isClosed, !becameReady else { return }
                    self.sendServer(.cantConnectToPeer(token: token, username: username))
                    self.closeFile(link, reason: "Couldn't open file connection")
                }
            case .failed:
                self.sendServer(.cantConnectToPeer(token: token, username: username))
                self.closeFile(link, reason: "Couldn't open file connection")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func handleFileData(_ link: FileLink, _ data: Data) {
        link.lastDataAt = Date()
        switch link.role {
        case .awaitingToken:
            link.pending.append(data)
            guard link.pending.count >= 4 else { return }
            var reader = ByteReader(link.pending)
            guard let token = try? reader.u32() else { return }
            let leftover = reader.rest()
            link.pending = Data()
            beginReceivingFile(link, token: token, leftover: leftover)

        case let .downloading(id):
            writeChunk(data, link: link, id: id)

        case .uploading:
            handleUploadOffset(link, data)
        }
    }

    private func beginReceivingFile(_ link: FileLink, token: UInt32, leftover: Data) {
        guard let id = downloadsByToken[tokenKey(link.username, token)], var record = downloads[id] else {
            log("Unexpected file connection from \(link.username)")
            closeFile(link, reason: nil)
            return
        }

        let partial = partialURL(for: id)
        var offset: UInt64 = 0
        do {
            try FileManager.default.createDirectory(at: incompleteDirectory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: partial.path) {
                FileManager.default.createFile(atPath: partial.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: partial)
            offset = try handle.seekToEnd()
            if record.size > 0 && offset > record.size {
                try handle.truncate(atOffset: 0)
                offset = 0
            }
            link.handle = handle
        } catch {
            record.state = .failed("Can't write file: \(error.localizedDescription)")
            record.sentToPeer = false
            downloads[id] = record
            emitDownload(id)
            closeFile(link, reason: nil)
            pumpDownloads()
            return
        }

        record.received = offset
        record.state = .transferring
        record.bytesPerSecond = 0
        downloads[id] = record
        link.role = .downloading(id)
        link.lastSpeedSampleAt = Date()
        link.bytesSinceSpeedSample = 0

        var writer = ByteWriter()
        writer.u64(offset)
        link.connection.send(content: writer.data, completion: .contentProcessed { _ in })
        emitDownload(id)

        if record.size > 0 && record.received >= record.size {
            finishDownload(link, id: id)
        } else if !leftover.isEmpty {
            writeChunk(leftover, link: link, id: id)
        }
    }

    private func writeChunk(_ data: Data, link: FileLink, id: DownloadID) {
        guard let handle = link.handle, let currentRecord = downloads[id] else {
            closeFile(link, reason: nil)
            return
        }

        // Clamp incoming bytes to expected file size so rogue peers cannot corrupt/inflate the file.
        let chunkToWrite: Data
        if currentRecord.size > 0 {
            let remaining = currentRecord.size > currentRecord.received ? currentRecord.size - currentRecord.received : 0
            if remaining == 0 {
                finishDownload(link, id: id)
                return
            }
            chunkToWrite = UInt64(data.count) > remaining ? data.prefix(Int(remaining)) : data
        } else {
            chunkToWrite = data
        }

        do {
            try handle.write(contentsOf: chunkToWrite)
        } catch {
            downloads[id]?.state = .failed("Write failed: \(error.localizedDescription)")
            downloads[id]?.sentToPeer = false
            downloads[id]?.bytesPerSecond = 0
            emitDownload(id)
            closeFile(link, reason: nil)
            pumpDownloads()
            return
        }

        downloads[id]?.received += UInt64(chunkToWrite.count)
        link.bytesSinceSpeedSample += UInt64(chunkToWrite.count)
        guard let record = downloads[id] else { return }

        if record.size > 0 && record.received >= record.size {
            finishDownload(link, id: id)
            return
        }

        let now = Date()
        let dt = now.timeIntervalSince(link.lastSpeedSampleAt)
        if dt >= 0.4 {
            let instant = Double(link.bytesSinceSpeedSample) / dt
            link.ewmaSpeed = link.ewmaSpeed > 0 ? (link.ewmaSpeed * 0.6 + instant * 0.4) : instant
            link.bytesSinceSpeedSample = 0
            link.lastSpeedSampleAt = now
            downloads[id]?.bytesPerSecond = link.ewmaSpeed
            emitDownload(id)
        }
    }

    private func finishDownload(_ link: FileLink, id: DownloadID) {
        try? link.handle?.close()
        link.handle = nil
        link.isClosed = true
        link.connection.stateUpdateHandler = nil
        link.connection.cancel()
        fileLinks[ObjectIdentifier(link)] = nil

        if let token = downloads[id]?.token {
            downloadsByToken[tokenKey(id.username, token)] = nil
            downloads[id]?.token = nil
        }
        downloads[id]?.sentToPeer = false
        downloads[id]?.bytesPerSecond = 0
        do {
            let destination = try moveToLibrary(partialURL(for: id), id: id)
            downloads[id]?.state = .completed(destination)
            log("Finished \(destination.lastPathComponent)")
        } catch {
            downloads[id]?.state = .failed("Couldn't save file: \(error.localizedDescription)")
        }
        emitDownload(id)
        pumpDownloads()
    }

    private func closeFile(_ link: FileLink, reason: String?) {
        guard !link.isClosed else { return }
        link.isClosed = true
        link.connection.stateUpdateHandler = nil
        link.connection.cancel()
        try? link.handle?.close()
        link.handle = nil
        fileLinks[ObjectIdentifier(link)] = nil

        switch link.role {
        case let .downloading(id):
            guard let record = downloads[id], record.state == .transferring else { return }
            if let token = record.token {
                downloadsByToken.removeValue(forKey: tokenKey(id.username, token))
                downloads[id]?.token = nil
            }
            downloads[id]?.sentToPeer = false
            downloads[id]?.bytesPerSecond = 0

            // Unknown-size transfer that closed cleanly at EOF: finalize as completed.
            if record.size == 0, record.received > 0, reason == nil {
                downloads[id]?.size = record.received
                do {
                    let destination = try moveToLibrary(partialURL(for: id), id: id)
                    downloads[id]?.state = .completed(destination)
                    log("Finished \(destination.lastPathComponent)")
                } catch {
                    downloads[id]?.state = .failed("Couldn't save file: \(error.localizedDescription)")
                }
                emitDownload(id)
                pumpDownloads()
                return
            }

            let percent = record.size > 0 ? Int(Double(record.received) / Double(record.size) * 100) : 0
            downloads[id]?.state = .failed("\(reason ?? "Connection closed early") at \(percent)%")
            emitDownload(id)
            pumpDownloads()
        case let .uploading(token):
            finishUpload(token: token, succeeded: link.uploadDone)
        case .awaitingToken:
            break
        }
    }

    private func partialURL(for id: DownloadID) -> URL {
        incompleteDirectory.appendingPathComponent(MD5.hex(id.username + "\n" + id.path) + ".part")
    }

    private func moveToLibrary(_ source: URL, id: DownloadID) throws -> URL {
        let file = SharedFile(path: id.path, size: 0)
        let folder = downloads[id]?.folderName.map(Self.sanitize)
            ?? Self.libraryFolderName(forRemoteFolder: file.folderName.isEmpty ? id.username : file.folderName)
        let directory = downloadDirectory.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let name = Self.sanitize(file.filename)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var destination = directory.appendingPathComponent(name)
        var counter = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            let candidate = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            destination = directory.appendingPathComponent(candidate)
            counter += 1
        }
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    public static func libraryFolderName(forRemoteFolder name: String) -> String {
        sanitize(name)
    }

    private static func sanitize(_ name: String) -> String {
        let cleaned = name.map { "/:\0".contains($0) ? "_" : $0 }
        let result = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty || result.hasPrefix(".") ? "_" + result : result
    }

    // MARK: - Uploads (Multi-Slot + Indirect Fallback + Clean EOF Shutdown)

    private func enqueueUpload(for username: String, path: String) {
        guard sharingEnabled else {
            sendToPeer(username, [.uploadDenied(filename: path, reason: "Sharing disabled.")])
            return
        }
        guard let share = shares[path] else {
            sendToPeer(username, [.uploadDenied(filename: path, reason: "File not shared.")])
            return
        }
        if activeUploads.values.contains(where: { $0.username == username && $0.path == path }) { return }
        if uploadQueue.contains(where: { $0.username == username && $0.path == path }) { return }
        uploadQueue.append(UploadJob(username: username, path: path, share: share))
        emitUpload(username: username, path: path, state: .queued, sent: 0, size: share.size, speed: 0)
        startNextUploads()
    }

    private func startNextUploads() {
        while activeUploads.count < maxConcurrentUploads, isLoggedIn, !uploadQueue.isEmpty {
            var job = uploadQueue.removeFirst()
            job.token = nextToken()
            activeUploads[job.token] = job
            let token = job.token

            sendToPeer(
                job.username,
                [.transferRequest(direction: .upload, token: token, filename: job.path, size: job.share.size)],
                onFailure: { [weak self] in self?.finishUpload(token: token, succeeded: false) }
            )

            queue.asyncAfter(deadline: .now() + 45) { [weak self] in
                guard let self, let active = self.activeUploads[token], !active.started else { return }
                self.finishUpload(token: token, succeeded: false)
            }
        }
    }

    private func handleUploadResponse(from username: String, token: UInt32, allowed: Bool, reason: String?) {
        guard var job = activeUploads[token], job.username == username, !job.started else { return }
        guard allowed else {
            log("\(username) declined upload: \(reason ?? "no reason")")
            finishUpload(token: token, succeeded: false)
            return
        }
        job.started = true
        activeUploads[token] = job

        resolveAddress(username) { [weak self] address in
            guard let self, self.activeUploads[token] != nil else { return }
            guard let address, let port = NWEndpoint.Port(rawValue: UInt16(truncatingIfNeeded: address.port)) else {
                self.attemptIndirectUploadOrFail(job)
                return
            }
            let connection = NWConnection(host: NWEndpoint.Host(address.ip), port: port, using: Self.tcpParameters(timeout: 6))
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, self.activeUploads[token] != nil else {
                    connection.cancel()
                    return
                }
                switch state {
                case .ready:
                    self.attachUploadConnection(job: job, connection: connection, sendPeerInit: true, leftover: Data())
                case .waiting, .failed:
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    self.attemptIndirectUploadOrFail(job)
                default:
                    break
                }
            }
            connection.start(queue: self.queue)
        }
    }

    private func attemptIndirectUploadOrFail(_ job: UploadJob) {
        guard isLoggedIn, activeListenPort > 0, activeUploads[job.token] != nil else {
            finishUpload(token: job.token, succeeded: false)
            return
        }
        let pierceToken = nextToken()
        pendingIndirectFiles[pierceToken] = job
        sendServer(.connectToPeer(token: pierceToken, username: job.username, type: .file))
        queue.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, let pending = self.pendingIndirectFiles.removeValue(forKey: pierceToken) else { return }
            self.finishUpload(token: pending.token, succeeded: false)
        }
    }

    private func attachUploadConnection(job: UploadJob, connection: NWConnection, sendPeerInit: Bool, leftover: Data) {
        let link = FileLink(username: job.username, connection: connection, role: .uploading(job.token))
        fileLinks[ObjectIdentifier(link)] = link

        connection.stateUpdateHandler = { [weak self, weak link] state in
            guard let self, let link, !link.isClosed else { return }
            if case .failed = state {
                self.closeFile(link, reason: nil)
            }
        }

        var writer = ByteWriter()
        if sendPeerInit {
            writer.raw(PeerInitMessage.peerInit(username: username, type: "F").frame)
        }
        writer.u32(job.token)
        connection.send(content: writer.data, completion: .contentProcessed { _ in })

        if !leftover.isEmpty {
            handleFileData(link, leftover)
        }
        guard !link.isClosed else { return }
        receive(on: connection, onData: { [weak self, weak link] data in
            guard let self, let link else { return }
            self.handleFileData(link, data)
        }, onClose: { [weak self, weak link] _ in
            guard let self, let link else { return }
            self.closeFile(link, reason: nil)
        })
    }

    private func handleUploadOffset(_ link: FileLink, _ data: Data) {
        guard link.handle == nil, !link.uploadDone else { return }
        guard case let .uploading(token) = link.role, let job = activeUploads[token] else {
            closeFile(link, reason: nil)
            return
        }
        link.pending.append(data)
        guard link.pending.count >= 8 else { return }
        var reader = ByteReader(link.pending)
        guard let offset = try? reader.u64() else { return }
        link.pending = Data()

        do {
            let handle = try FileHandle(forReadingFrom: job.share.url)
            let start = min(offset, job.share.size)
            try handle.seek(toOffset: start)
            link.handle = handle
            link.sentBytes = start
            link.lastSpeedSampleAt = Date()
            link.bytesSinceSpeedSample = 0
        } catch {
            closeFile(link, reason: nil)
            return
        }
        emitUpload(username: job.username, path: job.path, state: .transferring, sent: link.sentBytes, size: job.share.size, speed: 0)
        sendNextUploadChunk(link, token: token)
    }

    private func sendNextUploadChunk(_ link: FileLink, token: UInt32) {
        guard !link.isClosed, let handle = link.handle else { return }
        let chunk: Data
        do {
            chunk = try autoreleasepool {
                try handle.read(upToCount: 256 * 1024) ?? Data()
            }
        } catch {
            closeFile(link, reason: nil)
            return
        }
        if chunk.isEmpty {
            link.uploadDone = true
            try? handle.close()
            link.handle = nil
            // Flush final FIN and guarantee slot release even if downloader delays closing socket.
            link.connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self, weak link] _ in
                guard let self, let link else { return }
                self.queue.asyncAfter(deadline: .now() + 2) { [weak self, weak link] in
                    guard let self, let link, !link.isClosed else { return }
                    self.closeFile(link, reason: nil)
                }
            })
            return
        }
        link.connection.send(content: chunk, completion: .contentProcessed { [weak self, weak link] error in
            guard let self, let link, !link.isClosed else { return }
            if error != nil {
                self.closeFile(link, reason: nil)
            } else {
                link.sentBytes += UInt64(chunk.count)
                link.bytesSinceSpeedSample += UInt64(chunk.count)
                let now = Date()
                let dt = now.timeIntervalSince(link.lastSpeedSampleAt)
                if dt >= 0.5, let job = self.activeUploads[token] {
                    let instant = Double(link.bytesSinceSpeedSample) / dt
                    link.ewmaSpeed = link.ewmaSpeed > 0 ? (link.ewmaSpeed * 0.6 + instant * 0.4) : instant
                    link.bytesSinceSpeedSample = 0
                    link.lastSpeedSampleAt = now
                    if link.ewmaSpeed > 0 {
                        self.averageUploadSpeed = UInt32(min(link.ewmaSpeed, Double(UInt32.max)))
                    }
                    self.emitUpload(
                        username: job.username,
                        path: job.path,
                        state: .transferring,
                        sent: link.sentBytes,
                        size: job.share.size,
                        speed: link.ewmaSpeed
                    )
                }
                self.sendNextUploadChunk(link, token: token)
            }
        })
    }

    private func finishUpload(token: UInt32, succeeded: Bool) {
        guard let job = activeUploads.removeValue(forKey: token) else { return }
        emitUpload(
            username: job.username,
            path: job.path,
            state: succeeded ? .completed : .failed,
            sent: succeeded ? job.share.size : 0,
            size: job.share.size,
            speed: 0
        )
        if succeeded {
            completedUploads += 1
            log("Uploaded \(job.path) to \(job.username)")
        } else if job.started && isLoggedIn {
            sendToPeer(job.username, [.uploadFailed(filename: job.path)])
        }
        startNextUploads()
    }

    private func sharedFolders() -> [SharedFolder] {
        guard sharingEnabled else { return [] }
        var grouped: [String: [SharedFile]] = [:]
        for share in shares.values {
            let parts = Self.splitVirtualPath(share.virtualPath)
            grouped[parts.folder, default: []].append(SharedFile(path: parts.name, size: share.size))
        }
        return grouped.keys.sorted().map { SharedFolder(name: $0, files: grouped[$0] ?? []) }
    }

    private static func splitVirtualPath(_ path: String) -> (folder: String, name: String) {
        guard let separator = path.lastIndex(of: "\\") else { return ("", path) }
        return (String(path[..<separator]), String(path[path.index(after: separator)...]))
    }

    // MARK: - Helpers

    private func nextToken() -> UInt32 {
        UInt32.random(in: 1..<UInt32.max)
    }

    private func receive(on connection: NWConnection, onData: @escaping (Data) -> Void, onClose: @escaping (NWError?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty { onData(data) }
            if isComplete || error != nil {
                onClose(error)
                return
            }
            self?.receive(on: connection, onData: onData, onClose: onClose)
        }
    }

    private static func tcpParameters(timeout: Int) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60
        tcp.connectionTimeout = timeout
        tcp.noDelay = true
        return NWParameters(tls: nil, tcp: tcp)
    }

    private func tokenKey(_ username: String, _ token: UInt32) -> String { "\(username)|\(token)" }

    private func emitUpload(username: String, path: String, state: UploadState, sent: UInt64, size: UInt64, speed: Double) {
        emit(.upload(UploadUpdate(id: DownloadID(username: username, path: path), state: state, sent: sent, size: size, bytesPerSecond: speed)))
    }

    private func emitDownload(_ id: DownloadID) {
        guard let record = downloads[id] else { return }
        emit(.download(DownloadUpdate(id: id, state: record.state, received: record.received, size: record.size, bytesPerSecond: record.bytesPerSecond)))
    }

    private func log(_ message: String) { emit(.log(message)) }

    private func emit(_ event: ClientEvent) {
        let handler = onEvent
        DispatchQueue.main.async { handler?(event) }
    }
}

private struct PeerAddress {
    let ip: String
    let port: UInt32
}

private struct CachedAddress {
    let address: PeerAddress
    let cachedAt: Date
}

private final class IncomingConnection {
    let connection: NWConnection
    var frames = FrameBuffer()

    init(connection: NWConnection) {
        self.connection = connection
    }

    func cancel() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}

private final class PeerLink {
    let username: String
    var connection: NWConnection?
    var frames = FrameBuffer()
    var isReady = false
    var isClosed = false
    var triedIndirect = false
    var indirectToken: UInt32?
    var lastActivity = Date()
    var outbox: [Data] = []
    var sentHandlers: [() -> Void] = []
    var failureHandlers: [() -> Void] = []

    init(username: String) {
        self.username = username
    }
}

private final class FileLink {
    enum Role {
        case awaitingToken
        case downloading(DownloadID)
        case uploading(UInt32)
    }

    let username: String
    let connection: NWConnection
    var role: Role
    var pending = Data()
    var handle: FileHandle?
    var isClosed = false
    var uploadDone = false
    var sentBytes: UInt64 = 0
    var lastDataAt = Date()
    var lastSpeedSampleAt = Date()
    var bytesSinceSpeedSample: UInt64 = 0
    var ewmaSpeed: Double = 0

    init(username: String, connection: NWConnection, role: Role) {
        self.username = username
        self.connection = connection
        self.role = role
    }
}

private struct DownloadRecord {
    let id: DownloadID
    var state: DownloadState
    var size: UInt64
    var received: UInt64 = 0
    var token: UInt32?
    var retries = 0
    var folderName: String?
    var sentToPeer = false
    var bytesPerSecond: Double = 0
}

private struct FolderBrowse {
    let username: String
    let folder: String
    let completion: ([SharedFile]?) -> Void
}

private struct UploadJob {
    let username: String
    let path: String
    let share: LocalShare
    var token: UInt32 = 0
    var started = false
}
#endif
