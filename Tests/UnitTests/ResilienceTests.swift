import XCTest
import GRDB
import Darwin
@testable import SharedCore

private struct SelectiveMetadata: FileMetadataProviding {
    let name: String
    let unavailable: Bool
    func metadata(for url: URL) throws -> LocalFileMetadata {
        let actual = try LocalFileMetadataProvider().metadata(for: url)
        guard url.lastPathComponent == name else { return actual }
        if unavailable { throw FileAccessError.unavailable }
        return LocalFileMetadata(size: actual.size, modificationDate: actual.modificationDate,
            identity: actual.identity, isDirectory: actual.isDirectory, isRegular: actual.isRegular,
            isSymbolicLink: actual.isSymbolicLink, isDataless: true)
    }
}

final class ResilienceTests: XCTestCase {
    private func fixture() throws -> (IndexDatabase, URL, SourceRecord) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("localseek-safety-\(UUID().uuidString)")
        let root = base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("Payment is due in thirty days.".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("The garden needs water.".utf8).write(to: root.appendingPathComponent("b.txt"))
        let db = try IndexDatabase(url: base.appendingPathComponent("db/index.sqlite"))
        let source = SourceRecord(id: root.path, path: root.path)
        try db.upsertSource(source)
        try DirectoryScanner().scan(source: source, into: db)
        return (db, root, source)
    }

    func testMissingSourceAndPartialScanNeverDeleteCachedContent() async throws {
        let (db, root, source) = try fixture()
        try await ContentIndexer().indexContent(source: source, into: db)
        let count = try db.chunkCount()
        let offline = root.appendingPathExtension("offline")
        try FileManager.default.moveItem(at: root, to: offline)
        XCTAssertThrowsError(try DirectoryScanner().scan(source: source, into: db))
        XCTAssertEqual(try db.fileCount(), 2)
        XCTAssertEqual(try db.chunkCount(), count)
        XCTAssertEqual(try db.source(id: source.id)?.scanStatus, "unavailable")
        try FileManager.default.moveItem(at: offline, to: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.txt"))
        let partial = DirectoryScanner(metadata: SelectiveMetadata(name: "b.txt", unavailable: true))
        XCTAssertThrowsError(try partial.scan(source: source, into: db))
        XCTAssertEqual(try db.fileCount(), 2, "A partial generation must not reconcile the missing entry")
        try DirectoryScanner().scan(source: source, into: db)
        XCTAssertEqual(try db.fileCount(), 1)
        XCTAssertEqual(try db.source(id: source.id)?.scanStatus, "idle")
    }

    func testEvictedFileRetainsSearchableContentAndIsNotExtracted() async throws {
        let (db, root, source) = try fixture()
        try await ContentIndexer().indexContent(source: source, into: db)
        let chunks = try db.chunkCount()
        let probe = SelectiveMetadata(name: "a.txt", unavailable: false)
        try DirectoryScanner(metadata: probe).scan(source: source, into: db)
        XCTAssertEqual(try db.searchFilenames("a.txt").first?.state, "cloudOnly")
        let processed = try await ContentIndexer(access: CoordinatedFileAccess(metadata: probe))
            .indexContent(source: source, into: db)
        XCTAssertEqual(processed, 0)
        XCTAssertEqual(try db.chunkCount(), chunks)
        XCTAssertEqual(try db.searchChunks("Payment").count, 1)
        XCTAssertThrowsError(try CoordinatedFileAccess(metadata: probe).read(at: root.appendingPathComponent("a.txt")) { _ in
            XCTFail("A cloud-only file must never reach a content reader")
        })
    }

    func testRenamePreservesFileChunkAndVectorIdentity() async throws {
        let (db, root, source) = try fixture()
        try await ContentIndexer().indexContent(source: source, into: db)
        let original = try XCTUnwrap(try db.searchChunks("Payment").first)
        try db.upsertEmbedding(chunkId: original.chunkId, modelId: "fake", textHash: "hash", vector: [1, 0, 0])
        try FileManager.default.moveItem(at: root.appendingPathComponent("a.txt"), to: root.appendingPathComponent("renamed.txt"))
        try DirectoryScanner().scan(source: source, into: db)
        let renamed = try XCTUnwrap(try db.searchChunks("Payment").first)
        XCTAssertEqual(renamed.fileId, original.fileId)
        XCTAssertEqual(renamed.chunkId, original.chunkId)
        XCTAssertEqual(renamed.filename, "renamed.txt")
        XCTAssertEqual(try db.embeddingCount(), 1)
    }

    func testIdenticalContentReplacementPreservesChunkVectors() throws {
        let (db, _, _) = try fixture()
        let file = try XCTUnwrap(try db.searchFilenames("a.txt").first?.id)
        let chunk = ChunkRecord(fileId: file, ordinal: 0, text: "unchanged")
        try db.replaceChunks(fileId: file, chunks: [chunk])
        let original = try XCTUnwrap(try db.searchChunks("unchanged").first?.chunkId)
        try db.upsertEmbedding(chunkId: original, modelId: "fake", textHash: StableHash.hex(chunk.text), vector: [1, 0, 0])
        try db.replaceChunks(fileId: file, chunks: [chunk])
        XCTAssertEqual(try db.searchChunks("unchanged").first?.chunkId, original)
        XCTAssertEqual(try db.embeddingCount(), 1)
    }

    func testMaterializationPolicyIsRestoredAfterThrow() throws {
        let before = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        XCTAssertThrowsError(try withoutFileMaterialization {
            XCTAssertEqual(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD),
                           IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
            throw FileAccessError.unavailable
        })
        XCTAssertEqual(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD), before)
    }
}

final class ChunkingTests: XCTestCase {
    func testBoundedUnicodeChunksRetainTailAndLocation() async throws {
        let text = (0..<100).map { "Abschnitt \($0): Zahlungsverkehr 日本語 🧑🏽‍💻\n" }.joined() + "LAST_UNIQUE_MARKER"
        let chunks = try await DocumentChunker().chunks(from: ExtractedDocument(segments: [
            DocumentSegment(text: text, location: .page(17))]), fileId: 1)
        XCTAssertGreaterThan(chunks.count, 10)
        XCTAssertTrue(chunks.allSatisfy { $0.tokenCount <= 350 && $0.locationValue == "17" })
        XCTAssertTrue(chunks.last?.text.hasSuffix("LAST_UNIQUE_MARKER") == true)
        for index in 0..<100 {
            XCTAssertTrue(chunks.contains { $0.text.contains("Abschnitt \(index):") })
        }
        XCTAssertEqual(chunks.map(\.ordinal), Array(chunks.indices))
    }
}

final class PersistentJobTests: XCTestCase {
    func testPriorityCoalescingAndCrashRecovery() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("index.sqlite")
        let db = try IndexDatabase(url: url)
        try db.upsertSource(SourceRecord(id: "s", path: "/tmp/s"))
        try db.enqueueJobs([IndexJobRequest(sourceId: "s", kind: .embeddings),
                            IndexJobRequest(sourceId: "s", kind: .metadata)])
        let first = try XCTUnwrap(try db.claimNextJob())
        XCTAssertEqual(first.kind, .metadata)
        try db.enqueueJobs([IndexJobRequest(sourceId: "s", kind: .metadata)])
        try db.finishJob(first, followUps: [])
        XCTAssertEqual(try db.claimNextJob()?.kind, .metadata, "Changes during a running scan require another generation")
        try db.recoverInterruptedJobs()
        let recovered = try XCTUnwrap(try db.claimNextJob())
        XCTAssertEqual(recovered.kind, .metadata)
        try db.finishJob(recovered, followUps: [IndexJobRequest(sourceId: "s", kind: .content)])
        XCTAssertEqual(try db.claimNextJob()?.kind, .content)
    }
}
