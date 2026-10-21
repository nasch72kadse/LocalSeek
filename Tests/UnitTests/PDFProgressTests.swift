import AppKit
import GRDB
import XCTest
@testable import SharedCore

final class PDFProgressTests: XCTestCase {
    private func writePDF(_ texts: [String], at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw ExtractionError.unreadable }
        for text in texts {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (text as NSString).draw(at: .init(x: 20, y: 150), withAttributes: [.font: NSFont.systemFont(ofSize: 18)])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
    }
    private func fixture() throws -> (IndexDatabase, SourceRecord, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-progress-" + UUID().uuidString)
        let root = base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("document.pdf")
        try writePDF((1...17).map { "ResumePage\($0)" }, at: url)
        let db = try IndexDatabase(url: base.appendingPathComponent("db/index.sqlite"))
        let source = SourceRecord(id: "s", path: root.path)
        try db.upsertSource(source)
        try DirectoryScanner().scan(source: source, into: db)
        addTeardownBlock { try db.dbPool.close(); try FileManager.default.removeItem(at: base) }
        return (db, source, url)
    }
    private func file(_ db: IndexDatabase) throws -> FileRecord { try XCTUnwrap(db.searchFilenames("document.pdf").first) }
    private func progressCount(_ db: IndexDatabase) throws -> Int {
        try db.dbPool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pdf_progress") ?? 0 }
    }

    func testPDFSlicesPersistAcrossIndexerAndDatabaseRecreation() async throws {
        let (db, source, _) = try fixture()
        let first = try await ContentIndexer().indexBatch(source: source, into: db, maxFiles: 1, maxSeconds: 120)
        XCTAssertEqual(first.processed, 0)
        let record = try file(db)
        XCTAssertEqual(try db.pdfProgress(file: record, version: DocumentChunker.defaultVersion)?.nextPage, 16)
        XCTAssertEqual(try db.chunkCount(), 0)
        let reopened = try IndexDatabase(url: db.storageURL)
        let second = try await ContentIndexer().indexBatch(source: source, into: reopened, maxFiles: 1, maxSeconds: 120)
        XCTAssertEqual(second.processed, 1)
        XCTAssertEqual(try reopened.chunkCount(), 17)
        XCTAssertEqual(try reopened.searchChunks("ResumePage17").first?.locationValue, "17")
        XCTAssertEqual(try progressCount(reopened), 0)
        try reopened.dbPool.close()
    }

    func testChangedPDFDiscardsOldPartialPages() async throws {
        let (db, source, url) = try fixture()
        _ = try await ContentIndexer().indexBatch(source: source, into: db, maxFiles: 1, maxSeconds: 120)
        try writePDF(["ReplacementFirst", "ReplacementSecond"], at: url)
        try DirectoryScanner().scanChanges(source: source, relativePaths: ["document.pdf"], into: db)
        let pass = try await ContentIndexer().indexBatch(source: source, into: db, maxFiles: 1, maxSeconds: 120)
        XCTAssertEqual(pass.processed, 1)
        XCTAssertEqual(try db.chunkCount(), 2)
        XCTAssertTrue(try db.searchChunks("ResumePage1").isEmpty)
        XCTAssertEqual(try db.searchChunks("ReplacementFirst").count, 1)
    }

    func testPreviousSuccessfulContentRemainsUntilNewPDFIsComplete() async throws {
        let (db, source, url) = try fixture()
        try writePDF(["ExistingSuccessfulContent"], at: url)
        try DirectoryScanner().scanChanges(source: source, relativePaths: ["document.pdf"], into: db)
        try await ContentIndexer().indexContent(source: source, into: db)
        try writePDF((1...17).map { "UpdatedPage\($0)" }, at: url)
        try DirectoryScanner().scanChanges(source: source, relativePaths: ["document.pdf"], into: db)
        _ = try await ContentIndexer().indexBatch(source: source, into: db, maxFiles: 1, maxSeconds: 120)
        XCTAssertEqual(try db.searchChunks("ExistingSuccessfulContent").count, 1)
        XCTAssertTrue(try db.searchChunks("UpdatedPage1").isEmpty)
        _ = try await ContentIndexer().indexBatch(source: source, into: db, maxFiles: 1, maxSeconds: 120)
        XCTAssertTrue(try db.searchChunks("ExistingSuccessfulContent").isEmpty)
        XCTAssertEqual(try db.chunkCount(), 17)
    }

    func testPDFProgressByteLimitAndCascadeCleanup() throws {
        let (db, source, _) = try fixture()
        let record = try file(db)
        let batch = PDFPageBatch(title: nil, segments: [.init(text: "text", location: .page(1))], nextPage: 1, totalPages: 2, bytes: 4)
        try db.savePDFBatch(batch, file: record, version: "test", previous: nil, keys: ["cached-page"], maxBytes: 5)
        let previous = try db.pdfProgress(file: record, version: "test")
        XCTAssertThrowsError(try db.savePDFBatch(batch, file: record, version: "test", previous: previous, keys: [], maxBytes: 5))
        XCTAssertEqual(try db.pdfProgress(file: record, version: "test")?.nextPage, 1)
        try db.removeSource(id: source.id)
        XCTAssertEqual(try progressCount(db), 0)
    }
}
