import Foundation

public struct EmbeddingBatchResult: Sendable {
    public var processed: Int = 0
    public var lastID: Int64 = 0
}

/// Small bounded inference batches, one atomic database write per batch.
public struct EmbeddingIndexer: Sendable {
    private let provider: any EmbeddingProvider
    private let store: any VectorStore
    public init(provider: any EmbeddingProvider, store: any VectorStore) {
        self.provider = provider; self.store = store
    }

    @discardableResult
    public func indexEmbeddings(modelId: String, into db: IndexDatabase, sourceId: String? = nil,
                                checkpoint: IndexCheckpoint = { _ in try Task.checkCancellation() }) async throws -> Int {
        try await indexBatch(modelId: modelId, into: db, sourceId: sourceId,
            maxChunks: .max, maxSeconds: .infinity, checkpoint: checkpoint).processed
    }

    public func indexBatch(modelId: String, into db: IndexDatabase, sourceId: String? = nil,
                           afterId: Int64 = 0, maxChunks: Int = 64, maxSeconds: TimeInterval = 2,
                           checkpoint: IndexCheckpoint = { _ in try Task.checkCancellation() }) async throws -> EmbeddingBatchResult {
        guard maxChunks > 0, maxSeconds > 0 else { throw ExtractionError.resourceLimit }
        var result = EmbeddingBatchResult(lastID: afterId)
        var attempted = 0
        let deadline = ProcessInfo.processInfo.systemUptime + maxSeconds
        while attempted < maxChunks && ProcessInfo.processInfo.systemUptime < deadline {
            let pending = try db.chunksNeedingEmbedding(modelId: modelId,
                limit: min(4, maxChunks - attempted), afterId: result.lastID, sourceId: sourceId)
            if pending.isEmpty { break }
            try await checkpoint(.embedding)
            var writes: [EmbeddingWrite] = []
            do {
                let vectors = try await provider.embed(pending.map(\.text), kind: .passage)
                guard vectors.count == pending.count else { throw EmbeddingError.inferenceFailed }
                for (chunk, vector) in zip(pending, vectors) {
                    writes.append(try write(chunk, vector: vector, modelId: modelId))
                }
            } catch EmbeddingError.inferenceFailed {
                // A bad text must not poison the other members of a batch.
                writes.removeAll(keepingCapacity: true)
                for chunk in pending {
                    try await checkpoint(.embedding)
                    do {
                        guard let vector = try await provider.embed([chunk.text], kind: .passage).first else {
                            throw EmbeddingError.inferenceFailed
                        }
                        writes.append(try write(chunk, vector: vector, modelId: modelId))
                    } catch EmbeddingError.inferenceFailed {
                        if let id = chunk.id { try db.recordEmbeddingFailure(chunkId: id, modelId: modelId) }
                    }
                }
            }
            try Task.checkCancellation()
            try store.upsertBatch(writes)
            result.processed += writes.count
            result.lastID = pending.last?.id ?? result.lastID
            attempted += pending.count
        }
        return result
    }

    private func write(_ chunk: ChunkRecord, vector: [Float], modelId: String) throws -> EmbeddingWrite {
        guard let id = chunk.id, vector.allSatisfy(\.isFinite), vector.contains(where: { $0 != 0 }) else {
            throw EmbeddingError.inferenceFailed
        }
        guard vector.count == provider.dimensions else {
            throw EmbeddingError.dimensionMismatch(expected: provider.dimensions, got: vector.count)
        }
        return EmbeddingWrite(chunkId: id, modelId: modelId, textHash: chunk.textHash,
                              embedding: vector, requireCurrentText: true)
    }
}
