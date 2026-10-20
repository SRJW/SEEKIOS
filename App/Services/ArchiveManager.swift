import Foundation

enum ArchiveManager {
    /// Descomprime un archivo .zip en una carpeta con su mismo nombre
    static func unzipFile(at sourceURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let destinationFolder = sourceURL.deletingPathExtension()

            do {
                if !fm.fileExists(atPath: destinationFolder.path) {
                    try fm.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
                }

                // Descompresión nativa de iOS mediante FileManager
                try fm.unzipItem(at: sourceURL, to: destinationFolder)

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
}
