import Foundation
import GRDB
import XCTest
@testable import SharedCore

private struct ReviewQueryProvider: EmbeddingProvider {
    let dimensions = 3
    func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]] { texts.map { _ in [1, 0, 0] } }
}
private final class QueryGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    func visit() { lock.withLock { count += 1 }; entered.signal(); Thread.sleep(forTimeInterval: 0.003) }
    func waitForEntry() -> Bool { entered.wait(timeout: .now() + 3) == .success }
    var visits: Int { lock.withLock { count } }
}

final class SearchImprovementTests: XCTestCase {
    private func fixture() throws -> IndexDatabase {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("search-improvement-" + UUID().uuidString)
        let db = try IndexDatabase(url: directory.appendingPathComponent("index.sqlite"))
        try db.upsertSource(.init(id: "s", path: directory.appendingPathComponent("source").path))
        addTeardownBlock { try db.dbPool.close(); try FileManager.default.removeItem(at: directory) }
        return db
    }
    private func document(_ db: IndexDatabase, name: String, count: Int, vector: [Float]) throws -> Int64 {
        try db.upsertFile(.init(sourceId: "s", relativePath: name, filename: name, fileExtension: URL(fileURLWithPath: name).pathExtension, size: 1, mtime: nil))
        let id = try XCTUnwrap(try db.searchFilenames(name).first?.id)
        try db.replaceChunks(fileId: id, chunks: (0..<count).map {
            .init(fileId: id, ordinal: $0, text: count > 1 ? "needle" : "needle additional context")
        })
        let ids = try db.dbPool.read { try Int64.fetchAll($0, sql: "SELECT id FROM chunks WHERE fileId = ? ORDER BY ordinal", arguments: [id]) }
        try db.upsertEmbeddings(ids.map { .init(chunkId: $0, modelId: "m", textHash: "fixture", embedding: vector) })
        return id
    }

    func testLargeDocumentCannotHideOtherMatchingDocumentsInAnyStrategy() async throws {
        let db = try fixture()
        let large = try document(db, name: "large.txt", count: 600, vector: [1, 0, 0])
        let small = try document(db, name: "small.txt", count: 1, vector: [0.9, 0.1, 0])
        let engine = HybridSearchEngine(db: db, provider: ReviewQueryProvider(), store: BruteForceVectorStore(db: db), modelId: "m")
        for strategy in [SearchStrategy.exact, .semantic, .hybrid] {
            let hits = try await engine.search("needle", strategy: strategy)
            XCTAssertEqual(Set(hits.map(\.fileId)), [large, small])
            XCTAssertEqual(hits.count, 2)
        }
    }

    func testDocumentPaginationAndFiltersRemainComplete() async throws {
        let db = try fixture()
        _ = try document(db, name: "large.txt", count: 600, vector: [1, 0, 0])
        let pdf = try document(db, name: "small.pdf", count: 1, vector: [0.9, 0.1, 0])
        _ = try document(db, name: "third.txt", count: 1, vector: [0.8, 0.2, 0])
        let engine = HybridSearchEngine(db: db, provider: ReviewQueryProvider(), store: BruteForceVectorStore(db: db), modelId: "m")
        for strategy in [SearchStrategy.exact, .semantic, .hybrid] {
            let first = try await engine.search("needle", strategy: strategy, limit: 2)
            let all = try await engine.search("needle", strategy: strategy, limit: 3)
            XCTAssertEqual(first.count, 2); XCTAssertEqual(all.count, 3)
            XCTAssertEqual(first.map(\.fileId), Array(all.prefix(2)).map(\.fileId))
            let filtered = try await engine.search("needle ext:pdf", strategy: strategy)
            XCTAssertEqual(filtered.map(\.fileId), [pdf])
        }
    }

    func testDocumentHeapUpdatesAndEvictsWithoutLosingBestChunks() {
        var heap = VectorHeap(capacity: 2)
        heap.offer(.init(chunkId: 1, score: 0.5), key: 10)
        heap.offer(.init(chunkId: 2, score: 0.4), key: 20)
        heap.offer(.init(chunkId: 3, score: 0.9), key: 10)
        heap.offer(.init(chunkId: 4, score: 0.8), key: 30)
        heap.offer(.init(chunkId: 5, score: 0.7), key: 10)
        XCTAssertEqual(heap.ranked.map(\.chunkId), [3, 4])
    }

    func testFilteredANNExpandsCandidatesAndRetainsDocumentDiversity() async throws {
        let db = try fixture()
        let large = try document(db, name: "large.txt", count: 600, vector: [1, 0, 0])
        let pdf = try document(db, name: "rare.txt", count: 1, vector: [0, 1, 0])
        let index = AdaptiveVectorIndex(database: db, minimumVectors: 1)
        let built = try await index.prepare(modelId: "m", dimensions: 3)
        XCTAssertTrue(built)
        let filtered = try XCTUnwrap(index.nearest([1, 0, 0], modelId: "m", limit: 50,
            filters: .init(extensions: ["txt"]), documents: true))
        let fileIDs = try db.fetchChunkHits(chunkIds: filtered.map(\.chunkId)).map(\.fileId)
        XCTAssertEqual(Set(fileIDs), [large, pdf])
        let matches = try XCTUnwrap(index.nearest([1, 0, 0], modelId: "m", limit: 50, documents: true))
        XCTAssertEqual(Set(try db.fetchChunkHits(chunkIds: matches.map(\.chunkId)).map(\.fileId)), [large, pdf])
    }

    func testStatusSnapshotInvalidatesFavoriteCacheOnCascadeDeletion() async throws {
        let db = try fixture()
        let id = try document(db, name: "one.txt", count: 2, vector: [1, 0, 0])
        let initial = try await db.statusSnapshot(modelId: "m")
        XCTAssertEqual(initial.fileCounts["s"], 1)
        XCTAssertEqual(initial.chunks, 2); XCTAssertEqual(initial.embeddings, 2)
        try db.toggleFavorite(fileId: id)
        let favorite = try await db.statusSnapshot(modelId: "m", knownFavoritesRevision: initial.favoritesRevision)
        XCTAssertEqual(favorite.favorites, [id])
        let unchanged = try await db.statusSnapshot(modelId: "m", knownFavoritesRevision: favorite.favoritesRevision)
        XCTAssertNil(unchanged.favorites)
        try db.removeMissingPath(sourceId: "s", relativePath: "one.txt")
        let removed = try await db.statusSnapshot(modelId: "m", knownFavoritesRevision: favorite.favoritesRevision)
        XCTAssertEqual(removed.favorites, [])
        XCTAssertNil(removed.fileCounts["s"])
    }

    func testSelectiveANNFallsBackToExactWhenCandidateBudgetIsExhausted() async throws {
        let db = try fixture()
        let large = try document(db, name: "large.txt", count: 600, vector: [1, 0, 0])
        let rare = try document(db, name: "rare.txt", count: 1, vector: [0, 1, 0])
        let index = AdaptiveVectorIndex(database: db, minimumVectors: 1, maximumCandidates: 32)
        let built = try await index.prepare(modelId: "m", dimensions: 3)
        XCTAssertTrue(built)
        XCTAssertNil(try index.nearest([1, 0, 0], modelId: "m", limit: 10,
            filters: .init(extensions: ["txt"]), documents: true))
        let matches = try AdaptiveVectorStore(db: db, index: index).nearestDocuments(to: [1, 0, 0], modelId: "m",
            limit: 10, matching: .init(extensions: ["txt"]), parsedQuery: .init())
        XCTAssertEqual(Set(try db.fetchChunkHits(chunkIds: matches.map(\.chunkId)).map(\.fileId)), [large, rare])
    }

    func testSmallFilteredSubsetUsesExactPlanAndRechecksCurrentVisibility() async throws {
        let db = try fixture()
        _ = try document(db, name: "large.txt", count: 600, vector: [1, 0, 0])
        let pdf = try document(db, name: "small.pdf", count: 1, vector: [0.9, 0.1, 0])
        let index = AdaptiveVectorIndex(database: db, minimumVectors: 1)
        let built = try await index.prepare(modelId: "m", dimensions: 3)
        XCTAssertTrue(built)
        let filter = SearchFilters(extensions: ["pdf"])
        XCTAssertNil(try index.nearest([1, 0, 0], modelId: "m", limit: 50, filters: filter, documents: true))
        let store = AdaptiveVectorStore(db: db, index: index)
        let matches = try store.nearestDocuments(to: [1, 0, 0], modelId: "m", limit: 50, matching: filter, parsedQuery: .init())
        XCTAssertEqual(try db.fetchChunkHits(chunkIds: matches.map(\.chunkId)).map(\.fileId), [pdf])
        XCTAssertNil(try db.claimNextJob(), "An exact filter plan must not schedule a rebuild of the current graph")
        var source = try XCTUnwrap(db.source(id: "s")); source.enabled = false
        try db.upsertSource(source)
        XCTAssertTrue(try store.nearestDocuments(to: [1, 0, 0], modelId: "m", limit: 50, matching: filter, parsedQuery: .init()).isEmpty)
    }

    func testCancelledFilenameReadStopsSQLWithoutInterruptingAnotherReader() async throws {
        let db = try fixture()
        try db.upsertFiles((0..<400).map { .init(sourceId: "s", relativePath: "file\($0).txt", filename: "file\($0).txt", fileExtension: "txt", size: 1, mtime: nil) })
        let gate = QueryGate()
        try await db.dbPool.read { connection in
            connection.add(function: DatabaseFunction("lower", argumentCount: 1, pure: false) { values in
                gate.visit(); return String.fromDatabaseValue(values[0])?.lowercased()
            })
        }
        let search = Task { try await db.searchFilenamesAsync("file", limit: 50) }
        let started = await Task.detached { gate.waitForEntry() }.value
        XCTAssertTrue(started)
        let began = ProcessInfo.processInfo.systemUptime
        search.cancel()
        do { _ = try await search.value; XCTFail("Cancelled query must stop") }
        catch is CancellationError {}
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 1)
        XCTAssertLessThan(gate.visits, 100)
        let next = try await db.searchFilenamesAsync("ext:pdf")
        XCTAssertTrue(next.isEmpty)
    }
}
