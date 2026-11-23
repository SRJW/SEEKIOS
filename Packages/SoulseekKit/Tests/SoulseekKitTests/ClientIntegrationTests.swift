#if canImport(Network)
import Foundation
import Network
import XCTest
@testable import SoulseekKit

/// End-to-end loopback TCP integration tests exercising `SoulseekClient` against a real
/// in-process mock Soulseek server and mock peer on `127.0.0.1`.
final class ClientIntegrationTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("soulseek-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    private func makeClient() -> SoulseekClient {
        let dl = tempRoot.appendingPathComponent("Music", isDirectory: true)
        let inc = tempRoot.appendingPathComponent("Incomplete", isDirectory: true)
        try? FileManager.default.createDirectory(at: dl, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: inc, withIntermediateDirectories: true)
        let client = SoulseekClient(downloadDirectory: dl, incompleteDirectory: inc)
        client.serverHost = "127.0.0.1"
        client.advertisedPort = 0
        return client
    }

    /// Regression test: the official Soulseek server does NOT send a pong for ServerPing (32).
    /// Ensure the client remains logged in and does NOT tear down waiting for a pong.
    func testLoginAndSharingDisabledReportsZeroShares() throws {
        let server = try MockSoulseekServer()
        defer { server.stop() }

        let loggedInExp = expectation(description: "Client logs in")
        let shareCountsExp = expectation(description: "Server receives 0 shared files when sharing disabled")
        var receivedShareCounts: (UInt32, UInt32)?

        server.onServerFrame = { code, reader in
            if code == 35 { // SharedFoldersFiles
                let folders = (try? reader.u32()) ?? 99
                let files = (try? reader.u32()) ?? 99
                if receivedShareCounts == nil {
                    receivedShareCounts = (folders, files)
                    shareCountsExp.fulfill()
                }
            }
        }

        let client = makeClient()
        client.serverPort = server.port
        client.configure(
            maxConcurrentDownloads: 4,
            maxConcurrentUploads: 2,
            maxQueuedPerPeer: 10,
            sharingEnabled: false,
            distributedSearchEnabled: false
        )

        // Register a fake local share — must NOT be announced while sharingEnabled == false.
        let dummyFile = tempRoot.appendingPathComponent("secret.flac")
        try Data(repeating: 0xAA, count: 1024).write(to: dummyFile)
        client.updateShares([LocalShare(virtualPath: "Music\\Album\\secret.flac", url: dummyFile, size: 1024)])

        var didDisconnect = false
        client.onEvent = { event in
            switch event {
            case .state(.loggedIn):
                loggedInExp.fulfill()
            case .state(.failed):
                didDisconnect = true
            default:
                break
            }
        }

        client.connect(username: "seekios_tester", password: "pw")
        wait(for: [loggedInExp, shareCountsExp], timeout: 5)

        XCTAssertEqual(receivedShareCounts?.0, 0)
        XCTAssertEqual(receivedShareCounts?.1, 0)
        XCTAssertFalse(didDisconnect)
        client.disconnect()
    }

    /// End-to-end indirect file transfer (`ConnectToPeer` type "F" + `PierceFirewall`) verifying
    /// exact byte-for-byte download integrity.
    func testIndirectFileDownloadByteForByte() throws {
        let payload = Data((0..<(128 * 1024)).map { UInt8($0 & 0xFF) })
        let remotePath = "@@music\\TestAlbum\\01 Test Track.flac"

        let server = try MockSoulseekServer()
        defer { server.stop() }
        let peer = try MockSoulseekPeer(
            username: "mockpeer",
            filePath: remotePath,
            payload: payload,
            mode: .indirectFile(server: server)
        )
        defer { peer.stop() }
        server.peerAddresses["mockpeer"] = ("127.0.0.1", UInt32(peer.port))

        let loggedInExp = expectation(description: "Logged in")
        let completedExp = expectation(description: "Download completed")
        var completedURL: URL?

        let client = makeClient()
        client.serverPort = server.port
        client.onEvent = { event in
            switch event {
            case .state(.loggedIn):
                loggedInExp.fulfill()
            case let .download(update):
                if case let .completed(url) = update.state {
                    completedURL = url
                    completedExp.fulfill()
                }
            default:
                break
            }
        }

        client.connect(username: "seekios_tester", password: "pw")
        wait(for: [loggedInExp], timeout: 5)

        client.download(username: "mockpeer", file: SharedFile(path: remotePath, size: UInt64(payload.count)))
        wait(for: [completedExp], timeout: 10)

        let savedURL = try XCTUnwrap(completedURL)
        let savedData = try Data(contentsOf: savedURL)
        XCTAssertEqual(savedData, payload)
        client.disconnect()
    }

    /// End-to-end pause + resume test: peer drips first half, client pauses keeping `.part`,
    /// then resumes sending non-zero `u64(offset)` and receives exact remaining bytes.
    func testDownloadPausePreservesPartialAndResumesFromOffset() throws {
        let payload = Data((0..<(192 * 1024)).map { UInt8(($0 * 7) & 0xFF) })
        let remotePath = "@@music\\ResumeAlbum\\02 Resume Track.flac"
        let firstChunkLimit = 64 * 1024

        let server = try MockSoulseekServer()
        defer { server.stop() }
        let peer = try MockSoulseekPeer(
            username: "resumepeer",
            filePath: remotePath,
            payload: payload,
            mode: .indirectStalledThenResume(server: server, firstSendLimit: firstChunkLimit)
        )
        defer { peer.stop() }
        server.peerAddresses["resumepeer"] = ("127.0.0.1", UInt32(peer.port))

        let loggedInExp = expectation(description: "Logged in")
        let pausedExp = expectation(description: "Paused with partial bytes")
        let completedExp = expectation(description: "Resumed and completed")
        var didTriggerPause = false
        var completedURL: URL?

        let client = makeClient()
        client.serverPort = server.port
        let downloadID = DownloadID(username: "resumepeer", path: remotePath)

        client.onEvent = { event in
            switch event {
            case .state(.loggedIn):
                loggedInExp.fulfill()
            case let .download(update) where update.id == downloadID:
                if !didTriggerPause, update.state == .transferring, update.received >= UInt64(firstChunkLimit) {
                    didTriggerPause = true
                    client.pause(downloadID)
                } else if update.state == .paused, didTriggerPause {
                    pausedExp.fulfill()
                } else if case let .completed(url) = update.state {
                    completedURL = url
                    completedExp.fulfill()
                }
            default:
                break
            }
        }

        client.connect(username: "seekios_tester", password: "pw")
        wait(for: [loggedInExp], timeout: 5)

        client.download(username: "resumepeer", file: SharedFile(path: remotePath, size: UInt64(payload.count)))
        wait(for: [pausedExp], timeout: 10)

        let partialBytes = client.partialBytesOnDisk(username: "resumepeer", path: remotePath)
        XCTAssertGreaterThanOrEqual(partialBytes, UInt64(firstChunkLimit))

        // Resume download from partial offset.
        client.retry(downloadID, size: UInt64(payload.count))
        wait(for: [completedExp], timeout: 10)

        XCTAssertGreaterThanOrEqual(peer.lastReceivedOffset, UInt64(firstChunkLimit))
        let savedURL = try XCTUnwrap(completedURL)
        let savedData = try Data(contentsOf: savedURL)
        XCTAssertEqual(savedData, payload)
        client.disconnect()
    }
}

// MARK: - Loopback Mock Soulseek Server & Peer

private final class MockSoulseekServer: @unchecked Sendable {
    private(set) var port: UInt16 = 0
    var peerAddresses: [String: (String, UInt32)] = [:]
    var onServerFrame: ((UInt32, inout ByteReader) -> Void)?

    private let queue = DispatchQueue(label: "test.mock.server")
    private let listener: NWListener
    private var clientConn: NWConnection?
    private var frames = FrameBuffer()

    init() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        var boundPort: UInt16 = 0
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                boundPort = listener.port?.rawValue ?? 0
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.start(queue: queue)
        ready.wait()
        self.port = boundPort
    }

    func stop() {
        queue.sync {
            clientConn?.cancel()
            clientConn = nil
            listener.cancel()
        }
    }

    func sendConnectToPeer(username: String, type: String, ip: String, port: UInt32, token: UInt32) {
        queue.async {
            var w = ByteWriter()
            w.string(username)
            w.string(type)
            let parts = ip.split(separator: ".").compactMap { UInt32($0) }
            let ipVal = (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
            w.u32(ipVal)
            w.u32(port)
            w.u32(token)
            let frame = ByteWriter.frame(code: 18, payload: w.data)
            self.clientConn?.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    private func accept(_ conn: NWConnection) {
        clientConn = conn
        frames = FrameBuffer()
        conn.start(queue: queue)
        readLoop(conn)
    }

    private func readLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.frames.append(data)
                while let body = try? self.frames.nextFrame() {
                    self.handleFrame(body, on: conn)
                }
            }
            if !isComplete && error == nil {
                self.readLoop(conn)
            }
        }
    }

    private func handleFrame(_ body: Data, on conn: NWConnection) {
        var reader = ByteReader(body)
        guard let code = try? reader.u32() else { return }
        onServerFrame?(code, &reader)

        switch code {
        case 1: // Login
            var w = ByteWriter()
            w.bool(true)
            w.string("Welcome to MockServer")
            w.u32((127 << 24) | 1)
            conn.send(content: ByteWriter.frame(code: 1, payload: w.data), completion: .contentProcessed { _ in })
        case 3: // GetPeerAddress
            var r = ByteReader(body)
            _ = try? r.u32()
            let user = (try? r.string()) ?? ""
            let addr = peerAddresses[user] ?? ("0.0.0.0", 0)
            let parts = addr.0.split(separator: ".").compactMap { UInt32($0) }
            let ipVal = parts.count == 4 ? (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3] : 0
            var w = ByteWriter()
            w.string(user)
            w.u32(ipVal)
            w.u32(addr.1)
            conn.send(content: ByteWriter.frame(code: 3, payload: w.data), completion: .contentProcessed { _ in })
        case 5: // WatchUser
            var r = ByteReader(body)
            _ = try? r.u32()
            let user = (try? r.string()) ?? ""
            var w = ByteWriter()
            w.string(user)
            w.bool(true)
            w.u32(2) // Online
            conn.send(content: ByteWriter.frame(code: 5, payload: w.data), completion: .contentProcessed { _ in })
        default:
            break
        }
    }
}

private final class MockSoulseekPeer: @unchecked Sendable {
    enum Mode {
        case indirectFile(server: MockSoulseekServer)
        case indirectStalledThenResume(server: MockSoulseekServer, firstSendLimit: Int)
    }

    private(set) var port: UInt16 = 0
    var lastReceivedOffset: UInt64 = 0

    private let username: String
    private let filePath: String
    private let payload: Data
    private let mode: Mode
    private let queue = DispatchQueue(label: "test.mock.peer")
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var transferToken: UInt32 = 777
    private var pierceToken: UInt32 = 888
    private var transferAttempt = 0

    init(username: String, filePath: String, payload: Data, mode: Mode) throws {
        self.username = username
        self.filePath = filePath
        self.payload = payload
        self.mode = mode

        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        var boundPort: UInt16 = 0
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                boundPort = listener.port?.rawValue ?? 0
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.start(queue: queue)
        ready.wait()
        self.port = boundPort
    }

    func stop() {
        queue.sync {
            connections.forEach { $0.cancel() }
            connections.removeAll()
            listener.cancel()
        }
    }

    private func accept(_ conn: NWConnection) {
        connections.append(conn)
        conn.start(queue: queue)
        var frames = FrameBuffer()
        var isPeerConnection = false
        var isFileConnection = false
        var fileOffsetBuf = Data()

        func receiveNext() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    if isFileConnection {
                        fileOffsetBuf.append(data)
                        if fileOffsetBuf.count >= 8 {
                            var r = ByteReader(fileOffsetBuf)
                            let offset = (try? r.u64()) ?? 0
                            self.lastReceivedOffset = offset
                            self.streamFile(on: conn, from: Int(offset))
                            return
                        }
                    } else {
                        frames.append(data)
                        while let body = try? frames.nextFrame() {
                            if !isPeerConnection {
                                if let initMsg = try? PeerInitMessage.decode(body) {
                                    switch initMsg {
                                    case .peerInit(_, let type) where type == "P":
                                        isPeerConnection = true
                                    case .pierceFirewall:
                                        isFileConnection = true
                                        var tw = ByteWriter()
                                        tw.u32(self.transferToken)
                                        conn.send(content: tw.data, completion: .contentProcessed { _ in })
                                        let rest = frames.drain()
                                        if !rest.isEmpty {
                                            fileOffsetBuf.append(rest)
                                            if fileOffsetBuf.count >= 8 {
                                                var r = ByteReader(fileOffsetBuf)
                                                let offset = (try? r.u64()) ?? 0
                                                self.lastReceivedOffset = offset
                                                self.streamFile(on: conn, from: Int(offset))
                                                return
                                            }
                                        }
                                    default:
                                        break
                                    }
                                }
                            } else if let msg = try? PeerMessage.decode(body) {
                                self.handlePeerMessage(msg, on: conn)
                            }
                        }
                    }
                }
                if !isComplete && error == nil {
                    receiveNext()
                }
            }
        }
        receiveNext()
    }

    private func handlePeerMessage(_ msg: PeerMessage, on conn: NWConnection) {
        switch msg {
        case .queueUpload(let path) where path == filePath:
            transferAttempt += 1
            transferToken += 1
            pierceToken += 1
            let offer = PeerMessage.transferRequest(
                direction: .upload,
                token: transferToken,
                filename: filePath,
                size: UInt64(payload.count)
            )
            if let frame = try? offer.frame() {
                conn.send(content: frame, completion: .contentProcessed { _ in })
            }
        case let .transferResponse(token, allowed, _, _) where token == transferToken && allowed:
            switch mode {
            case let .indirectFile(server), let .indirectStalledThenResume(server, _):
                server.sendConnectToPeer(
                    username: username,
                    type: "F",
                    ip: "127.0.0.1",
                    port: UInt32(port),
                    token: pierceToken
                )
            }
        default:
            break
        }
    }

    private func streamFile(on conn: NWConnection, from offset: Int) {
        guard offset < payload.count else {
            conn.cancel()
            return
        }
        switch mode {
        case .indirectFile:
            let slice = payload.subdata(in: offset..<payload.count)
            conn.send(content: slice, completion: .contentProcessed { _ in })
        case let .indirectStalledThenResume(_, firstSendLimit):
            if transferAttempt == 1 {
                let end = min(offset + firstSendLimit, payload.count)
                let split = max(offset, end - 1024)
                let firstPart = payload.subdata(in: offset..<split)
                let tailPart = payload.subdata(in: split..<end)
                conn.send(content: firstPart, completion: .contentProcessed { [weak self] _ in
                    self?.queue.asyncAfter(deadline: .now() + 0.5) {
                        conn.send(content: tailPart, completion: .contentProcessed { _ in
                            // Hold connection open after first chunk so client receives progress update and pauses.
                        })
                    }
                })
            } else {
                let slice = payload.subdata(in: offset..<payload.count)
                conn.send(content: slice, completion: .contentProcessed { _ in })
            }
        }
    }
}
#endif
