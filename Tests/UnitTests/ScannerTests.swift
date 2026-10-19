import XCTest
@testable import SharedCore

/// Verifiziert, dass der rekursive Scanner Dateien samt Unterordnern findet,
/// Metadaten liest und über die DB auffindbar macht.
final class ScannerTests: XCTestCase {

    private func makeTempDB() throws -> IndexDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("localseek-scan-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("index.sqlite")
        return try IndexDatabase(url: url)
    }

    private func makeFixtureTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("localseek-fixture-\(UUID().uuidString)", isDirectory: true)
        let sub = root.appendingPathComponent("Unterordner", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "a".write(to: root.appendingPathComponent("report.pdf"), atomically: true, encoding: .utf8)
        try "b".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "c".write(to: sub.appendingPathComponent("tief_versteckt.md"), atomically: true, encoding: .utf8)
        // Versteckte Datei muss übersprungen werden.
        try "x".write(to: root.appendingPathComponent(".geheim"), atomically: true, encoding: .utf8)
        return root
    }

    func testRecursiveScanFillsDatabase() throws {
        let db = try makeTempDB()
        let root = try makeFixtureTree()
        let source = SourceRecord(id: root.path, path: root.path)
        try db.upsertSource(source)

        let count = try DirectoryScanner().scan(source: source, into: db)

        XCTAssertEqual(count, 3) // versteckte Datei ausgeschlossen
        XCTAssertEqual(try db.fileCount(), 3)

        // Datei im Unterordner über Substring-Suche auffindbar.
        let hits = try db.searchFilenames("versteckt")
        XCTAssertEqual(hits.map(\.filename), ["tief_versteckt.md"])
        XCTAssertEqual(hits.first?.relativePath, "Unterordner/tief_versteckt.md")
    }

    func testRescanIsIdempotent() throws {
        let db = try makeTempDB()
        let root = try makeFixtureTree()
        let source = SourceRecord(id: root.path, path: root.path)
        try db.upsertSource(source)

        try DirectoryScanner().scan(source: source, into: db)
        try DirectoryScanner().scan(source: source, into: db)

        XCTAssertEqual(try db.fileCount(), 3) // keine Duplikate
    }

    func testRescanRemovesDeletedFiles() throws {
        let db = try makeTempDB()
        let root = try makeFixtureTree()
        let source = SourceRecord(id: root.path, path: root.path)
        try db.upsertSource(source)

        try DirectoryScanner().scan(source: source, into: db)
        XCTAssertEqual(try db.fileCount(), 3)

        // Datei löschen → erneuter Scan entfernt sie aus Index und FTS.
        try FileManager.default.removeItem(at: root.appendingPathComponent("notes.txt"))
        try DirectoryScanner().scan(source: source, into: db)

        XCTAssertEqual(try db.fileCount(), 2)
        XCTAssertTrue(try db.searchFilenames("notes").isEmpty)
    }
}
