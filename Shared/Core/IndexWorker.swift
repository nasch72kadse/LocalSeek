import Foundation

public struct IndexWorker: Sendable {
    private let db: IndexDatabase
    private let content: ContentIndexer
    private let provider: (any EmbeddingProvider)?
    private let modelId: String?
    private let scans = IndexScanCoordinator()

    public init(db: IndexDatabase, content: ContentIndexer = ContentIndexer(),
                provider: (any EmbeddingProvider)? = nil, modelId: String? = nil) {
        self.db = db; self.content = content; self.provider = provider; self.modelId = modelId
    }

    public func perform(_ job: IndexJob, checkpoint: IndexCheckpoint) async throws -> [IndexJobRequest] {
        let source = try job.sourceId.flatMap { try db.source(id: $0) }
        if let source, !source.enabled { return [] }
        if job.kind != .maintenance && job.kind != .vectorIndex && source == nil { return [] }
        switch job.kind {
        case .metadata:
            guard let source else { return [] }
            try await checkpoint(.metadata)
            do {
                if try await !scans.metadataBatch(source: source, job: job, db: db) {
                    return [.init(sourceId: source.id, kind: .content), .init(sourceId: source.id, kind: .metadata, priority: IndexJobKind.content.priority, cursor: 1)]
                }
            }
            catch DirectoryScanner.ScanError.partialEnumeration {
                return [.init(sourceId: source.id, kind: .content),
                        .init(sourceId: source.id, kind: .metadata, notBefore: Date().addingTimeInterval(30))]
            }
            return [.init(sourceId: source.id, kind: .content)]
        case .changes:
            guard let source else { return [] }
            try await checkpoint(.metadata)
            if try await !scans.changesBatch(source: source, job: job, db: db) {
                return [.init(sourceId: source.id, kind: .content), .init(sourceId: source.id, kind: .changes, priority: IndexJobKind.content.priority, cursor: 1)]
            }
            return []
        case .content:
            guard let source else { return [] }
            let pass = try await content.indexBatch(source: source, into: db, afterId: job.cursor, checkpoint: checkpoint)
            var followUps: [IndexJobRequest] = []
            if provider != nil { followUps.append(.init(sourceId: source.id, kind: .embeddings, priority: 5)) }
            if try content.hasRemainingContent(sourceId: source.id, in: db, afterId: pass.lastID) {
                followUps.append(.init(sourceId: source.id, kind: .content, cursor: pass.lastID))
            } else if try content.hasRemainingContent(sourceId: source.id, in: db) {
                followUps.append(.init(sourceId: source.id, kind: .content,
                    notBefore: Date().addingTimeInterval(pass.batteryDeferred ? 30 : 0)))
            } else if let retry = try db.nextExtractionRetry(sourceId: source.id) {
                followUps.append(.init(sourceId: source.id, kind: .content, notBefore: retry))
            }
            return followUps
        case .embeddings:
            guard let provider, let modelId else { return [] }
            let pass = try await EmbeddingIndexer(provider: provider, store: BruteForceVectorStore(db: db))
                .indexBatch(modelId: modelId, into: db, sourceId: source?.id, afterId: job.cursor, checkpoint: checkpoint)
            if !(try db.chunksNeedingEmbedding(modelId: modelId, limit: 1, afterId: pass.lastID, sourceId: source?.id)).isEmpty {
                return [.init(sourceId: source?.id, kind: .embeddings, priority: 15, cursor: pass.lastID)]
            }
            if !(try db.chunksNeedingEmbedding(modelId: modelId, limit: 1, sourceId: source?.id)).isEmpty {
                return [.init(sourceId: source?.id, kind: .embeddings, priority: 15)]
            }
            if let retry = try db.nextEmbeddingRetry(sourceId: source?.id, modelId: modelId) {
                return [.init(sourceId: source?.id, kind: .embeddings, notBefore: retry), .init(kind: .vectorIndex)]
            }
            return [.init(kind: .vectorIndex)]
        case .vectorIndex:
            guard let modelId, let provider else { return [] }
            try await db.vectorIndex.prepare(modelId: modelId, dimensions: provider.dimensions, checkpoint: checkpoint)
            return []
        case .maintenance:
            try await checkpoint(.maintenance)
            _ = try db.checkIntegrity()
            try db.checkpoint()
            return try db.allSources().filter(\.enabled).map { .init(sourceId: $0.id, kind: .metadata) }
                + [.init(kind: .maintenance, notBefore: Date().addingTimeInterval(12 * 3600))]
        }
    }
}
