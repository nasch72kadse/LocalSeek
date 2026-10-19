import Foundation
import GRDB

extension IndexDatabase {
    static func enqueue(_ request: IndexJobRequest, in db: Database) throws {
        if let sourceId = request.sourceId,
           try SourceRecord.fetchOne(db, key: sourceId) == nil { return }
        try db.execute(sql: """
            INSERT INTO jobs(id, sourceId, kind, state, priority, attempts, nextRetry, updatedAt, rerun, lastError, cursor)
            VALUES (?, ?, ?, 'queued', ?, 0, ?, ?, 0, '', ?)
            ON CONFLICT(id) DO UPDATE SET
                state = CASE WHEN jobs.state = 'running' THEN 'running' ELSE 'queued' END,
                priority = MIN(jobs.priority, excluded.priority),
                nextRetry = MIN(jobs.nextRetry, excluded.nextRetry),
                attempts = CASE WHEN jobs.state = 'running' THEN jobs.attempts ELSE 0 END,
                rerun = CASE WHEN jobs.state = 'running' THEN 1 ELSE jobs.rerun END,
                updatedAt = excluded.updatedAt, lastError = '', cursor = MIN(jobs.cursor, excluded.cursor)
            """, arguments: [request.id, request.sourceId, request.kind.rawValue,
                              request.priority, request.notBefore, Date(), request.cursor])
    }

    public func enqueueJobs(_ requests: [IndexJobRequest]) throws {
        try dbPool.write { db in for request in requests { try Self.enqueue(request, in: db) } }
    }

    public func recoverInterruptedJobs() throws {
        try dbPool.write { db in
            try db.execute(sql: "UPDATE jobs SET state = 'queued', nextRetry = ?, rerun = 0 WHERE state = 'running'",
                           arguments: [Date()])
            try db.execute(sql: "UPDATE sources SET scanStatus = 'idle' WHERE scanStatus = 'scanning'")
        }
    }

    public func claimNextJob(now: Date = Date()) throws -> IndexJob? {
        try dbPool.write { db in
            guard var job = try IndexJob.fetchOne(db, sql: """
                SELECT * FROM jobs WHERE state IN ('queued', 'retry') AND nextRetry <= ?
                ORDER BY priority, updatedAt, id LIMIT 1
                """, arguments: [now]) else { return nil }
            job.state = "running"; job.attempts += 1
            try db.execute(sql: "UPDATE jobs SET state = 'running', attempts = ?, updatedAt = ? WHERE id = ?",
                           arguments: [job.attempts, now, job.id])
            return job
        }
    }

    /// A crash cannot lose the hand-off between metadata, content and embeddings.
    public func finishJob(_ job: IndexJob, followUps: [IndexJobRequest]) throws {
        try dbPool.write { db in
            guard try String.fetchOne(db, sql: "SELECT state FROM jobs WHERE id = ?", arguments: [job.id]) == "running" else { return }
            if try Bool.fetchOne(db, sql: "SELECT rerun FROM jobs WHERE id = ?", arguments: [job.id]) == true {
                try db.execute(sql: "UPDATE jobs SET state = 'queued', attempts = 0, rerun = 0, cursor = 0, nextRetry = ? WHERE id = ?",
                               arguments: [Date(), job.id])
            } else {
                try db.execute(sql: "DELETE FROM jobs WHERE id = ?", arguments: [job.id])
            }
            for request in followUps { try Self.enqueue(request, in: db) }
        }
    }

    public func deferJob(_ job: IndexJob, code: String, resourcePause: Bool = false, now: Date = Date()) throws {
        let delay = resourcePause ? 30 : min(1800, 5 * pow(2, Double(min(job.attempts - 1, 9))))
        let state = !resourcePause && job.attempts >= 5 ? "failed" : "retry"
        try dbPool.write { db in
            try db.execute(sql: "UPDATE jobs SET state = ?, nextRetry = ?, lastError = ?, attempts = ? WHERE id = ?",
                           arguments: [state, now.addingTimeInterval(delay), code,
                                       resourcePause ? max(0, job.attempts - 1) : job.attempts, job.id])
        }
    }

    public func requeueJob(_ job: IndexJob) throws {
        try dbPool.write { db in
            try db.execute(sql: "UPDATE jobs SET state = 'queued', nextRetry = ?, attempts = MAX(0, attempts - 1) WHERE id = ?",
                           arguments: [Date(), job.id])
        }
    }

    public func nextJobDate() throws -> Date? {
        try dbPool.read { try Date.fetchOne($0, sql: "SELECT MIN(nextRetry) FROM jobs WHERE state IN ('queued', 'retry')") }
    }

    public func cancelJobs(sourceId: String) throws {
        try dbPool.write {
            try $0.execute(sql: "DELETE FROM jobs WHERE sourceId = ?", arguments: [sourceId])
            try $0.execute(sql: "DELETE FROM file_events WHERE sourceId = ?", arguments: [sourceId])
        }
    }

    public func source(id: String) throws -> SourceRecord? {
        try dbPool.read { try SourceRecord.fetchOne($0, key: id) }
    }

    public func nextExtractionRetry(sourceId: String) throws -> Date? {
        try dbPool.read { db in
            try Date.fetchOne(db, sql: """
                SELECT MIN(ff.nextRetry) FROM file_failures ff JOIN files ON files.id = ff.fileId
                WHERE files.sourceId = ? AND files.state = 'present' AND ff.attempts < 5 AND ff.nextRetry > ?
                """, arguments: [sourceId, Date()])
        }
    }

    public func clearExtractionFailures(sourceId: String? = nil) throws {
        try dbPool.write { db in
            if let sourceId {
                try db.execute(sql: "DELETE FROM file_failures WHERE fileId IN (SELECT id FROM files WHERE sourceId = ?)",
                               arguments: [sourceId])
                try db.execute(sql: "DELETE FROM embedding_failures WHERE chunkId IN (SELECT chunks.id FROM chunks JOIN files ON files.id = chunks.fileId WHERE files.sourceId = ?)", arguments: [sourceId])
            } else {
                try db.execute(sql: "DELETE FROM file_failures")
                try db.execute(sql: "DELETE FROM embedding_failures")
            }
        }
    }

    public func jobCounts() throws -> JobCounts {
        try dbPool.read { db in
            var counts = JobCounts()
            counts.pending = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM jobs WHERE state IN ('queued', 'retry') AND kind != 'maintenance'") ?? 0
            counts.running = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM jobs WHERE state = 'running'") ?? 0
            counts.failed = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM jobs WHERE state = 'failed'") ?? 0
            counts.extractionFailures = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM file_failures") ?? 0
            counts.embeddingFailures = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embedding_failures") ?? 0
            return counts
        }
    }

    public func setting(_ key: String) throws -> String? {
        try dbPool.read { try String.fetchOne($0, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key]) }
    }
    public func setSetting(_ key: String, value: String) throws {
        try dbPool.write { try $0.execute(sql: "INSERT INTO settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                                         arguments: [key, value]) }
    }

    public func recordEmbeddingFailure(chunkId: Int64, modelId: String) throws {
        try dbPool.write { db in
            let attempts = (try Int.fetchOne(db, sql: "SELECT attempts FROM embedding_failures WHERE chunkId = ? AND modelId = ?",
                                            arguments: [chunkId, modelId]) ?? 0) + 1
            let delay = min(12 * 3600, 30 * pow(2, Double(min(attempts - 1, 10))))
            try db.execute(sql: """
                INSERT INTO embedding_failures(chunkId, modelId, attempts, nextRetry) VALUES (?, ?, ?, ?)
                ON CONFLICT(chunkId, modelId) DO UPDATE SET attempts = excluded.attempts, nextRetry = excluded.nextRetry
                """, arguments: [chunkId, modelId, attempts, Date().addingTimeInterval(delay)])
        }
    }

    public func nextEmbeddingRetry(sourceId: String?, modelId: String) throws -> Date? {
        try dbPool.read { db in
            try Date.fetchOne(db, sql: """
                SELECT MIN(ef.nextRetry) FROM embedding_failures ef
                JOIN chunks ON chunks.id = ef.chunkId JOIN files ON files.id = chunks.fileId
                WHERE ef.modelId = ? AND (? IS NULL OR files.sourceId = ?) AND ef.attempts < 5 AND ef.nextRetry > ?
                """, arguments: [modelId, sourceId, sourceId, Date()])
        }
    }

    public func retryResourceJobs() throws {
        try dbPool.write { try $0.execute(sql: "UPDATE jobs SET nextRetry = ? WHERE state = 'retry' AND lastError IN ('temperature', 'battery')",
                                         arguments: [Date()]) }
    }
}

extension IndexDatabase {
    public func hasHigherPriorityJob(than priority: Int) throws -> Bool {
        try dbPool.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM jobs WHERE state IN ('queued','retry') AND nextRetry <= ? AND priority < ?)", arguments: [Date(), priority]) ?? false
        }
    }
}

extension IndexDatabase {
    public func isJobRunning(id: String) throws -> Bool {
        try dbPool.read { try String.fetchOne($0, sql: "SELECT state FROM jobs WHERE id = ?", arguments: [id]) == "running" }
    }
}
