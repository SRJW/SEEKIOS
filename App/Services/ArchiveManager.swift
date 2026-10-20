import Compression
import Foundation

enum ArchiveManager {
    enum UnzipError: LocalizedError {
        case invalidArchive
        var errorDescription: String? { "Invalid or unsupported ZIP archive." }
    }

    /// Descomprime un archivo .zip de forma 100% nativa en iOS usando el módulo Compression
    static func unzipFile(at sourceURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let destinationFolder = sourceURL.deletingPathExtension()

            do {
                let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
                try fm.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
                try extractZipEntries(from: data, to: destinationFolder)

                DispatchQueue.main.async {
                    completion(.success(destinationFolder))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    private static func extractZipEntries(from data: Data, to destination: URL) throws {
        let fm = FileManager.default
        var offset = 0
        let count = data.count

        // Recorre las cabeceras Local File Header del estándar ZIP (0x04034b50)
        while offset + 30 <= count {
            let sig = readUInt32(data, at: offset)
            if sig != 0x04034b50 { break }

            let flags = readUInt16(data, at: offset + 6)
            let method = readUInt16(data, at: offset + 8)
            let compSize = Int(readUInt32(data, at: offset + 18))
            let uncompSize = Int(readUInt32(data, at: offset + 22))
            let nameLen = Int(readUInt16(data, at: offset + 26))
            let extraLen = Int(readUInt16(data, at: offset + 28))

            let headerEnd = offset + 30
            guard headerEnd + nameLen + extraLen <= count else { break }

            let nameData = data.subdata(in: headerEnd ..< (headerEnd + nameLen))
            let rawName = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1)
                ?? "file_\(offset)"

            let dataStart = headerEnd + nameLen + extraLen
            let dataEnd = dataStart + compSize
            guard dataEnd <= count else { break }

            // Limpia rutas relativas por seguridad
            let cleanPath = rawName
                .replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/")
                .filter { $0 != ".." && $0 != "." }
                .joined(separator: "/")

            if !cleanPath.isEmpty {
                let targetURL = destination.appendingPathComponent(cleanPath)
                if rawName.hasSuffix("/") {
                    try fm.createDirectory(at: targetURL, withIntermediateDirectories: true)
                } else {
                    try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let payload = data.subdata(in: dataStart ..< dataEnd)

                    if method == 0 {
                        // Sin compresión (Stored)
                        try payload.write(to: targetURL, options: .atomic)
                    } else if method == 8 {
                        // Comprimido con Deflate (ZLIB raw)
                        let outData = try inflateRawDeflate(payload, expectedSize: max(uncompSize, compSize * 2))
                        try outData.write(to: targetURL, options: .atomic)
                    }
                }
            }

            offset = dataEnd
            // Si el bit 3 de flags está activo y el tamaño era 0, salta el Data Descriptor de 12/16 bytes
            if (flags & 0x0008) != 0 && compSize == 0 {
                break
            }
        }
    }

    private static func inflateRawDeflate(_ input: Data, expectedSize: Int) throws -> Data {
        if input.isEmpty { return Data() }
        var capacity = max(expectedSize, 4096)
        let maxCapacity = max(expectedSize * 4, 64 * 1024 * 1024)

        while capacity <= maxCapacity {
            var output = Data(count: capacity)
            let decodedBytes = input.withUnsafeBytes { srcPtr -> Int in
                output.withUnsafeMutableBytes { dstPtr -> Int in
                    guard let src = srcPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let dst = dstPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                    return compression_decode_buffer(dst, capacity, src, input.count, nil, COMPRESSION_ZLIB)
                }
            }
            if decodedBytes > 0 && decodedBytes < capacity {
                output.count = decodedBytes
                return output
            } else if decodedBytes == capacity && capacity == expectedSize {
                return output
            }
            capacity *= 2
        }
        throw UnzipError.invalidArchive
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        let b0 = UInt16(data[offset])
        let b1 = UInt16(data[offset + 1]) << 8
        return b0 | b1
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1]) << 8
        let b2 = UInt32(data[offset + 2]) << 16
        let b3 = UInt32(data[offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }
}
