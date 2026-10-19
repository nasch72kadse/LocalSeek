import XCTest
import GRDB
@testable import SharedCore

private struct VectorBuildYield: Error {}
private final class VectorBuildGate: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func checkpoint() throws {
        try lock.withLock {
            calls += 1
            if calls == 3 { throw VectorBuildYield() }
        }
    }
}

final class AdaptiveVectorTests: XCTestCase {
    private func fixture(count: Int = 600) throws -> (IndexDatabase, [Int64], [[Float]]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ann-test-" + UUID().uuidString)
        let db = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
        try db.upsertSource(.init(id: "s", path: root.path))
        try db.upsertFile(.init(sourceId: "s", relativePath: "doc.txt", filename: "doc.txt", fileExtension: "txt", size: 0, mtime: nil))
        let fileID = try XCTUnwrap(try db.dbPool.read { try Int64.fetchOne($0, sql: "SELECT id FROM files") })
        try db.replaceChunks(fileId: fileID, chunks: (0..<count).map { .init(fileId: fileID, ordinal: $0, text: "vector \($0)") })
        let ids = try db.dbPool.read { try Int64.fetchAll($0, sql: "SELECT id FROM chunks ORDER BY ordinal") }
        var seed: UInt64 = 42
        let vectors: [[Float]] = (0..<count).map { _ in
            (0..<32).map { _ in
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Float(Int32(truncatingIfNeeded: seed >> 32)) / Float(Int32.max)
            }
        }
        try db.upsertEmbeddings(zip(ids, vectors).map { .init(chunkId: $0, modelId: "m", textHash: "fixture", embedding: $1) })
        addTeardownBlock { try db.dbPool.close(); try FileManager.default.removeItem(at: root) }
        return (db, ids, vectors)
    }

    func testGraphRecallAndExactReranking() async throws {
        let (db, _, vectors) = try fixture()
        let index = AdaptiveVectorIndex(database: db, minimumVectors: 1)
        let built = try await index.prepare(modelId: "m", dimensions: 32)
        XCTAssertTrue(built)
        for query in vectors.prefix(12) {
            let exact = try BruteForceVectorStore(db: db).nearest(to: query, modelId: "m", limit: 10)
            let accelerated = try XCTUnwrap(try index.nearest(query, modelId: "m", limit: 10))
            let overlap = Set(exact.map(\.chunkId)).intersection(accelerated.map(\.chunkId)).count
            XCTAssertGreaterThanOrEqual(overlap, 9)
            XCTAssertEqual(accelerated.first?.chunkId, exact.first?.chunkId)
            for match in accelerated {
                if let reference = exact.first(where: { $0.chunkId == match.chunkId }) {
                    XCTAssertEqual(match.score, reference.score, accuracy: 0.00001)
                }
            }
        }
    }

    func testUpdatesDeletesAndReinsertionInvalidateThenRefreshGraph() async throws {
        let (db, ids, vectors) = try fixture()
        let index = AdaptiveVectorIndex(database: db, minimumVectors: 1)
        _ = try await index.prepare(modelId: "m", dimensions: 32)
        try db.removeEmbeddings(chunkIds: [ids[0]])
        try db.upsertEmbedding(chunkId: ids[1], modelId: "m", textHash: "updated", vector: vectors[0])
        XCTAssertNil(try index.nearest(vectors[0], modelId: "m", limit: 5))
        let store = AdaptiveVectorStore(db: db, index: index)
        XCTAssertEqual(try store.nearest(to: vectors[0], modelId: "m", limit: 5).first?.chunkId, ids[1])
        _ = try await index.prepare(modelId: "m", dimensions: 32)
        XCTAssertEqual(try index.nearest(vectors[0], modelId: "m", limit: 5)?.first?.chunkId, ids[1])
        try db.upsertEmbedding(chunkId: ids[0], modelId: "m", textHash: "restored", vector: vectors[0])
        _ = try await index.prepare(modelId: "m", dimensions: 32)
        XCTAssertEqual(try index.nearest(vectors[0], modelId: "m", limit: 5)?.first?.chunkId, ids[0])
        try db.removeSource(id: "s")
        XCTAssertTrue(try store.nearest(to: vectors[0], modelId: "m", limit: 5).isEmpty)
    }

    func testFiltersAndVisibilityUseAuthoritativeRows() async throws {
        let (db, _, vectors) = try fixture()
        let index = AdaptiveVectorIndex(database: db, minimumVectors: 1)
        _ = try await index.prepare(modelId: "m", dimensions: 32)
        let store = AdaptiveVectorStore(db: db, index: index)
        let filtered = try store.nearest(to: vectors[0], modelId: "m", limit: 5,
            matching: .init(extensions: ["pdf"]), parsedQuery: .init())
        XCTAssertTrue(filtered.isEmpty)
        var source = try XCTUnwrap(try db.source(id: "s")); source.enabled = false
        try db.upsertSource(source)
        XCTAssertTrue(try store.nearest(to: vectors[0], modelId: "m", limit: 5).isEmpty)
    }

    func testBudgetFallbackAndCheckpointResume() async throws {
        let (db, _, vectors) = try fixture()
        let small = AdaptiveVectorIndex(database: db, minimumVectors: 1, memoryBudget: 1024)
        let denied = try await small.prepare(modelId: "m", dimensions: 32)
        XCTAssertFalse(denied)
        XCTAssertFalse(small.isReady)
        let index = AdaptiveVectorIndex(database: db, minimumVectors: 1)
        let gate = VectorBuildGate()
        do {
            _ = try await index.prepare(modelId: "m", dimensions: 32, checkpoint: { _ in try gate.checkpoint() })
            XCTFail("The partial build must yield")
        } catch is VectorBuildYield {}
        XCTAssertFalse(index.isReady)
        let resumed = try await index.prepare(modelId: "m", dimensions: 32)
        XCTAssertTrue(resumed)
        XCTAssertNotNil(try index.nearest(vectors[0], modelId: "m", limit: 5))
        index.release()
        XCTAssertFalse(index.isReady)
    }

    func testJournalOnlyTracksActiveGraphAndBothSidesOfModelChange() throws {
        let (db, ids, vectors) = try fixture(count: 2)
        XCTAssertEqual(try db.vectorRevision(modelId: "m"), 2)
        XCTAssertTrue(try db.vectorChanges(modelId: "m", after: 0).isEmpty)
        let baseline = try db.beginVectorTracking(modelId: "m")
        try db.upsertEmbedding(chunkId: ids[0], modelId: "other", textHash: "new", vector: vectors[0])
        let changes = try db.vectorChanges(modelId: "m", after: baseline)
        XCTAssertEqual(changes.count, 1)
        XCTAssertNil(changes.first?.vector)
        XCTAssertEqual(try db.vectorRevision(modelId: "m"), 3)
        XCTAssertEqual(try db.vectorRevision(modelId: "other"), 1)
        try db.acknowledgeVectorChanges(modelId: "m", through: 3)
        XCTAssertTrue(try db.vectorChanges(modelId: "m", after: 0).isEmpty)
    }
}
