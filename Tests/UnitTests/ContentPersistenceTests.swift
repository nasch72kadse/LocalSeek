import XCTest
import GRDB
@testable import SharedCore

/// Verifiziert das Phase-3-Schema (Migration v2): chunks + chunk_fts (FTS5 BM25),
/// Chunk-Ersetzung je Datei, Volltextsuche mit Snippet/Fundstelle und das
/// Mitentfernen der FTS-Einträge bei Datei-/Chunk-Löschung (FK-Cascade + Trigger).
final class ContentPersistenceTests: XCTestCase {

    private func makeDB() throws -> IndexDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("localseek-test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("index.sqlite")
        return try IndexDatabase(url: url)
    }

    /// Legt eine Quelle + Datei an und liefert die vergebene File-ID zurück.
    private func seedFile(_ db: IndexDatabase, source: String = "s1",
                         path: String = "docs/bericht.pdf",
                         filename: String = "bericht.pdf") throws -> Int64 {
        try db.upsertSource(SourceRecord(id: source, path: "/tmp/\(source)"))
        try db.upsertFile(FileRecord(sourceId: source, relativePath: path,
                                     filename: filename, fileExtension: "pdf",
                                     size: 1, mtime: nil))
        return try db.dbPool.read { dbc in
            try Int64.fetchOne(dbc, sql:
                "SELECT id FROM files WHERE sourceId = ? AND relativePath = ?",
                arguments: [source, path])!
        }
    }

    private func chunk(_ fileId: Int64, _ ordinal: Int, _ text: String,
                       type: String = "page", value: String = "") -> ChunkRecord {
        ChunkRecord(fileId: fileId, ordinal: ordinal, text: text,
                    locationType: type, locationValue: value.isEmpty ? "\(ordinal + 1)" : value,
                    textHash: String(text.hashValue), tokenCount: text.split(separator: " ").count)
    }

    func testMigrationV2CreatesContentTables() throws {
        let db = try makeDB()
        try db.dbPool.read { dbc in
            XCTAssertTrue(try dbc.tableExists("chunks"))
            XCTAssertTrue(try dbc.tableExists("chunk_fts"))
        }
        XCTAssertEqual(try db.chunkCount(), 0)
    }

    func testReplaceAndSearchChunks() throws {
        let db = try makeDB()
        let fileId = try seedFile(db)
        try db.replaceChunks(fileId: fileId, chunks: [
            chunk(fileId, 0, "Dies ist die Einleitung des Prüfberichts."),
            chunk(fileId, 1, "Das Risiko im Zahlungsverkehr wurde bewertet."),
        ])
        XCTAssertEqual(try db.chunkCount(), 2)

        let hits = try db.searchChunks("Zahlungsverkehr")
        XCTAssertEqual(hits.count, 1)
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit.fileId, fileId)
        XCTAssertEqual(hit.filename, "bericht.pdf")
        XCTAssertEqual(hit.ordinal, 1)
        XCTAssertEqual(hit.locationType, "page")
        XCTAssertEqual(hit.locationValue, "2")
        XCTAssertTrue(hit.snippet.contains("["), "Snippet soll den Treffer markieren: \(hit.snippet)")
    }

    /// remove_diacritics 2: Suche ohne Umlaut findet Umlaut-Token ("prufung" → "Prüfung").
    /// FTS5 ist tokenbasiert: nur eigenständige Wörter, keine Substrings.
    func testDiacriticsFoldingSearch() throws {
        let db = try makeDB()
        let fileId = try seedFile(db)
        try db.replaceChunks(fileId: fileId, chunks: [
            chunk(fileId, 0, "Die Prüfung für das Geschäftsjahr war erfolgreich."),
        ])
        XCTAssertEqual(try db.searchChunks("prufung").count, 1)
        XCTAssertEqual(try db.searchChunks("fur").count, 1)
        XCTAssertEqual(try db.searchChunks("geschaftsjahr").count, 1)
    }

    /// Erneutes replaceChunks ersetzt die Chunks der Datei vollständig (kein Duplikat).
    func testReplaceChunksIsIdempotent() throws {
        let db = try makeDB()
        let fileId = try seedFile(db)
        let payload = [chunk(fileId, 0, "Inhalt A"), chunk(fileId, 1, "Inhalt B")]
        try db.replaceChunks(fileId: fileId, chunks: payload)
        try db.replaceChunks(fileId: fileId, chunks: payload)
        XCTAssertEqual(try db.chunkCount(), 2)
        XCTAssertEqual(try db.searchChunks("Inhalt").count, 2)
    }

    /// Datei-/Quellenlöschung entfernt Chunks (FK-Cascade) UND FTS-Zeilen (AFTER-DELETE-Trigger).
    func testSourceDeleteCascadesChunksAndFTS() throws {
        let db = try makeDB()
        let fileId = try seedFile(db)
        try db.replaceChunks(fileId: fileId, chunks: [chunk(fileId, 0, "Vertrauliches Dokument")])
        XCTAssertEqual(try db.searchChunks("Vertrauliches").count, 1)

        try db.removeSource(id: "s1")
        XCTAssertEqual(try db.chunkCount(), 0)
        XCTAssertEqual(try db.searchChunks("Vertrauliches").count, 0,
                       "FTS-Zeile muss beim Cascade-Delete mitentfernt werden")
    }
}
