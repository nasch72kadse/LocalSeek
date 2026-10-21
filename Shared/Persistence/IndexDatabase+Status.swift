import Foundation
import GRDB

public struct IndexStatusSnapshot: Sendable {
    public let sources: [SourceRecord]
    public let fileCounts: [String: Int]
    public let chunks: Int
    public let embeddings: Int
    public let jobs: JobCounts
    public let favoritesRevision: Int64
    public let favorites: Set<Int64>?
}

extension IndexDatabase {
    /// One consistent, cancellation-aware reader; never aggregate on the UI thread.
    public func statusSnapshot(modelId: String?, knownFavoritesRevision: Int64? = nil) async throws -> IndexStatusSnapshot {
        try await dbPool.read { db in
            let sources = try SourceRecord.order(Column("path")).fetchAll(db)
            let counts = try Row.fetchAll(db, sql: "SELECT sourceId, COUNT(*) AS count FROM files WHERE state != 'deleted' GROUP BY sourceId")
            let fileCounts = Dictionary(uniqueKeysWithValues: counts.map { row -> (String, Int) in (row["sourceId"], row["count"]) })
            var jobs = JobCounts()
            for row in try Row.fetchAll(db, sql: "SELECT state, kind, COUNT(*) AS count FROM jobs GROUP BY state, kind") {
                let state: String = row["state"], kind: String = row["kind"], count: Int = row["count"]
                if ["queued", "retry"].contains(state), kind != "maintenance" { jobs.pending += count }
                if state == "running" { jobs.running += count }
                if state == "failed" { jobs.failed += count }
            }
            jobs.extractionFailures = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM file_failures") ?? 0
            jobs.embeddingFailures = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embedding_failures") ?? 0
            let revision = try Int64.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'favoritesRevision'") ?? 0
            let favorites = revision == knownFavoritesRevision ? nil : Set(try Int64.fetchAll(db, sql: "SELECT fileId FROM favorites"))
            return IndexStatusSnapshot(sources: sources, fileCounts: fileCounts,
                chunks: try ChunkRecord.fetchCount(db),
                embeddings: try modelId.map { try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunk_vectors_v1 WHERE modelId = ?", arguments: [$0]) ?? 0 } ?? 0,
                jobs: jobs, favoritesRevision: revision, favorites: favorites)
        }
    }
}
