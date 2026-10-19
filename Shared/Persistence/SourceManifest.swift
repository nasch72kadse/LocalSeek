import Foundation

/// A separate, owner-readable list of explicitly approved roots makes a corrupt
/// derived SQLite index recoverable without silently expanding the search scope.
public enum SourceManifest {
    private static func url(for databaseURL: URL) -> URL {
        databaseURL.deletingLastPathComponent().appendingPathComponent("sources.json", isDirectory: false)
    }
    public static func save(_ sources: [SourceRecord], for databaseURL: URL) throws {
        let dest = url(for: databaseURL)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(sources)
        try data.write(to: dest, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
    }
    public static func load(for databaseURL: URL) throws -> [SourceRecord] {
        let source = url(for: databaseURL)
        guard FileManager.default.fileExists(atPath: source.path) else { return [] }
        return try JSONDecoder().decode([SourceRecord].self, from: Data(contentsOf: source))
    }
}
