import Foundation

/// Reassembles length-prefixed frames from a TCP byte stream in O(n) amortized time.
///
/// Server, peer-init, peer, and distributed messages all start with a uint32 length;
/// the returned frame body is everything after it (message code + payload).
public struct FrameBuffer {
    /// Peers can legitimately send large shared file lists, but nothing near this.
    public static let maxFrameSize = 256 * 1024 * 1024

    private var buffer = Data()
    private var readOffset = 0

    public init() {}

    public var bufferedCount: Int { buffer.count - readOffset }

    public mutating func append(_ data: Data) {
        if readOffset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
        }
        buffer.append(data)
    }

    public mutating func nextFrame() throws -> Data? {
        guard bufferedCount >= 4 else { return nil }
        let base = buffer.startIndex + readOffset
        var length = 0
        for index in 0..<4 {
            length |= Int(buffer[base + index]) << (8 * index)
        }
        guard length <= FrameBuffer.maxFrameSize else { throw ProtocolError.frameTooLarge(length) }
        guard bufferedCount >= 4 + length else { return nil }

        let bodyStart = base + 4
        let bodyEnd = bodyStart + length
        let body = Data(buffer[bodyStart..<bodyEnd])
        readOffset += 4 + length

        if readOffset == buffer.count {
            buffer.removeAll(keepingCapacity: buffer.count <= 256 * 1024)
            readOffset = 0
        } else if readOffset >= 64 * 1024 && readOffset * 2 >= buffer.count {
            buffer = Data(buffer[(buffer.startIndex + readOffset)..<buffer.endIndex])
            readOffset = 0
        }
        return body
    }

    /// Hands over whatever is buffered (used when a connection switches to raw file data).
    public mutating func drain() -> Data {
        guard bufferedCount > 0 else {
            buffer = Data()
            readOffset = 0
            return Data()
        }
        let rest = Data(buffer[(buffer.startIndex + readOffset)..<buffer.endIndex])
        buffer = Data()
        readOffset = 0
        return rest
    }
}

extension ByteWriter {
    /// uint32 length + uint32 code + payload (server and peer messages).
    static func frame(code: UInt32, payload: Data) -> Data {
        var writer = ByteWriter()
        writer.u32(UInt32(payload.count + 4))
        writer.u32(code)
        writer.raw(payload)
        return writer.data
    }

    /// uint32 length + uint8 code + payload (peer init and distributed messages).
    static func initFrame(code: UInt8, payload: Data) -> Data {
        var writer = ByteWriter()
        writer.u32(UInt32(payload.count + 1))
        writer.u8(code)
        writer.raw(payload)
        return writer.data
    }
}
