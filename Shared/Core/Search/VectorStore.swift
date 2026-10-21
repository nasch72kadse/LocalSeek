import Foundation
import Accelerate
import GRDB

public struct VectorMatch: Sendable, Equatable {
    public let chunkId: Int64
    public let score: Double
    public init(chunkId: Int64, score: Double) { self.chunkId = chunkId; self.score = score }
}

public enum VectorStoreError: Error { case invalidVector, unsupportedFilters }

public struct EmbeddingWrite: Sendable {
    public let chunkId: Int64
    public let modelId: String
    public let textHash: String
    public let embedding: [Float]
    public let requireCurrentText: Bool
    public init(chunkId: Int64, modelId: String, textHash: String, embedding: [Float],
                requireCurrentText: Bool = false) {
        self.chunkId = chunkId; self.modelId = modelId; self.textHash = textHash
        self.embedding = embedding; self.requireCurrentText = requireCurrentText
    }
}

public protocol VectorStore: Sendable {
    func upsert(chunkId: Int64, modelId: String, textHash: String, embedding: [Float]) throws
    func upsertBatch(_ writes: [EmbeddingWrite]) throws
    func nearestDocuments(to query: [Float], modelId: String, limit: Int,
                          matching filters: SearchFilters, parsedQuery: ParsedQuery) throws -> [VectorMatch]
    func remove(chunkIds: [Int64]) throws
    func nearest(to query: [Float], modelId: String, limit: Int) throws -> [VectorMatch]
    func nearest(to query: [Float], modelId: String, limit: Int,
                 matching filters: SearchFilters, parsedQuery: ParsedQuery) throws -> [VectorMatch]
}

public extension VectorStore {
    func upsertBatch(_ writes: [EmbeddingWrite]) throws {
        for write in writes {
            try upsert(chunkId: write.chunkId, modelId: write.modelId,
                       textHash: write.textHash, embedding: write.embedding)
        }
    }
    func nearestDocuments(to query: [Float], modelId: String, limit: Int,
                          matching filters: SearchFilters, parsedQuery: ParsedQuery) throws -> [VectorMatch] {
        try nearest(to: query, modelId: modelId, limit: limit, matching: filters, parsedQuery: parsedQuery)
    }
    func nearest(to query: [Float], modelId: String, limit: Int,
                 matching filters: SearchFilters, parsedQuery: ParsedQuery) throws -> [VectorMatch] {
        guard filters.isEmpty, !parsedQuery.hasFilters else { throw VectorStoreError.unsupportedFilters }
        return try nearest(to: query, modelId: modelId, limit: limit)
    }
}

public enum VectorBlob {
    public static func data(from vector: [Float]) -> Data { vector.withUnsafeBytes { Data($0) } }
    public static func vector(from data: Data) -> [Float] {
        guard data.count % MemoryLayout<Float>.size == 0 else { return [] }
        var result = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        result.withUnsafeMutableBufferPointer { pointer in
            data.copyBytes(to: UnsafeMutableRawBufferPointer(start: pointer.baseAddress, count: data.count))
        }
        return result
    }
}

/// A bounded top-k heap: memory depends on k, never on the corpus size.
/// Indexed heap keeps one best candidate per key, bounded by the requested result count.
struct VectorHeap {
    private struct Entry { let key: Int64; let match: VectorMatch }
    private var entries: [Entry] = []
    private var positions: [Int64: Int] = [:]
    let capacity: Int
    private func worse(_ a: VectorMatch, _ b: VectorMatch) -> Bool {
        a.score < b.score || (a.score == b.score && a.chunkId > b.chunkId)
    }
    private mutating func swap(_ a: Int, _ b: Int) {
        entries.swapAt(a, b)
        positions[entries[a].key] = a; positions[entries[b].key] = b
    }
    private mutating func sink(_ start: Int) {
        var index = start
        while index * 2 + 1 < entries.count {
            var child = index * 2 + 1
            if child + 1 < entries.count && worse(entries[child + 1].match, entries[child].match) { child += 1 }
            if !worse(entries[child].match, entries[index].match) { break }
            swap(child, index); index = child
        }
    }
    mutating func offer(_ entry: VectorMatch, key suppliedKey: Int64? = nil) {
        guard capacity > 0 else { return }
        let key = suppliedKey ?? entry.chunkId
        if let index = positions[key] {
            guard worse(entries[index].match, entry) else { return }
            entries[index] = Entry(key: key, match: entry)
            sink(index)
        } else if entries.count < capacity {
            entries.append(Entry(key: key, match: entry)); positions[key] = entries.count - 1
            var index = entries.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                if !worse(entries[index].match, entries[parent].match) { break }
                swap(index, parent); index = parent
            }
        } else if let first = entries.first, worse(first.match, entry) {
            positions.removeValue(forKey: first.key)
            entries[0] = Entry(key: key, match: entry); positions[key] = 0
            sink(0)
        }
    }
    var ranked: [VectorMatch] {
        entries.map(\.match).sorted { $0.score == $1.score ? $0.chunkId < $1.chunkId : $0.score > $1.score }
    }
}

/// Stream SQLite blobs without copying the entire vector index into Swift arrays.
/// Filters are applied before selecting nearest candidates, for every search mode.
public struct BruteForceVectorStore: VectorStore {
    private let db: IndexDatabase
    public init(db: IndexDatabase) { self.db = db }

    public func upsert(chunkId: Int64, modelId: String, textHash: String, embedding: [Float]) throws {
        guard !embedding.isEmpty, embedding.count <= 8192, embedding.allSatisfy(\.isFinite),
              embedding.contains(where: { $0 != 0 }) else { throw VectorStoreError.invalidVector }
        try db.upsertEmbedding(chunkId: chunkId, modelId: modelId, textHash: textHash, vector: embedding)
    }
    public func upsertBatch(_ writes: [EmbeddingWrite]) throws {
        for write in writes {
            guard !write.embedding.isEmpty, write.embedding.count <= 8192,
                  write.embedding.allSatisfy(\.isFinite), write.embedding.contains(where: { $0 != 0 }) else {
                throw VectorStoreError.invalidVector
            }
        }
        try db.upsertEmbeddings(writes)
    }
    public func remove(chunkIds: [Int64]) throws { try db.removeEmbeddings(chunkIds: chunkIds) }
    public func nearest(to query: [Float], modelId: String, limit: Int) throws -> [VectorMatch] {
        try nearest(to: query, modelId: modelId, limit: limit, matching: SearchFilters(), parsedQuery: ParsedQuery())
    }

    public func nearest(to query: [Float], modelId: String, limit: Int,
                        matching filters: SearchFilters, parsedQuery: ParsedQuery) throws -> [VectorMatch] {
        try nearest(query, modelId: modelId, limit: limit, filters: filters, parsed: parsedQuery, documents: false)
    }
    public func nearestDocuments(to query: [Float], modelId: String, limit: Int,
                                 matching filters: SearchFilters, parsedQuery: ParsedQuery) throws -> [VectorMatch] {
        try nearest(query, modelId: modelId, limit: limit, filters: filters, parsed: parsedQuery, documents: true)
    }
    private func nearest(_ query: [Float], modelId: String, limit: Int,
                         filters: SearchFilters, parsed: ParsedQuery, documents: Bool) throws -> [VectorMatch] {
        guard limit > 0, !query.isEmpty, query.allSatisfy(\.isFinite) else { return [] }
        let queryNorm = sqrt(query.reduce(Double(0)) { $0 + Double($1) * Double($1) })
        guard queryNorm > 0, queryNorm.isFinite else { return [] }
        let constraints = IndexDatabase.fileConstraints(parsed, filters: filters)
        let args: [any DatabaseValueConvertible] = [modelId, query.count * 4] + constraints.args
        return try db.dbPool.read { connection in
            let cursor = try Row.fetchCursor(connection, sql: """
                SELECT cv.chunkId, cv.embedding, cv.norm, files.id AS fileId FROM chunk_vectors_v1 cv
                JOIN chunks ON chunks.id = cv.chunkId JOIN files ON files.id = chunks.fileId
                WHERE cv.modelId = ? AND length(cv.embedding) = ? AND cv.norm > 0 AND \(constraints.sql)
                """, arguments: StatementArguments(args))
            var heap = VectorHeap(capacity: min(limit, 2000))
            var scratch = [Float](repeating: 0, count: query.count)
            var processed = 0
            try query.withUnsafeBufferPointer { queryBuffer in
                try scratch.withUnsafeMutableBufferPointer { scratchBuffer in
                    while let row = try cursor.next() {
                        processed += 1
                        if processed % 256 == 0 { try Task.checkCancellation() }
                        let norm: Double = row[2]
                        guard norm.isFinite else { continue }
                        let score: Double? = try row.withUnsafeData(atIndex: 1) { data in
                            guard let data, data.count == query.count * 4 else { return nil }
                            return data.withUnsafeBytes { raw in
                                guard let base = raw.baseAddress else { return nil }
                                var dot: Float = 0
                                if Int(bitPattern: base) % MemoryLayout<Float>.alignment == 0 {
                                    vDSP_dotpr(queryBuffer.baseAddress!, 1, base.assumingMemoryBound(to: Float.self), 1,
                                               &dot, vDSP_Length(query.count))
                                } else {
                                    data.copyBytes(to: UnsafeMutableRawBufferPointer(start: scratchBuffer.baseAddress, count: data.count))
                                    vDSP_dotpr(queryBuffer.baseAddress!, 1, scratchBuffer.baseAddress!, 1,
                                               &dot, vDSP_Length(query.count))
                                }
                                return Double(dot) / (queryNorm * norm)
                            }
                        }
                        if let score, score.isFinite { heap.offer(VectorMatch(chunkId: row[0], score: score), key: documents ? row["fileId"] : nil) }
                    }
                }
            }
            return heap.ranked
        }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var dot: Float = 0, sa: Float = 0, sb: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &sa, vDSP_Length(a.count)); vDSP_svesq(b, 1, &sb, vDSP_Length(b.count))
        let denominator = sqrt(sa) * sqrt(sb)
        return denominator > 0 ? Double(dot / denominator) : 0
    }
}
