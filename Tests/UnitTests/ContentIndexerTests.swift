import XCTest
@testable import SharedCore

/// Verifiziert die End-to-End-Verdrahtung Scan → Extraktion → Chunk-Persistenz
/// (`ContentIndexer`): neue Dateien werden indiziert und volltextdurchsuchbar,
/// unveränderte Dateien nicht erneut extrahiert, geänderte Dateien aufgefrischt,
/// nicht unterstützte Endungen übersprungen.
final class ContentIndexerTests: XCTestCase {

    private let scanner = DirectoryScanner()
    private let indexer = ContentIndexer()

    private func makeDB() throws -> IndexDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("localseek-ci-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("index.sqlite")
        return try IndexDatabase(url: url)
    }

    /// Legt einen temporären Quellordner an und schreibt die angegebenen Dateien hinein.
    private func makeSource(_ files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("localseek-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, content) in files {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }
        return dir
    }

    private func setMTime(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    func testScanThenIndexMakesContentSearchable() async throws {
        let db = try makeDB()
        let dir = try makeSource([
            "notiz.txt": "Das Quartalsergebnis war hervorragend.",
            "readme.md": "# Titel\n\nDer Zahlungsverkehr ist stabil.",
        ])
        let source = SourceRecord(id: dir.path, path: dir.path)
        try db.upsertSource(source)
        try scanner.scan(source: source, into: db)

        let processed = try await indexer.indexContent(source: source, into: db)
        XCTAssertEqual(processed, 2)
        XCTAssertGreaterThan(try db.chunkCount(), 0)

        XCTAssertEqual(try db.searchChunks("Quartalsergebnis").count, 1)
        let mdHit = try XCTUnwrap(try db.searchChunks("Zahlungsverkehr").first)
        XCTAssertEqual(mdHit.filename, "readme.md")
    }

    /// Zweiter Lauf ohne Änderungen extrahiert nichts erneut (Stempel greift).
    func testUnchangedFilesAreNotReindexed() async throws {
        let db = try makeDB()
        let dir = try makeSource(["a.txt": "Inhalt eins", "b.txt": "Inhalt zwei"])
        let source = SourceRecord(id: dir.path, path: dir.path)
        try db.upsertSource(source)
        try scanner.scan(source: source, into: db)

        let processedFirst = try await indexer.indexContent(source: source, into: db)
        XCTAssertEqual(processedFirst, 2)
        let countAfterFirst = try db.chunkCount()
        let processedSecond = try await indexer.indexContent(source: source, into: db)
        XCTAssertEqual(processedSecond, 0)
        XCTAssertEqual(try db.chunkCount(), countAfterFirst)
    }

    /// Eine geänderte Datei (neuer mtime + neuer Inhalt) wird neu extrahiert.
    func testChangedFileIsReindexed() async throws {
        let db = try makeDB()
        let dir = try makeSource(["doc.txt": "alter Begriff Apfel"])
        let fileURL = dir.appendingPathComponent("doc.txt")
        try setMTime(fileURL, Date(timeIntervalSince1970: 1_000_000))
        let source = SourceRecord(id: dir.path, path: dir.path)
        try db.upsertSource(source)
        try scanner.scan(source: source, into: db)
        _ = try await indexer.indexContent(source: source, into: db)
        XCTAssertEqual(try db.searchChunks("Apfel").count, 1)

        // Inhalt ersetzen und mtime vorrücken, dann erneut scannen + indizieren.
        try Data("neuer Begriff Birne".utf8).write(to: fileURL)
        try setMTime(fileURL, Date(timeIntervalSince1970: 2_000_000))
        try scanner.scan(source: source, into: db)
        let reprocessed = try await indexer.indexContent(source: source, into: db)
        XCTAssertEqual(reprocessed, 1)

        XCTAssertEqual(try db.searchChunks("Apfel").count, 0, "alter Inhalt muss ersetzt sein")
        XCTAssertEqual(try db.searchChunks("Birne").count, 1)
    }

    /// Dateien ohne unterstützten Extraktor werden ignoriert (keine Chunks, kein Churn).
    func testUnsupportedExtensionIsSkipped() async throws {
        let db = try makeDB()
        let dir = try makeSource(["data.bin": "binärzeug", "text.txt": "lesbarer Text"])
        let source = SourceRecord(id: dir.path, path: dir.path)
        try db.upsertSource(source)
        try scanner.scan(source: source, into: db)

        let processed = try await indexer.indexContent(source: source, into: db)
        XCTAssertEqual(processed, 1)
        XCTAssertEqual(try db.searchChunks("binärzeug").count, 0)
        XCTAssertEqual(try db.searchChunks("lesbarer").count, 1)
    }
}
