import XCTest
import GRDB
@testable import SharedCore

private final class MetadataSpy: FileMetadataProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func metadata(for url: URL) throws -> LocalFileMetadata {
        lock.lock(); paths.append(url.path); lock.unlock()
        return try LocalFileMetadataProvider().metadata(for: url)
    }
    var seen: [String] { lock.lock(); defer { lock.unlock() }; return paths }
}

private actor BatchProvider: EmbeddingProvider {
    let dimensions = 3
    private(set) var sizes: [Int] = []
    func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]] {
        sizes.append(texts.count)
        if texts.contains("BAD") { throw EmbeddingError.inferenceFailed }
        return texts.map { _ in [1, 0, 0] }
    }
}

final class IndexOptimizationTests: XCTestCase {
    private func fixture(_ paths: [String] = ["a.txt"]) throws -> (IndexDatabase, URL, SourceRecord) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("index-opt-" + UUID().uuidString)
        let root = base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for path in paths {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(("Content " + path).utf8).write(to: file)
        }
        let db = try IndexDatabase(url: base.appendingPathComponent("db/index.sqlite"))
        let source = SourceRecord(id: "opaque-source", path: root.path)
        try db.upsertSource(source); try DirectoryScanner().scan(source: source, into: db)
        addTeardownBlock { try db.dbPool.close(); try FileManager.default.removeItem(at: base) }
        return (db, root, source)
    }
    private func changes(_ db: IndexDatabase) throws -> Int {
        try db.dbPool.write { try Int.fetchOne($0, sql: "SELECT total_changes()")! }
    }
    private func file(_ db: IndexDatabase, path: String) throws -> FileRecord {
        try XCTUnwrap(try db.dbPool.read {
            try FileRecord.fetchOne($0, sql: "SELECT * FROM files WHERE relativePath = ?", arguments: [path])
        })
    }

    func testUnchangedMetadataDoesNotWriteOrTouchFTS() throws {
        let (db, root, source) = try fixture()
        let url = root.appendingPathComponent("a.txt")
        let info = try LocalFileMetadataProvider().metadata(for: url)
        let record = FileRecord(sourceId: source.id, relativePath: "a.txt", filename: "a.txt",
            fileExtension: "txt", size: info.size, mtime: info.modificationDate, fileIdentity: info.identity)
        let before = try changes(db)
        try db.upsertFile(record)
        XCTAssertEqual(try changes(db) - before, 0)
        try DirectoryScanner().scan(source: source, into: db)
        XCTAssertLessThanOrEqual(try changes(db) - before, 3, "Only generation and source status may change")
        XCTAssertEqual(try db.searchFilenames("a.txt").count, 1)
    }

    func testFileEventOnlyInspectsTheChangedFile() throws {
        let (db, root, source) = try fixture((0..<30).map { "file\($0).txt" })
        let spy = MetadataSpy()
        let url = root.appendingPathComponent("file7.txt")
        try Data("Longer changed content".utf8).write(to: url)
        try DirectoryScanner(metadata: spy).scanChanges(source: source, relativePaths: ["file7.txt"], into: db)
        XCTAssertEqual(Set(spy.seen.filter { $0 != root.path }), [url.path])
        XCTAssertEqual(try file(db, path: "file7.txt").size, 22)
        XCTAssertEqual(try db.fileCount(), 30)
    }

    func testSubtreeReconciliationPreservesUnrelatedFiles() throws {
        let (db, root, source) = try fixture(["a/old.txt", "b/keep.txt"])
        let keptID = try file(db, path: "b/keep.txt").id
        try FileManager.default.removeItem(at: root.appendingPathComponent("a/old.txt"))
        try Data("New".utf8).write(to: root.appendingPathComponent("a/new.txt"))
        try DirectoryScanner().scanChanges(source: source, relativePaths: ["a"], into: db)
        XCTAssertEqual(try db.fileCount(), 2)
        XCTAssertEqual(try file(db, path: "b/keep.txt").id, keptID)
        XCTAssertTrue(try db.searchFilenames("old.txt").isEmpty)
    }

    func testTargetedRenamePreservesChunksAndVectors() async throws {
        let (db, root, source) = try fixture()
        try await ContentIndexer().indexContent(source: source, into: db)
        let original = try XCTUnwrap(try db.searchChunks("Content").first)
        try db.upsertEmbedding(chunkId: original.chunkId, modelId: "m", textHash: "fixture", vector: [1, 0])
        try FileManager.default.moveItem(at: root.appendingPathComponent("a.txt"), to: root.appendingPathComponent("renamed.txt"))
        try DirectoryScanner().scanChanges(source: source, relativePaths: ["a.txt", "renamed.txt"], into: db)
        let after = try XCTUnwrap(try db.searchChunks("Content").first)
        XCTAssertEqual(after.fileId, original.fileId)
        XCTAssertEqual(after.chunkId, original.chunkId)
        XCTAssertEqual(after.filename, "renamed.txt")
        XCTAssertEqual(try db.embeddingCount(), 1)
    }

    func testSizeChangeWithPreservedTimestampNeedsReextraction() async throws {
        let (db, root, source) = try fixture()
        try await ContentIndexer().indexContent(source: source, into: db)
        let url = root.appendingPathComponent("a.txt")
        let old = try LocalFileMetadataProvider().metadata(for: url)
        try Data("Replacement with a different number of bytes".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: old.modificationDate], ofItemAtPath: url.path)
        try DirectoryScanner().scanChanges(source: source, relativePaths: ["a.txt"], into: db)
        XCTAssertEqual(try db.filesNeedingContentExtraction(sourceId: source.id, extensions: ["txt"]).count, 1)
        try await ContentIndexer().indexContent(source: source, into: db)
        XCTAssertEqual(try db.searchChunks("Replacement").count, 1)
    }

    func testNewEventRevisionSurvivesCompletionOfOldSnapshot() throws {
        let (db, _, source) = try fixture()
        try db.enqueueFileEvents(sourceId: source.id, relativePaths: ["a.txt"])
        let job = try XCTUnwrap(try db.claimNextJob())
        let old = try db.pendingFileEvents(sourceId: source.id)
        try db.enqueueFileEvents(sourceId: source.id, relativePaths: ["a.txt"])
        try db.completeFileEvents(old, job: job)
        let pending = try db.pendingFileEvents(sourceId: source.id)
        XCTAssertEqual(pending.count, 1)
        XCTAssertNotEqual(pending.first?.id, old.first?.id)
        try db.finishJob(job, followUps: [])
        XCTAssertEqual(try db.claimNextJob()?.kind, .changes)
    }

    func testReplacementWithSameSizeAndTimestampNeedsReextraction() async throws {
        let (db, root, source) = try fixture()
        try await ContentIndexer().indexContent(source: source, into: db)
        let url = root.appendingPathComponent("a.txt")
        let old = try LocalFileMetadataProvider().metadata(for: url)
        let replacement = root.appendingPathComponent("replacement.tmp")
        try Data(String(repeating: "x", count: Int(old.size)).utf8).write(to: replacement)
        try FileManager.default.setAttributes([.modificationDate: old.modificationDate], ofItemAtPath: replacement.path)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: replacement, to: url)
        try DirectoryScanner().scanChanges(source: source, relativePaths: ["a.txt"], into: db)
        XCTAssertEqual(try db.filesNeedingContentExtraction(sourceId: source.id, extensions: ["txt"]).count, 1)
    }

    func testTargetedScanDoesNotFollowSymlinkAncestors() throws {
        let (db, root, source) = try fixture(["a/keep.txt"])
        let elsewhere = root.deletingLastPathComponent().appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: elsewhere.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: elsewhere)
        XCTAssertThrowsError(try DirectoryScanner().scanChanges(source: source, relativePaths: ["link/secret.txt"], into: db))
        XCTAssertEqual(try db.fileCount(), 1)
    }

    func testNarrowEventsKeepTheFullScanHiddenAndPackagePolicy() throws {
        let (db, root, source) = try fixture()
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".secret.txt"))
        let package = root.appendingPathComponent("Example.app/Contents")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("package".utf8).write(to: package.appendingPathComponent("secret.txt"))
        try DirectoryScanner().scanChanges(source: source,
            relativePaths: [".secret.txt", "Example.app/Contents/secret.txt"], into: db)
        XCTAssertEqual(try db.fileCount(), 1)
    }

    func testWorkerEmbedsBeforeFinishingTheSource() async throws {
        let (db, _, source) = try fixture((0..<20).map { "file\($0).txt" })
        let worker = IndexWorker(db: db, provider: BatchProvider(), modelId: "m")
        try db.enqueueJobs([.init(sourceId: source.id, kind: .content)])
        let first = try XCTUnwrap(try db.claimNextJob())
        let followUps = try await worker.perform(first, checkpoint: { _ in try Task.checkCancellation() })
        try db.finishJob(first, followUps: followUps)
        let next = try XCTUnwrap(try db.claimNextJob())
        XCTAssertEqual(next.kind, .embeddings)
        let embeddingFollowUps = try await worker.perform(next, checkpoint: { _ in try Task.checkCancellation() })
        try db.finishJob(next, followUps: embeddingFollowUps)
        XCTAssertGreaterThan(try db.embeddingCount(), 0)
        XCTAssertLessThan(try db.chunkCount(), 20)
        XCTAssertEqual(try db.claimNextJob()?.kind, .content)
    }

    func testNarrowPathsCannotEscapeTheSource() throws {
        let (db, _, source) = try fixture()
        for path in ["../outside", "/etc", "a/../../b", "a//b"] {
            XCTAssertThrowsError(try DirectoryScanner().scanChanges(source: source, relativePaths: [path], into: db))
        }
        XCTAssertEqual(try db.fileCount(), 1)
    }

    func testContentBatchesResumeAndEmbeddingWorkRunsBetweenThem() async throws {
        let (db, _, source) = try fixture((0..<5).map { "file\($0).txt" })
        let content = ContentIndexer()
        let first = try await content.indexBatch(source: source, into: db, maxFiles: 2, maxSeconds: .infinity)
        XCTAssertEqual(first.processed, 2)
        let second = try await content.indexBatch(source: source, into: db, afterId: first.lastID, maxFiles: 2, maxSeconds: .infinity)
        XCTAssertEqual(second.processed, 2)
        let third = try await content.indexBatch(source: source, into: db, afterId: second.lastID, maxFiles: 2, maxSeconds: .infinity)
        XCTAssertEqual(third.processed, 1)
        XCTAssertEqual(try db.chunkCount(), 5)

        try db.enqueueJobs([.init(sourceId: source.id, kind: .content, cursor: 5)])
        let job = try XCTUnwrap(try db.claimNextJob())
        try db.enqueueJobs([.init(sourceId: source.id, kind: .content)])
        try db.finishJob(job, followUps: [.init(sourceId: source.id, kind: .content, cursor: 10)])
        XCTAssertEqual(try db.claimNextJob()?.cursor, 0, "New changes must reset an old continuation")
    }

    func testEmbeddingsUseBatchesAndIsolateBadMembers() async throws {
        let (db, _, source) = try fixture()
        let id = try XCTUnwrap(try file(db, path: "a.txt").id)
        try db.replaceChunks(fileId: id, chunks: (0..<10).map { ChunkRecord(fileId: id, ordinal: $0, text: "chunk\($0)") })
        let provider = BatchProvider()
        let indexer = EmbeddingIndexer(provider: provider, store: BruteForceVectorStore(db: db))
        let first = try await indexer.indexBatch(modelId: "m", into: db, sourceId: source.id, maxChunks: 8, maxSeconds: .infinity)
        XCTAssertEqual(first.processed, 8)
        let sizes = await provider.sizes
        XCTAssertEqual(sizes, [4, 4])
        let last = try await indexer.indexBatch(modelId: "m", into: db, sourceId: source.id, afterId: first.lastID)
        XCTAssertEqual(last.processed, 2)

        try db.replaceChunks(fileId: id, chunks: ["Good", "BAD", "Other"].enumerated().map {
            ChunkRecord(fileId: id, ordinal: $0.offset, text: $0.element)
        })
        let count = try await indexer.indexEmbeddings(modelId: "m", into: db)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(try db.embeddingCount(), 2)
        let failures = try await db.dbPool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM embedding_failures") }
        XCTAssertEqual(failures, 1)
    }

    func testStaleBatchCannotOverwriteChangedText() throws {
        let (db, _, _) = try fixture()
        let id = try XCTUnwrap(try file(db, path: "a.txt").id)
        try db.replaceChunks(fileId: id, chunks: [.init(fileId: id, ordinal: 0, text: "current")])
        let chunk = try XCTUnwrap(try db.chunksNeedingEmbedding(modelId: "m").first?.id)
        try db.upsertEmbeddings([.init(chunkId: chunk, modelId: "m", textHash: "old", embedding: [1, 0], requireCurrentText: true)])
        XCTAssertEqual(try db.embeddingCount(), 0)
    }

    func testOCRCacheBudgetAndDeletionFollowFileOwnership() throws {
        let (db, _, source) = try fixture()
        let id = try XCTUnwrap(try file(db, path: "a.txt").id)
        let cache = DatabaseOCRCache(db: db, fileId: id, maximumBytes: 64)
        try cache.store([String(repeating: "a", count: 40)], key: "one")
        try cache.store([String(repeating: "b", count: 40)], key: "two")
        XCTAssertNil(try cache.lookup(key: "one"))
        XCTAssertEqual(try cache.lookup(key: "two")?.first, String(repeating: "b", count: 40))
        let bytes = try db.dbPool.read { try Int.fetchOne($0, sql: "SELECT bytes FROM ocr_cache_budget")! }
        XCTAssertLessThanOrEqual(bytes, 64)
        try db.removeSource(id: source.id)
        XCTAssertNil(try cache.lookup(key: "two"))
        XCTAssertEqual(try db.dbPool.read { try Int.fetchOne($0, sql: "SELECT bytes FROM ocr_cache_budget") }, 0)
    }
}
