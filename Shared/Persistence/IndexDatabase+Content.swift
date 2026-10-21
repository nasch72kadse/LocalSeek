import Foundation
import GRDB

extension IndexDatabase {
    static func writeChunks(fileId: Int64, chunks: [ChunkRecord], in db: Database) throws {
        guard let file = try FileRecord.fetchOne(db, key: fileId) else {
            throw DatabaseError(message: "Indexed file no longer exists")
        }
        let existing = try ChunkRecord.filter(Column("fileId") == fileId).order(Column("ordinal")).fetchAll(db)
        func key(_ chunk: ChunkRecord) -> String {
            "\(chunk.locationType)\u{0}\(chunk.locationValue)\u{0}\(StableHash.hex(chunk.text))"
        }
        var reusable = Dictionary(grouping: existing, by: key)
        var retained = Set<Int64>()
        // Free the ordinal namespace while reordering unchanged chunks in this transaction.
        try db.execute(sql: "UPDATE chunks SET ordinal = -ordinal - 1 WHERE fileId = ?", arguments: [fileId])
        for (ordinal, original) in chunks.enumerated() {
            var chunk = original
            chunk.fileId = fileId
            chunk.ordinal = ordinal
            chunk.textHash = StableHash.hex(chunk.text)
            let matchKey = key(chunk)
            if var matches = reusable[matchKey], !matches.isEmpty, let id = matches.removeFirst().id {
                reusable[matchKey] = matches
                retained.insert(id)
                try db.execute(sql: """
                    UPDATE chunks SET ordinal = ?, tokenCount = ?, textHash = ? WHERE id = ?
                    """, arguments: [ordinal, chunk.tokenCount, chunk.textHash, id])
                try db.execute(sql: """
                    UPDATE chunk_fts SET filename = ?, path = ? WHERE rowid = ?
                      AND (filename != ? OR path != ?)
                    """, arguments: [file.filename, file.relativePath, id, file.filename, file.relativePath])
            } else {
                chunk.id = nil
                try chunk.insert(db)
                if let id = chunk.id { retained.insert(id) }
                try db.execute(sql: "INSERT INTO chunk_fts(rowid, text, filename, path) VALUES (?, ?, ?, ?)",
                               arguments: [chunk.id, chunk.text, file.filename, file.relativePath])
            }
        }
        for old in existing where old.id.map({ !retained.contains($0) }) == true {
            try db.execute(sql: "DELETE FROM chunks WHERE id = ?", arguments: [old.id])
        }
    }

    /// The content, FTS changes and extraction stamp are committed together.
    public func storeContent(fileId: Int64, chunks: [ChunkRecord], mtime: Date, version: String,
                             usedOCRKeys: Set<String>? = nil) throws {
        try dbPool.write { db in
            try Self.writeChunks(fileId: fileId, chunks: chunks, in: db)
            try db.execute(sql: "DELETE FROM pdf_progress WHERE fileId = ?", arguments: [fileId])
            try db.execute(sql: "UPDATE files SET contentMtime = ?, contentVersion = ?, contentSize = size, contentIdentity = fileIdentity WHERE id = ?",
                           arguments: [mtime, version, fileId])
            try db.execute(sql: "DELETE FROM file_failures WHERE fileId = ?", arguments: [fileId])
            if let usedOCRKeys {
                if usedOCRKeys.isEmpty {
                    try db.execute(sql: "DELETE FROM ocr_cache WHERE fileId = ?", arguments: [fileId])
                } else {
                    let placeholders = usedOCRKeys.map { _ in "?" }.joined(separator: ",")
                    let args: [any DatabaseValueConvertible] = [fileId] + usedOCRKeys.sorted().map { $0 }
                    try db.execute(sql: "DELETE FROM ocr_cache WHERE fileId = ? AND cacheKey NOT IN (\(placeholders))",
                                   arguments: StatementArguments(args))
                }
            }
        }
    }

    public func recordExtractionFailure(fileId: Int64, code: String, now: Date = Date()) throws {
        try dbPool.write { db in
            let attempts = (try Int.fetchOne(db, sql: "SELECT attempts FROM file_failures WHERE fileId = ?",
                                            arguments: [fileId]) ?? 0) + 1
            let delay = min(12 * 3600, 30 * pow(2, Double(min(attempts - 1, 10))))
            try db.execute(sql: """
                INSERT INTO file_failures(fileId, attempts, errorCode, nextRetry) VALUES (?, ?, ?, ?)
                ON CONFLICT(fileId) DO UPDATE SET attempts = excluded.attempts,
                    errorCode = excluded.errorCode, nextRetry = excluded.nextRetry
                """, arguments: [fileId, attempts, code, now.addingTimeInterval(delay)])
        }
    }

    public func setFileState(id: Int64, state: String) throws {
        try dbPool.write { db in
            try db.execute(sql: "UPDATE files SET state = ? WHERE id = ?", arguments: [state, id])
        }
    }

    public func markSourceUnavailable(id: String) throws {
        try dbPool.write { db in
            try db.execute(sql: "UPDATE sources SET scanStatus = 'unavailable' WHERE id = ?", arguments: [id])
            try db.execute(sql: "UPDATE files SET state = 'unavailable' WHERE sourceId = ?", arguments: [id])
        }
    }
}
