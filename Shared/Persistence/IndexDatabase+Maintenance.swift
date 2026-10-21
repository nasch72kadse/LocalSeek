import Foundation
import GRDB

public struct IndexHealth: Sendable, Equatable {
    public let repairedFTS: Bool
    public let removedInvalidVectors: Int
}

public enum IndexIntegrityError: Error { case corruptDatabase, foreignKeys }

extension IndexDatabase {
    /// Validate the authoritative tables first. Derived indexes may be rebuilt;
    /// corruption of the authoritative DB is reported rather than silently discarded.
    public func checkIntegrity(repair: Bool = true) throws -> IndexHealth {
        try dbPool.write { db in
            guard try String.fetchOne(db, sql: "PRAGMA quick_check") == "ok" else { throw IndexIntegrityError.corruptDatabase }
            guard try Row.fetchOne(db, sql: "PRAGMA foreign_key_check") == nil else { throw IndexIntegrityError.foreignKeys }
            var repaired = false
            do {
                try db.execute(sql: "INSERT INTO filename_fts(filename_fts, rank) VALUES('integrity-check', 1)")
                try db.execute(sql: "INSERT INTO chunk_fts(chunk_fts) VALUES('integrity-check')")
                let mismatches = try Int.fetchOne(db, sql: """
                    SELECT (SELECT COUNT(*) FROM chunks) != (SELECT COUNT(*) FROM chunk_fts)
                       OR EXISTS (SELECT 1 FROM chunks LEFT JOIN chunk_fts ON chunks.id = chunk_fts.rowid
                                  JOIN files ON files.id = chunks.fileId
                                  WHERE chunk_fts.rowid IS NULL OR chunk_fts.text != chunks.text
                                     OR chunk_fts.filename != files.filename OR chunk_fts.path != files.relativePath)
                    """) ?? 0
                if mismatches != 0 { throw IndexIntegrityError.corruptDatabase }
            } catch {
                guard repair else { throw error }
                try db.execute(sql: "INSERT INTO filename_fts(filename_fts) VALUES('rebuild')")
                try db.execute(sql: "DELETE FROM chunk_fts")
                try db.execute(sql: """
                    INSERT INTO chunk_fts(rowid, text, filename, path)
                    SELECT chunks.id, chunks.text, files.filename, files.relativePath
                    FROM chunks JOIN files ON files.id = chunks.fileId
                    """)
                repaired = true
            }
            var removed = 0, lastId: Int64 = 0
            var lastModel = ""
            while true {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT cv.chunkId, cv.modelId, cv.embedding, cv.norm, models.dimensions
                    FROM chunk_vectors_v1 cv LEFT JOIN models ON models.modelId = cv.modelId
                    WHERE cv.chunkId > ? OR (cv.chunkId = ? AND cv.modelId > ?) ORDER BY cv.chunkId, cv.modelId LIMIT 256
                    """, arguments: [lastId, lastId, lastModel])
                if rows.isEmpty { break }
                for row in rows {
                    let id: Int64 = row["chunkId"]
                    let model: String = row["modelId"]
                    lastId = id; lastModel = model
                    let data: Data = row["embedding"]
                    let dimensions: Int? = row["dimensions"]
                    let storedNorm: Double = row["norm"]
                    let values = VectorBlob.vector(from: data)
                    let norm = sqrt(values.reduce(Double(0)) { $0 + Double($1) * Double($1) })
                    if data.isEmpty || data.count % 4 != 0 || dimensions.map({ $0 != values.count }) == true
                        || !norm.isFinite || norm <= 0 || !values.allSatisfy(\.isFinite) {
                        guard repair else { throw IndexIntegrityError.corruptDatabase }
                        try db.execute(sql: "DELETE FROM chunk_vectors_v1 WHERE chunkId = ? AND modelId = ?", arguments: [id, model])
                        removed += 1
                    } else if !storedNorm.isFinite || abs(storedNorm - norm) > max(0.000001, norm * 0.000001) {
                        guard repair else { throw IndexIntegrityError.corruptDatabase }
                        try db.execute(sql: "UPDATE chunk_vectors_v1 SET norm = ? WHERE chunkId = ? AND modelId = ?", arguments: [norm, id, model])
                    }
                }
            }
            try db.execute(sql: "INSERT INTO settings(key,value) VALUES ('lastIntegrityCheck', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                           arguments: [String(Date().timeIntervalSince1970)])
            return IndexHealth(repairedFTS: repaired, removedInvalidVectors: removed)
        }
    }

    public func checkpoint() throws {
        try dbPool.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
    }

    public func rebuildDerivedIndex() throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM pdf_progress")
            try db.execute(sql: "DELETE FROM chunks")
            try db.execute(sql: "UPDATE files SET contentMtime = NULL, contentVersion = ''")
            try db.execute(sql: "DELETE FROM file_failures")
            try db.execute(sql: "INSERT INTO filename_fts(filename_fts) VALUES('rebuild')")
        }
    }
}
