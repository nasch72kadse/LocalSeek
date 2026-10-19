import Foundation
import GRDB

public struct PendingFileEvent: Decodable, FetchableRecord, Sendable {
    public var id: Int64
    public var sourceId: String
    public var relativePath: String
}

extension IndexDatabase {
    public func enqueueFileEvents(sourceId: String, relativePaths: Set<String>) throws {
        try dbPool.write { db in
            guard try SourceRecord.fetchOne(db, key: sourceId)?.enabled == true else { return }
            let paths = relativePaths.count > 512 || relativePaths.contains("") ? Set([""]) : relativePaths
            for path in paths {
                guard DirectoryScanner.validRelativePath(path) else { continue }
                try db.execute(sql: """
                    INSERT INTO file_events(sourceId, relativePath) VALUES (?, ?)
                    ON CONFLICT(sourceId, relativePath) DO UPDATE SET id = excluded.id
                    """, arguments: [sourceId, path])
            }
            if (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM file_events WHERE sourceId = ?", arguments: [sourceId]) ?? 0) > 2048 {
                try db.execute(sql: """
                    INSERT INTO file_events(sourceId, relativePath) VALUES (?, '')
                    ON CONFLICT(sourceId, relativePath) DO UPDATE SET id = excluded.id
                    """, arguments: [sourceId])
                try db.execute(sql: "DELETE FROM file_events WHERE sourceId = ? AND relativePath != ''", arguments: [sourceId])
            }
            if !paths.isEmpty { try Self.enqueue(.init(sourceId: sourceId, kind: .changes), in: db) }
        }
    }

    public func pendingFileEvents(sourceId: String, limit: Int = 128) throws -> [PendingFileEvent] {
        try dbPool.read {
            try PendingFileEvent.fetchAll($0, sql: """
                SELECT * FROM file_events WHERE sourceId = ? ORDER BY id LIMIT ?
                """, arguments: [sourceId, limit])
        }
    }

    /// Delete only the exact event revisions consumed. The content hand-off is
    /// committed together, so a crash cannot lose work between these steps.
    public func completeFileEvents(_ events: [PendingFileEvent], job: IndexJob) throws {
        try dbPool.write { db in
            guard try String.fetchOne(db, sql: "SELECT state FROM jobs WHERE id = ?", arguments: [job.id]) == "running",
                  let sourceId = job.sourceId else { return }
            for event in events {
                try db.execute(sql: "DELETE FROM file_events WHERE id = ? AND sourceId = ?",
                               arguments: [event.id, sourceId])
            }
            try Self.enqueue(.init(sourceId: sourceId, kind: .content), in: db)
            if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM file_events WHERE sourceId = ?)",
                                 arguments: [sourceId]) == true {
                try Self.enqueue(.init(sourceId: sourceId, kind: .changes), in: db)
            }
        }
    }

    public func removeMissingPath(sourceId: String, relativePath: String) throws {
        guard !relativePath.isEmpty, DirectoryScanner.validRelativePath(relativePath) else { return }
        try dbPool.write {
            try $0.execute(sql: """
                DELETE FROM files WHERE sourceId = ? AND (relativePath = ? OR relativePath LIKE ? ESCAPE '\\')
                """, arguments: [sourceId, relativePath, Self.escapeLike(relativePath) + "/%"])
        }
    }
}
