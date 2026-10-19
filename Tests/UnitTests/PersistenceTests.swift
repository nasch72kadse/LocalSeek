import XCTest
@testable import SharedCore

/// Verifiziert DB-Öffnung/Migration, Datei-Upsert und Dateinamen-Suche (Trigram + LIKE).
final class PersistenceTests: XCTestCase {

    private func makeDB() throws -> IndexDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("localseek-test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("index.sqlite")
        return try IndexDatabase(url: url)
    }

    func testOpenAndMigrate() throws {
        let db = try makeDB()
        XCTAssertEqual(try db.fileCount(), 0)
        XCTAssertEqual(try db.sourceCount(), 0)
    }

    func testUpsertSourceAndFile() throws {
        let db = try makeDB()
        try db.upsertSource(SourceRecord(id: "s1", path: "/tmp/Audits"))
        try db.upsertFile(FileRecord(sourceId: "s1", relativePath: "a/report.pdf",
                                     filename: "report.pdf", fileExtension: "pdf",
                                     size: 123, mtime: Date()))
        XCTAssertEqual(try db.sourceCount(), 1)
        XCTAssertEqual(try db.fileCount(), 1)
        XCTAssertEqual(try db.fileCount(forSource: "s1"), 1)

        // Erneutes Upsert desselben Pfads ersetzt, dupliziert nicht.
        try db.upsertFile(FileRecord(sourceId: "s1", relativePath: "a/report.pdf",
                                     filename: "report.pdf", fileExtension: "pdf",
                                     size: 999, mtime: Date()))
        XCTAssertEqual(try db.fileCount(), 1)
    }

    func testTrigramSubstringSearch() throws {
        let db = try makeDB()
        try db.upsertSource(SourceRecord(id: "s1", path: "/tmp/Audits"))
        for name in ["Jahresabschluss_2025.xlsx", "risk_assessment.pdf", "readme.txt"] {
            try db.upsertFile(FileRecord(sourceId: "s1", relativePath: name,
                                         filename: name,
                                         fileExtension: (name as NSString).pathExtension,
                                         size: 1, mtime: nil))
        }
        // Substring mitten im Namen (>=3 Zeichen → Trigram-FTS).
        let hits = try db.searchFilenames("assess")
        XCTAssertEqual(hits.map(\.filename), ["risk_assessment.pdf"])

        let xlsx = try db.searchFilenames("xlsx")
        XCTAssertEqual(xlsx.map(\.filename), ["Jahresabschluss_2025.xlsx"])
    }

    func testShortQueryLikeFallback() throws {
        let db = try makeDB()
        try db.upsertSource(SourceRecord(id: "s1", path: "/tmp"))
        try db.upsertFile(FileRecord(sourceId: "s1", relativePath: "ab.txt",
                                     filename: "ab.txt", fileExtension: "txt",
                                     size: 1, mtime: nil))
        // 2 Zeichen → LIKE-Fallback.
        let hits = try db.searchFilenames("ab")
        XCTAssertEqual(hits.count, 1)
    }

    func testEmptyQueryReturnsNothing() throws {
        let db = try makeDB()
        XCTAssertTrue(try db.searchFilenames("   ").isEmpty)
    }
}
