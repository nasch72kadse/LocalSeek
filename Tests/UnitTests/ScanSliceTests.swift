import Foundation
import GRDB
import XCTest
@testable import SharedCore

private final class ScopeMetadata: FileMetadataProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var visited: Set<String> = []
    let unavailable: String?
    init(unavailable: String? = nil) { self.unavailable = unavailable }
    func metadata(for url: URL) throws -> LocalFileMetadata {
        lock.withLock { _ = visited.insert(url.path) }
        if url.lastPathComponent == unavailable { throw FileAccessError.unavailable }
        return try LocalFileMetadataProvider().metadata(for: url)
    }
    func saw(_ url: URL) -> Bool { lock.withLock { visited.contains(url.path) } }
}

final class ScanSliceTests: XCTestCase {
    private func fixture(_ paths: [String]) throws -> (IndexDatabase, URL, SourceRecord) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("scan-slices-" + UUID().uuidString)
        let root = base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for path in paths {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("needle content".utf8).write(to: file)
        }
        let db = try IndexDatabase(url: base.appendingPathComponent("db/index.sqlite"))
        let source = SourceRecord(id: "a", path: root.path)
        try db.upsertSource(source)
        addTeardownBlock { try db.dbPool.close(); try FileManager.default.removeItem(at: base) }
        return (db, root, source)
    }

    func testDisjointSubtreesSkipUnrelatedFilesAndPreserveCrossFolderRename() async throws {
        let (db, root, source) = try fixture(["one/document.txt", "two/keep.txt", "other/unrelated.txt"])
        try DirectoryScanner().scan(source: source, into: db)
        try await ContentIndexer().indexContent(source: source, into: db)
        let before = try XCTUnwrap(try db.searchChunks("needle").first { $0.relativePath == "one/document.txt" })
        try db.upsertEmbedding(chunkId: before.chunkId, modelId: "m", textHash: "fixture", vector: [1, 0])
        try FileManager.default.moveItem(at: root.appendingPathComponent("one/document.txt"), to: root.appendingPathComponent("two/document.txt"))
        let spy = ScopeMetadata()
        let plan = try DirectoryScanPlan(scanner: .init(metadata: spy), source: source, relativePaths: ["one", "two"])
        while try !plan.advance(into: db, maxEntries: 1, maxSeconds: .infinity).complete {}
        let after = try XCTUnwrap(try db.searchChunks("needle").first { $0.relativePath == "two/document.txt" })
        XCTAssertEqual(before.fileId, after.fileId); XCTAssertEqual(before.chunkId, after.chunkId)
        XCTAssertEqual(try db.embeddingCount(), 1)
        XCTAssertFalse(spy.saw(root.appendingPathComponent("other/unrelated.txt")))
        XCTAssertEqual(try db.fileCount(), 3)
    }

    func testPartialScopeNeverDeletesRowsFromAnotherScope() throws {
        let (db, root, source) = try fixture(["one/removed.txt", "two/unreadable.txt", "other/keep.txt"])
        try DirectoryScanner().scan(source: source, into: db)
        try FileManager.default.removeItem(at: root.appendingPathComponent("one/removed.txt"))
        let plan = try DirectoryScanPlan(scanner: .init(metadata: ScopeMetadata(unavailable: "unreadable.txt")), source: source, relativePaths: ["one", "two"])
        XCTAssertThrowsError(try plan.advance(into: db, maxEntries: 100, maxSeconds: .infinity))
        XCTAssertEqual(try db.fileCount(), 3)
        XCTAssertEqual(try db.searchFilenames("removed.txt").count, 1)
    }

    func testPartialGenerationRetainsMissingRowsUntilAllSlicesComplete() throws {
        let (db, root, source) = try fixture(["removed.txt", "one.txt", "two.txt", "three.txt"])
        try DirectoryScanner().scan(source: source, into: db)
        try FileManager.default.removeItem(at: root.appendingPathComponent("removed.txt"))
        let plan = try DirectoryScanPlan(scanner: .init(), source: source, relativePaths: [""])
        XCTAssertFalse(try plan.advance(into: db, maxEntries: 1, maxSeconds: .infinity).complete)
        XCTAssertEqual(try db.fileCount(), 4)
        while try !plan.advance(into: db, maxEntries: 1, maxSeconds: .infinity).complete {}
        XCTAssertEqual(try db.fileCount(), 3)
    }

    func testLargeMetadataJobYieldsToAnotherSourceAndResumes() async throws {
        let (db, root, source) = try fixture((0..<600).map { "file\($0).txt" })
        let otherRoot = root.deletingLastPathComponent().appendingPathComponent("other")
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        try Data("small source".utf8).write(to: otherRoot.appendingPathComponent("small.txt"))
        let other = SourceRecord(id: "b", path: otherRoot.path)
        try db.upsertSource(other)
        try db.enqueueJobs([.init(sourceId: source.id, kind: .metadata), .init(sourceId: other.id, kind: .metadata)])
        let worker = IndexWorker(db: db)
        let first = try XCTUnwrap(try db.claimNextJob())
        XCTAssertEqual(first.sourceId, source.id)
        let followUps = try await worker.perform(first, checkpoint: { _ in try Task.checkCancellation() })
        try db.finishJob(first, followUps: followUps)
        XCTAssertGreaterThan(try db.fileCount(), 0); XCTAssertLessThan(try db.fileCount(), 600)
        let next = try XCTUnwrap(try db.claimNextJob())
        XCTAssertEqual(next.sourceId, other.id)
        let nextJobs = try await worker.perform(next, checkpoint: { _ in try Task.checkCancellation() })
        try db.finishJob(next, followUps: nextJobs)
        XCTAssertEqual(try db.fileCount(forSource: other.id), 1)
        var iterations = 0
        while let job = try db.claimNextJob(), iterations < 30 {
            let requests = job.kind == .metadata ? try await worker.perform(job, checkpoint: { _ in try Task.checkCancellation() }) : []
            try db.finishJob(job, followUps: requests)
            iterations += 1
        }
        XCTAssertEqual(try db.fileCount(forSource: source.id), 600)
    }

    func testFileEventDuringFullScanRestartsGenerationWithoutDeletingNewRows() async throws {
        let (db, root, source) = try fixture((0..<600).map { "file\($0).txt" })
        try DirectoryScanner().scan(source: source, into: db)
        try FileManager.default.removeItem(at: root.appendingPathComponent("file0.txt"))
        let worker = IndexWorker(db: db)
        try db.enqueueJobs([.init(sourceId: source.id, kind: .metadata)])
        let first = try XCTUnwrap(try db.claimNextJob())
        let next = try await worker.perform(first, checkpoint: { _ in try Task.checkCancellation() })
        try db.finishJob(first, followUps: next)
        try Data("newly created".utf8).write(to: root.appendingPathComponent("fresh.txt"))
        try db.enqueueFileEvents(sourceId: source.id, relativePaths: ["fresh.txt"])
        var iterations = 0
        while let job = try db.claimNextJob(), iterations < 30 {
            let requests = [.metadata, .changes].contains(job.kind)
                ? try await worker.perform(job, checkpoint: { _ in try Task.checkCancellation() }) : []
            try db.finishJob(job, followUps: requests)
            iterations += 1
        }
        XCTAssertEqual(try db.fileCount(), 600)
        XCTAssertEqual(try db.searchFilenames("fresh.txt").count, 1)
        XCTAssertTrue(try db.searchFilenames("file0.txt").isEmpty)
    }

    func testMetadataContinuationIsNotStarvedByContinuingContentWork() async throws {
        let (db, _, source) = try fixture((0..<600).map { "file\($0).txt" })
        let worker = IndexWorker(db: db)
        try db.enqueueJobs([.init(sourceId: source.id, kind: .metadata)])
        let metadata = try XCTUnwrap(try db.claimNextJob())
        let followUps = try await worker.perform(metadata, checkpoint: { _ in try Task.checkCancellation() })
        try db.finishJob(metadata, followUps: followUps)
        let firstCount = try db.fileCount()
        let content = try XCTUnwrap(try db.claimNextJob())
        XCTAssertEqual(content.kind, .content)
        // Simulate a PDF/content slice that has more work remaining.
        try db.finishJob(content, followUps: [.init(sourceId: source.id, kind: .content)])
        let next = try XCTUnwrap(try db.claimNextJob())
        XCTAssertEqual(next.kind, .metadata)
        let more = try await worker.perform(next, checkpoint: { _ in try Task.checkCancellation() })
        try db.finishJob(next, followUps: more)
        XCTAssertGreaterThan(try db.fileCount(), firstCount)
    }
}
