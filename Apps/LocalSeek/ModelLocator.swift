import Foundation
import CryptoKit

/// Findet das GGUF-Embedding-Modell lokal (SPEC §9: kein Auto-Download).
/// Standardort: ~/Library/Application Support/LocalSeek/models/.
enum ModelLocator {
    static func modelsDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("LocalSeek/models", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Bevorzugt das zuletzt aktivierte Modell; sonst stabile Reihenfolge.
    static func installedModel(preferredName: String? = nil, in directory: URL? = nil) throws -> URL? {
        let dir = try directory ?? modelsDirectory()
        let models = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "gguf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return models.first { $0.lastPathComponent == preferredName } ?? models.first
            ?? (directory == nil ? Bundle.main.url(forResource: "multilingual-e5-small-q8_0", withExtension: "gguf", subdirectory: "Models") : nil)
    }

    /// Kopiert eine vom Nutzer gewählte GGUF-Datei in den Modellordner.
    static func install(from source: URL, into directory: URL? = nil) throws -> URL {
        let dir = try directory ?? modelsDirectory()
        let dest = dir.appendingPathComponent(source.lastPathComponent)
        guard source.resolvingSymlinksInPath().standardizedFileURL != dest.resolvingSymlinksInPath().standardizedFileURL else {
            return dest
        }
        let staging = dir.appendingPathComponent(".\(UUID().uuidString).pending")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        if FileManager.default.fileExists(atPath: dest.path) {
            _ = try FileManager.default.replaceItemAt(dest, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: dest)
        }
        return dest
    }

    static func checksum(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
