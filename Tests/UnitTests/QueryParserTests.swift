import XCTest
import GRDB
@testable import SharedCore

/// Verifiziert den `QueryParser` (typisierter Suchausdruck) und die Filterwirkung
/// (`ext:`/`type:`/`path:`/`after:`/`before:`) in `IndexDatabase.searchChunks`.
final class QueryParserTests: XCTestCase {

    // MARK: - Parser

    func testPlainTermsAreAnded() {
        let q = QueryParser.parse("audit risk")
        XCTAssertEqual(q.terms, ["audit", "risk"])
        XCTAssertTrue(q.phrases.isEmpty)
        XCTAssertTrue(q.hasTextMatch)
    }

    func testQuotedPhrase() {
        let q = QueryParser.parse("\"statement of applicability\"")
        XCTAssertEqual(q.phrases, ["statement of applicability"])
        XCTAssertTrue(q.terms.isEmpty)
    }

    func testExtAndTypeMapToExtensions() {
        XCTAssertEqual(QueryParser.parse("ext:pptx").extensions, ["pptx"])
        XCTAssertEqual(QueryParser.parse("type:PDF").extensions, ["pdf"])
        XCTAssertEqual(QueryParser.parse("ext:.docx").extensions, ["docx"]) // führender Punkt entfernt
    }

    func testPathFilter() {
        XCTAssertEqual(QueryParser.parse("path:Audits owner").pathContains, ["Audits"])
        XCTAssertEqual(QueryParser.parse("path:Audits owner").terms, ["owner"])
    }

    func testDateFilters() {
        let q = QueryParser.parse("after:2025-01-01 before:2025-12-31 audit")
        XCTAssertEqual(q.after, makeDate(2025, 1, 1))
        XCTAssertEqual(q.before, makeDate(2025, 12, 31))
        XCTAssertEqual(q.terms, ["audit"])
    }

    func testInvalidDateIsIgnored() {
        let q = QueryParser.parse("after:gestern audit")
        XCTAssertNil(q.after)
        XCTAssertEqual(q.terms, ["audit"]) // ungültiges Datum ⇒ nur der Term bleibt
    }

    func testMixedExample() {
        let q = QueryParser.parse("type:pdf \"risk assessment\" owner")
        XCTAssertEqual(q.extensions, ["pdf"])
        XCTAssertEqual(q.phrases, ["risk assessment"])
        XCTAssertEqual(q.terms, ["owner"])
    }

    func testFilterOnlyHasNoTextMatch() {
        XCTAssertFalse(QueryParser.parse("ext:pdf path:Audits").hasTextMatch)
    }

    // MARK: - Integration: Filter in searchChunks

    func testSearchChunksAppliesFilters() throws {
        let db = try makeDB()
        let pdf = try seed(db, path: "Audits/bericht.pdf", ext: "pdf",
                           mtime: makeDate(2025, 6, 1))
        let pptx = try seed(db, path: "Decks/vortrag.pptx", ext: "pptx",
                            mtime: makeDate(2024, 1, 1))
        try db.replaceChunks(fileId: pdf, chunks: [
            ChunkRecord(fileId: pdf, ordinal: 0, text: "Das Risiko wurde bewertet.")])
        try db.replaceChunks(fileId: pptx, chunks: [
            ChunkRecord(fileId: pptx, ordinal: 0, text: "Das Risiko im Vortrag.")])

        XCTAssertEqual(try db.searchChunks("Risiko").count, 2, "ohne Filter beide")
        XCTAssertEqual(try db.searchChunks("ext:pdf Risiko").count, 1, "nur das PDF")
        XCTAssertEqual(try db.searchChunks("type:pptx Risiko").first?.fileId, pptx)
        XCTAssertEqual(try db.searchChunks("path:Audits Risiko").count, 1, "nur unter Audits/")
        XCTAssertEqual(try db.searchChunks("after:2025-01-01 Risiko").count, 1, "nur neuere Datei")
        XCTAssertEqual(try db.searchChunks("before:2025-01-01 Risiko").count, 1, "nur ältere Datei")
    }

    func testFilterOnlyQueryReturnsNothing() throws {
        let db = try makeDB()
        let pdf = try seed(db, path: "a.pdf", ext: "pdf", mtime: makeDate(2025, 1, 1))
        try db.replaceChunks(fileId: pdf, chunks: [
            ChunkRecord(fileId: pdf, ordinal: 0, text: "Inhalt")])
        XCTAssertTrue(try db.searchChunks("ext:pdf").isEmpty, "Filter ohne Volltext ⇒ leer")
    }

    // MARK: - Helpers

    private func makeDB() throws -> IndexDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("localseek-qp-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("index.sqlite")
        return try IndexDatabase(url: url)
    }

    private func seed(_ db: IndexDatabase, path: String, ext: String, mtime: Date,
                      source: String = "s1") throws -> Int64 {
        try db.upsertSource(SourceRecord(id: source, path: "/tmp/\(source)"))
        try db.upsertFile(FileRecord(sourceId: source, relativePath: path,
                                     filename: (path as NSString).lastPathComponent,
                                     fileExtension: ext, size: 1, mtime: mtime))
        return try db.dbPool.read { dbc in
            try Int64.fetchOne(dbc, sql:
                "SELECT id FROM files WHERE sourceId = ? AND relativePath = ?",
                arguments: [source, path])!
        }
    }

    private func makeDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.timeZone = TimeZone.current
        return Calendar.current.date(from: c)!
    }
}
