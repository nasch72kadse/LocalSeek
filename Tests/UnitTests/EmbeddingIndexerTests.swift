import XCTest
import GRDB
@testable import SharedCore

/// Provider, der absichtlich einen Vektor falscher Länge liefert (für den Guard-Test).
private struct WrongLengthProvider: EmbeddingProvider {
    let dimensions = 3
    func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]] {
        texts.map { _ in [1, 0] }   // Länge 2 ≠ dimensions 3
    }
}

final class EmbeddingIndexerTests: XCTestCase {
    private func makeDB() throws -> IndexDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("localseek-emb-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("index.sqlite")
        return try IndexDatabase(url: url)
    }

    private func seed(_ db: IndexDatabase, _ texts: [String]) throws -> [Int64] {
        try db.upsertSource(SourceRecord(id: "s1", path: "/tmp/s1"))
        try db.upsertFile(FileRecord(sourceId: "s1", relativePath: "a.txt", filename: "a.txt",
                                     fileExtension: "txt", size: 1, mtime: nil))
        let fileId = try db.dbPool.read { try Int64.fetchOne($0, sql: "SELECT id FROM files")! }
        try db.replaceChunks(fileId: fileId, chunks: texts.enumerated().map {
            ChunkRecord(fileId: fileId, ordinal: $0.offset, text: $0.element)
        })
        return try db.dbPool.read { try Int64.fetchAll($0, sql: "SELECT id FROM chunks ORDER BY id") }
    }

    func testEmbedsAllPendingChunks() async throws {
        let db = try makeDB()
        _ = try seed(db, ["Risiko", "Zahlung"])
        let indexer = EmbeddingIndexer(provider: FakeEmbeddingProvider(), store: BruteForceVectorStore(db: db))
        let n = try await indexer.indexEmbeddings(modelId: "fake-3", into: db)
        XCTAssertEqual(n, 2)
        XCTAssertEqual(try db.embeddingCount(modelId: "fake-3"), 2)
    }

    func testNoReembedWhenUnchanged() async throws {
        let db = try makeDB()
        _ = try seed(db, ["Risiko"])
        let indexer = EmbeddingIndexer(provider: FakeEmbeddingProvider(), store: BruteForceVectorStore(db: db))
        _ = try await indexer.indexEmbeddings(modelId: "fake-3", into: db)
        let second = try await indexer.indexEmbeddings(modelId: "fake-3", into: db)
        XCTAssertEqual(second, 0, "Unveränderte Chunks nicht erneut einbetten")
    }

    func testModelSwitchReembedsAll() async throws {
        let db = try makeDB()
        _ = try seed(db, ["Risiko", "Zahlung"])
        let indexer = EmbeddingIndexer(provider: FakeEmbeddingProvider(), store: BruteForceVectorStore(db: db))
        _ = try await indexer.indexEmbeddings(modelId: "m1", into: db)
        let afterSwitch = try await indexer.indexEmbeddings(modelId: "m2", into: db)
        XCTAssertEqual(afterSwitch, 2, "Modellwechsel macht alte Vektoren veraltet")
    }

    func testThrowsOnDimensionMismatch() async throws {
        let db = try makeDB()
        _ = try seed(db, ["Risiko"])
        let indexer = EmbeddingIndexer(provider: WrongLengthProvider(), store: BruteForceVectorStore(db: db))
        do {
            _ = try await indexer.indexEmbeddings(modelId: "m", into: db)
            XCTFail("Erwarteter dimensionMismatch-Fehler")
        } catch EmbeddingError.dimensionMismatch(let expected, let got) {
            XCTAssertEqual(expected, 3)
            XCTAssertEqual(got, 2)
        }
    }

    func testPendingChunksBeyondFirstTenThousandAreNotStarved() async throws {
        let db = try makeDB()
        let ids = try seed(db, (0..<10_001).map { "chunk \($0)" })
        let blob = VectorBlob.data(from: [1, 0, 0])
        try await db.dbPool.write { connection in
            for (index, id) in ids.dropLast().enumerated() {
                try connection.execute(sql: "INSERT INTO chunk_vectors_v1(chunkId, embedding, modelId, textHash, norm) VALUES (?, ?, ?, ?, 1)",
                    arguments: [id, blob, "fake-3", StableHash.hex("chunk \(index)")])
            }
        }
        let indexer = EmbeddingIndexer(provider: FakeEmbeddingProvider(), store: BruteForceVectorStore(db: db))
        let processed = try await indexer.indexEmbeddings(modelId: "fake-3", into: db)
        XCTAssertEqual(processed, 1)
        XCTAssertEqual(try db.embeddingCount(modelId: "fake-3"), 10_001)
    }
}
