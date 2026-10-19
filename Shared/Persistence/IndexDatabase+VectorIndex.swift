import Foundation
import GRDB

struct IndexedVector: Sendable {
    let id: Int64
    let vector: [Float]
}
struct VectorChange: Sendable {
    let sequence: Int64
    let id: Int64
    let vector: [Float]?
}

extension IndexDatabase {
    public func vectorRevision(modelId: String) throws -> Int64 {
        try dbPool.read { try Int64.fetchOne($0, sql: "SELECT revision FROM vector_state WHERE modelId = ?",
                                            arguments: [modelId]) ?? 0 }
    }
    func hasVectorCount(_ minimum: Int, modelId: String) throws -> Bool {
        try dbPool.read { try Bool.fetchOne($0, sql: """
            SELECT EXISTS(SELECT 1 FROM chunk_vectors_v1 WHERE modelId = ? LIMIT 1 OFFSET ?)
            """, arguments: [modelId, max(0, minimum - 1)]) ?? false }
    }
    func beginVectorTracking(modelId: String) throws -> Int64 {
        try dbPool.write { db in
            let revision = try Int64.fetchOne(db, sql: "SELECT revision FROM vector_state WHERE modelId = ?",
                                             arguments: [modelId]) ?? 0
            try db.execute(sql: "DELETE FROM vector_tracking")
            try db.execute(sql: "DELETE FROM vector_changes")
            try db.execute(sql: "INSERT INTO vector_tracking(modelId, revision) VALUES (?, ?)", arguments: [modelId, revision])
            return revision
        }
    }
    func acknowledgeVectorChanges(modelId: String, through revision: Int64) throws {
        try dbPool.write {
            try $0.execute(sql: "DELETE FROM vector_changes WHERE modelId = ? AND sequence <= ?", arguments: [modelId, revision])
            try $0.execute(sql: "UPDATE vector_tracking SET revision = ? WHERE modelId = ?", arguments: [revision, modelId])
        }
    }
    func stopVectorTracking() throws {
        try dbPool.write {
            try $0.execute(sql: "DELETE FROM vector_tracking")
            try $0.execute(sql: "DELETE FROM vector_changes")
        }
    }
    func vectorsForIndex(modelId: String, afterId: Int64, limit: Int = 128) throws -> [IndexedVector] {
        try dbPool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT chunkId, embedding FROM chunk_vectors_v1
                WHERE modelId = ? AND chunkId > ? ORDER BY chunkId LIMIT ?
                """, arguments: [modelId, afterId, limit]).map {
                    IndexedVector(id: $0["chunkId"], vector: VectorBlob.vector(from: $0["embedding"]))
                }
        }
    }
    func vectorChanges(modelId: String, after revision: Int64) throws -> [VectorChange] {
        try dbPool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT vc.sequence, vc.chunkId, cv.embedding FROM vector_changes vc
                LEFT JOIN chunk_vectors_v1 cv ON cv.chunkId = vc.chunkId AND cv.modelId = vc.modelId
                WHERE vc.modelId = ? AND vc.sequence > ? ORDER BY vc.sequence LIMIT 128
                """, arguments: [modelId, revision]).map {
                    let data: Data? = $0["embedding"]
                    return VectorChange(sequence: $0["sequence"], id: $0["chunkId"], vector: data.map(VectorBlob.vector))
                }
        }
    }
    /// Re-rank ANN candidates against authoritative, current rows and visibility.
    func rankVectorCandidates(_ ids: [Int64], query: [Float], modelId: String, limit: Int) throws -> [VectorMatch] {
        let constraints = Self.fileConstraints(ParsedQuery(), filters: SearchFilters())
        return try dbPool.read { db in
            var matches: [VectorMatch] = []
            for offset in stride(from: 0, to: ids.count, by: 512) {
                try Task.checkCancellation()
                let group = Array(ids[offset..<min(offset + 512, ids.count)])
                let placeholders = group.map { _ in "?" }.joined(separator: ",")
                var args: [any DatabaseValueConvertible] = [modelId, query.count * 4]
                args.append(contentsOf: group)
                args.append(contentsOf: constraints.args)
                let rows = try Row.fetchAll(db, sql: """
                    SELECT cv.chunkId, cv.embedding FROM chunk_vectors_v1 cv
                    JOIN chunks ON chunks.id = cv.chunkId JOIN files ON files.id = chunks.fileId
                    WHERE cv.modelId = ? AND length(cv.embedding) = ? AND cv.norm > 0
                    AND cv.chunkId IN (\(placeholders)) AND \(constraints.sql)
                    """, arguments: StatementArguments(args))
                for row in rows {
                    let vector = VectorBlob.vector(from: row["embedding"])
                    let score = BruteForceVectorStore.cosine(query, vector)
                    if score.isFinite { matches.append(.init(chunkId: row["chunkId"], score: score)) }
                }
            }
            return Array(matches.sorted { $0.score == $1.score ? $0.chunkId < $1.chunkId : $0.score > $1.score }.prefix(limit))
        }
    }
}
