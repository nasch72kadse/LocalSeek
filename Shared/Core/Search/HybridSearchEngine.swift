import Foundation

public enum SearchStrategy: Sendable, Hashable { case exact, semantic, hybrid }

/// Fusioniert lexikalische (BM25) und semantische (Vektor) Suche per Reciprocal Rank Fusion,
/// gruppiert nach Dokument (bester Chunk je Datei zuerst). Fällt bei fehlendem Modell/leerem
/// Vektorindex still auf rein lexikalische Suche zurück (SPEC §6: exakte Suche immer verfügbar).
public struct HybridSearchEngine: Sendable {
    private let db: IndexDatabase
    private let provider: (any EmbeddingProvider)?
    private let store: (any VectorStore)?
    private let modelId: String?
    private let ftsWeight: Double
    private let vecWeight: Double
    private let rrfK: Double

    public init(db: IndexDatabase, provider: (any EmbeddingProvider)?, store: (any VectorStore)?,
                modelId: String?, ftsWeight: Double = 0.55, vecWeight: Double = 0.45, rrfK: Double = 60) {
        self.db = db; self.provider = provider; self.store = store; self.modelId = modelId
        self.ftsWeight = ftsWeight; self.vecWeight = vecWeight; self.rrfK = rrfK
    }

    public func search(_ query: String, strategy: SearchStrategy, limit: Int = 50,
                       filters: SearchFilters = SearchFilters()) async throws -> [ContentSearchHit] {
        try Task.checkCancellation()
        guard limit > 0 else { return [] }
        if !QueryParser.parse(query).hasTextMatch {
            return try db.filenameContentHits(query, filters: filters, limit: limit)
        }
        switch strategy {
        case .exact:
            let names = try db.filenameContentHits(query, filters: filters, limit: limit)
            let chunks = try db.searchChunks(query, limit: limit * 3, filters: filters)
            return groupByDocument(names + chunks, limit: limit)
        case .semantic: return try await semanticHits(query, limit: limit, filters: filters)
        case .hybrid:   return try await hybridHits(query, limit: limit, filters: filters)
        }
    }

    private func semanticHits(_ query: String, limit: Int, filters: SearchFilters) async throws -> [ContentSearchHit] {
        guard let ids = try await vectorChunkIds(query, limit: min(2000, limit * 10), filters: filters) else { return [] }
        return groupByDocument(try db.fetchChunkHits(chunkIds: ids), limit: limit)
    }

    private func hybridHits(_ query: String, limit: Int, filters: SearchFilters) async throws -> [ContentSearchHit] {
        let nameHits = try db.filenameContentHits(query, filters: filters, limit: limit)
        let ftsHits = try db.searchChunks(query, limit: limit * 3, filters: filters)
        let ftsIds = nameHits.map(\.chunkId) + ftsHits.map(\.chunkId)
        let vecIds: [Int64]?
        do {
            vecIds = try await vectorChunkIds(query, limit: min(2000, limit * 10), filters: filters)
        } catch is EmbeddingError {
            return groupByDocument(nameHits + ftsHits, limit: limit)
        }
        guard let vecIds, !vecIds.isEmpty else {
            return groupByDocument(nameHits + ftsHits, limit: limit)
        }
        let fusedIds = Self.rrf(fts: ftsIds, vec: vecIds, ftsWeight: ftsWeight, vecWeight: vecWeight, k: rrfK)
        let fetched = try db.fetchChunkHits(chunkIds: fusedIds.filter { $0 > 0 })
        let byID = Dictionary(uniqueKeysWithValues: (nameHits + fetched).map { ($0.chunkId, $0) })
        let exactNames = nameHits.filter { $0.filename.localizedCaseInsensitiveCompare(QueryParser.parse(query).searchText) == .orderedSame }
        return groupByDocument(exactNames + fusedIds.compactMap { byID[$0] }, limit: limit)
    }

    /// Query einbetten + Vektor-Nearest. `nil`, wenn kein Modell/Store aktiv.
    private func vectorChunkIds(_ query: String, limit: Int, filters: SearchFilters) async throws -> [Int64]? {
        guard let provider, let store, let modelId else { return nil }
        let parsed = QueryParser.parse(query)
        let vectors = try await provider.embed([parsed.searchText], kind: .query)
        try Task.checkCancellation()
        guard let qv = vectors.first else { return nil }
        return try store.nearest(to: qv, modelId: modelId, limit: limit,
                                 matching: filters, parsedQuery: parsed).map(\.chunkId)
    }

    /// Reine, DB-freie RRF-Fusion zweier Rang-Listen (Rang = Position). Höher = besser.
    public static func rrf(fts: [Int64], vec: [Int64], ftsWeight: Double, vecWeight: Double, k: Double) -> [Int64] {
        var score: [Int64: Double] = [:]
        for (rank, id) in fts.enumerated() { score[id, default: 0] += ftsWeight / (k + Double(rank + 1)) }
        for (rank, id) in vec.enumerated() { score[id, default: 0] += vecWeight / (k + Double(rank + 1)) }
        return score.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// Behält je Datei den bestplatzierten Chunk, Reihenfolge der Eingabe erhalten.
    private func groupByDocument(_ hits: [ContentSearchHit], limit: Int) -> [ContentSearchHit] {
        var seen: Set<Int64> = []
        var out: [ContentSearchHit] = []
        for hit in hits where !seen.contains(hit.fileId) {
            seen.insert(hit.fileId); out.append(hit)
            if out.count == limit { break }
        }
        return out
    }
}
