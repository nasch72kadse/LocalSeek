import Foundation
import GRDB

public protocol OCRResultCaching: Sendable {
    func lookup(key: String) throws -> [String]?
    func store(_ lines: [String], key: String) throws
}

/// Derived OCR text remains tied to its file row and is removed by FK cascade.
/// The shared byte counter makes eviction independent of cache entry count.
public final class DatabaseOCRCache: OCRResultCaching, @unchecked Sendable {
    private let db: IndexDatabase
    private let fileId: Int64
    private let maximumBytes: Int
    private let lock = NSLock()
    private var used: Set<String> = []
    public init(db: IndexDatabase, fileId: Int64, maximumBytes: Int = 64 * 1024 * 1024) {
        self.db = db; self.fileId = fileId; self.maximumBytes = max(0, maximumBytes)
    }
    private func note(_ key: String) { lock.lock(); used.insert(key); lock.unlock() }
    public var usedKeys: Set<String> { lock.lock(); defer { lock.unlock() }; return used }

    public func lookup(key: String) throws -> [String]? {
        note(key)
        let now = Date().timeIntervalSince1970
        let row = try db.dbPool.read { try Row.fetchOne($0, sql: """
            SELECT lines, lastUsed FROM ocr_cache WHERE fileId = ? AND cacheKey = ?
            """, arguments: [fileId, key]) }
        guard let row, now - (row["lastUsed"] as Double) < 30 * 86400 else { return nil }
        let data: Data = row["lines"]
        guard data.count <= 4 * 1024 * 1024,
              let lines = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        if now - (row["lastUsed"] as Double) >= 3600 {
            try db.dbPool.write { try $0.execute(sql: """
                UPDATE ocr_cache SET lastUsed = ? WHERE fileId = ? AND cacheKey = ?
                """, arguments: [now, fileId, key]) }
        }
        return lines
    }

    public func store(_ lines: [String], key: String) throws {
        note(key)
        let data = try JSONEncoder().encode(lines)
        guard data.count <= min(maximumBytes, 4 * 1024 * 1024) else { return }
        let now = Date().timeIntervalSince1970
        try db.dbPool.write { connection in
            // Source/file removal during extraction must not recreate private cache rows.
            guard try Int.fetchOne(connection, sql: "SELECT id FROM files WHERE id = ?", arguments: [fileId]) != nil else { return }
            try connection.execute(sql: """
                INSERT INTO ocr_cache(fileId, cacheKey, lines, byteCount, lastUsed) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(fileId, cacheKey) DO UPDATE SET lines = excluded.lines,
                    byteCount = excluded.byteCount, lastUsed = excluded.lastUsed
                """, arguments: [fileId, key, data, data.count, now])
            try connection.execute(sql: "DELETE FROM ocr_cache WHERE lastUsed < ?", arguments: [now - 30 * 86400])
            while try Bool.fetchOne(connection, sql: "SELECT bytes > ? OR entries > 32768 FROM ocr_cache_budget WHERE id = 1",
                                    arguments: [maximumBytes]) == true {
                try connection.execute(sql: """
                    DELETE FROM ocr_cache WHERE rowid IN
                    (SELECT rowid FROM ocr_cache WHERE NOT(fileId = ? AND cacheKey = ?)
                     ORDER BY lastUsed, rowid LIMIT 16)
                    """, arguments: [fileId, key])
            }
        }
    }
}
