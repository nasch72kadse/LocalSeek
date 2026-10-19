import Foundation
import GRDB

extension IndexDatabase {
    /// One commit per bounded inference batch; reject text changed during inference.
    public func upsertEmbeddings(_ writes: [EmbeddingWrite]) throws {
        try dbPool.write { db in
            let insert = try db.makeStatement(sql: """
                INSERT INTO chunk_vectors_v1(chunkId, embedding, modelId, textHash, norm)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(chunkId) DO UPDATE SET embedding = excluded.embedding,
                    modelId = excluded.modelId, textHash = excluded.textHash, norm = excluded.norm
                """)
            let clear = try db.makeStatement(sql: "DELETE FROM embedding_failures WHERE chunkId = ? AND modelId = ?")
            for write in writes {
                if write.requireCurrentText {
                    guard try String.fetchOne(db, sql: "SELECT textHash FROM chunks WHERE id = ?",
                                              arguments: [write.chunkId]) == write.textHash else { continue }
                }
                let norm = sqrt(write.embedding.reduce(Double(0)) { $0 + Double($1) * Double($1) })
                try insert.execute(arguments: [write.chunkId, VectorBlob.data(from: write.embedding),
                                                write.modelId, write.textHash, norm])
                try clear.execute(arguments: [write.chunkId, write.modelId])
            }
        }
    }
}
