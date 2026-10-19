import XCTest
import GRDB
@testable import SharedCore

final class VectorStoreTests: XCTestCase {
    private func makeDB() throws -> IndexDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("localseek-vec-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("index.sqlite")
        return try IndexDatabase(url: url)
    }

    private func seedChunk(_ db: IndexDatabase, text: String, ordinal: Int = 0) throws -> Int64 {
        try db.upsertSource(SourceRecord(id: "s1", path: "/tmp/s1"))
        try db.upsertFile(FileRecord(sourceId: "s1", relativePath: "f\(ordinal).txt",
                                     filename: "f\(ordinal).txt", fileExtension: "txt",
                                     size: 1, mtime: nil))
        let fileId = try db.dbPool.read { dbc in
            try Int64.fetchOne(dbc, sql: "SELECT id FROM files WHERE relativePath = ?",
                               arguments: ["f\(ordinal).txt"])!
        }
        try db.replaceChunks(fileId: fileId, chunks: [ChunkRecord(fileId: fileId, ordinal: 0, text: text)])
        return try db.dbPool.read { dbc in
            try Int64.fetchOne(dbc, sql: "SELECT id FROM chunks WHERE fileId = ?", arguments: [fileId])!
        }
    }

    func testBlobRoundTrip() {
        let v: [Float] = [0.1, -0.5, 1.0, 0.0]
        XCTAssertEqual(VectorBlob.vector(from: VectorBlob.data(from: v)), v)
    }

    func testNearestRanksByCosine() throws {
        let db = try makeDB()
        let store = BruteForceVectorStore(db: db)
        let near = try seedChunk(db, text: "a", ordinal: 0)
        let far  = try seedChunk(db, text: "b", ordinal: 1)
        try store.upsert(chunkId: near, modelId: "m", textHash: "h1", embedding: [1, 0, 0])
        try store.upsert(chunkId: far,  modelId: "m", textHash: "h2", embedding: [0, 1, 0])

        let hits = try store.nearest(to: [0.9, 0.1, 0], modelId: "m", limit: 10)
        XCTAssertEqual(hits.map(\.chunkId), [near, far])
        XCTAssertGreaterThan(hits[0].score, hits[1].score)
    }

    func testModelScopingAndEmptyIndex() throws {
        let db = try makeDB()
        let store = BruteForceVectorStore(db: db)
        let c = try seedChunk(db, text: "a")
        try store.upsert(chunkId: c, modelId: "m1", textHash: "h", embedding: [1, 0, 0])
        XCTAssertEqual(try store.nearest(to: [1, 0, 0], modelId: "m2", limit: 5), [])
        XCTAssertEqual(try db.embeddingCount(modelId: "m1"), 1)
    }

    func testCascadeDeleteRemovesVectors() throws {
        let db = try makeDB()
        let store = BruteForceVectorStore(db: db)
        let c = try seedChunk(db, text: "a")
        try store.upsert(chunkId: c, modelId: "m", textHash: "h", embedding: [1, 0, 0])
        try db.removeSource(id: "s1")
        XCTAssertEqual(try db.embeddingCount(), 0)
    }

    func testChunksNeedingEmbeddingIncremental() throws {
        let db = try makeDB()
        let store = BruteForceVectorStore(db: db)
        let c = try seedChunk(db, text: "Risiko im Zahlungsverkehr")
        XCTAssertEqual(try db.chunksNeedingEmbedding(modelId: "m").map(\.id), [c])
        try store.upsert(chunkId: c, modelId: "m",
                         textHash: StableHash.hex("Risiko im Zahlungsverkehr"), embedding: [1, 0, 0])
        XCTAssertTrue(try db.chunksNeedingEmbedding(modelId: "m").isEmpty)
        XCTAssertEqual(try db.chunksNeedingEmbedding(modelId: "other").map(\.id), [c])
    }
}
