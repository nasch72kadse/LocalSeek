import XCTest
import GRDB
@testable import SharedCore

final class HybridSearchEngineTests: XCTestCase {
    private func makeDB() throws -> IndexDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("localseek-hyb-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("index.sqlite")
        return try IndexDatabase(url: url)
    }

    func testRRFPrefersConsensus() {
        // id 2 steht in beiden Listen vorn → sollte oben landen.
        let fused = HybridSearchEngine.rrf(fts: [1, 2, 3], vec: [2, 4, 1],
                                           ftsWeight: 0.55, vecWeight: 0.45, k: 60)
        XCTAssertEqual(fused.first, 2)
        XCTAssertEqual(Set(fused), Set([1, 2, 3, 4]))
    }

    func testExactFallbackWhenNoProvider() async throws {
        let db = try makeDB()
        try db.upsertSource(SourceRecord(id: "s1", path: "/tmp/s1"))
        try db.upsertFile(FileRecord(sourceId: "s1", relativePath: "a.txt", filename: "a.txt",
                                     fileExtension: "txt", size: 1, mtime: nil))
        let fileId = try await db.dbPool.read { try Int64.fetchOne($0, sql: "SELECT id FROM files")! }
        try db.replaceChunks(fileId: fileId, chunks: [
            ChunkRecord(fileId: fileId, ordinal: 0, text: "Risiko im Zahlungsverkehr")])

        let engine = HybridSearchEngine(db: db, provider: nil, store: nil, modelId: nil)
        let hybrid = try await engine.search("Zahlungsverkehr", strategy: .hybrid)
        XCTAssertEqual(hybrid.count, 1, "Ohne Modell fällt Hybrid auf lexikalisch zurück")
        XCTAssertEqual(hybrid.first?.fileId, fileId)
    }

    func testSemanticAndDocumentGrouping() async throws {
        let db = try makeDB()
        let store = BruteForceVectorStore(db: db)
        try db.upsertSource(SourceRecord(id: "s1", path: "/tmp/s1"))
        try db.upsertFile(FileRecord(sourceId: "s1", relativePath: "a.txt", filename: "a.txt",
                                     fileExtension: "txt", size: 1, mtime: nil))
        let fileId = try await db.dbPool.read { try Int64.fetchOne($0, sql: "SELECT id FROM files")! }
        try db.replaceChunks(fileId: fileId, chunks: [
            ChunkRecord(fileId: fileId, ordinal: 0, text: "nah"),
            ChunkRecord(fileId: fileId, ordinal: 1, text: "fern")])
        let ids = try await db.dbPool.read { try Int64.fetchAll($0, sql: "SELECT id FROM chunks ORDER BY id") }
        try store.upsert(chunkId: ids[0], modelId: "m", textHash: "h0", embedding: [1, 0, 0])
        try store.upsert(chunkId: ids[1], modelId: "m", textHash: "h1", embedding: [0, 1, 0])

        // Fake-Provider, der die Query auf [1,0,0] abbildet → Chunk 0 am nächsten.
        struct QV: EmbeddingProvider {
            let dimensions = 3
            func embed(_ t: [String], kind: EmbeddingKind) async throws -> [[Float]] { t.map { _ in [1, 0, 0] } }
        }
        let engine = HybridSearchEngine(db: db, provider: QV(), store: store, modelId: "m")
        let hits = try await engine.search("egal", strategy: .semantic)
        XCTAssertEqual(hits.count, 1, "Beide Chunks gehören zu einer Datei → ein Dokument-Treffer")
        XCTAssertEqual(hits.first?.ordinal, 0, "Bester (nächster) Chunk zuerst")
    }

    func testHybridKeepsLexicalResultsWhenModelFails() async throws {
        struct FailingProvider: EmbeddingProvider {
            let dimensions = 384
            func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]] {
                throw EmbeddingError.modelLoadFailed
            }
        }
        let db = try makeDB()
        try db.upsertSource(SourceRecord(id: "s1", path: "/tmp/s1"))
        try db.upsertFile(FileRecord(sourceId: "s1", relativePath: "a.txt", filename: "a.txt",
                                     fileExtension: "txt", size: 1, mtime: nil))
        let fileId = try await db.dbPool.read { try Int64.fetchOne($0, sql: "SELECT id FROM files")! }
        try db.replaceChunks(fileId: fileId, chunks: [
            ChunkRecord(fileId: fileId, ordinal: 0, text: "Risiko im Zahlungsverkehr")])
        let engine = HybridSearchEngine(db: db, provider: FailingProvider(),
                                        store: BruteForceVectorStore(db: db), modelId: "broken")
        let hits = try await engine.search("Zahlungsverkehr", strategy: .hybrid)
        XCTAssertEqual(hits.first?.fileId, fileId)
    }
}
