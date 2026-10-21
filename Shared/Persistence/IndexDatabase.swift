import Foundation
import GRDB

/// Zentrale SQLite-Anbindung (GRDB). Hält einen `DatabasePool` (WAL, Foreign Keys),
/// führt Migrationen aus und kapselt die Phase-2-Operationen (Dateien upserten + suchen).
///
/// Thread-sicher: `DatabasePool` serialisiert Schreibzugriffe und erlaubt parallele Lesezugriffe.
public final class IndexDatabase: Sendable {

    public let dbPool: DatabasePool
    public let storageURL: URL
    private let vectorIndexHolder = VectorIndexHolder()
    public var vectorIndex: AdaptiveVectorIndex { vectorIndexHolder.get(database: self) }

    /// Öffnet (oder erstellt) die DB an `url` und migriert auf den aktuellen Stand.
    public init(url: URL) throws {
        storageURL = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)

        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
        }

        dbPool = try DatabasePool(path: url.path, configuration: config)
        try Self.migrator.migrate(dbPool)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + suffix) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path + suffix)
        }
    }

    /// Standard-Speicherort: `~/Library/Application Support/LocalSeek/index.sqlite`.
    public static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return base.appendingPathComponent("LocalSeek", isDirectory: true)
                   .appendingPathComponent("index.sqlite")
    }

    public convenience init() throws {
        try self.init(url: Self.defaultURL())
    }

    // MARK: - Migrationen

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-metadata") { db in
            try db.create(table: "sources") { t in
                t.primaryKey("id", .text)
                t.column("path", .text).notNull().unique()
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("scanStatus", .text).notNull().defaults(to: "idle")
                t.column("lastScan", .datetime)
            }

            try db.create(table: "files") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sourceId", .text).notNull()
                    .indexed()
                    .references("sources", onDelete: .cascade)
                t.column("relativePath", .text).notNull()
                t.column("filename", .text).notNull()
                t.column("fileExtension", .text).notNull().defaults(to: "")
                t.column("size", .integer).notNull().defaults(to: 0)
                t.column("mtime", .datetime)
                t.column("state", .text).notNull().defaults(to: "present")
                t.uniqueKey(["sourceId", "relativePath"])
            }

            // Substring-/„Everything"-Suche über Dateiname + Pfad via Trigram-FTS5,
            // automatisch synchron gehalten mit `files`.
            try db.create(virtualTable: "filename_fts", using: FTS5()) { t in
                t.synchronize(withTable: "files")
                // Trigram-Tokenizer (SQLite-FTS5-eingebaut): ermöglicht Substring-MATCH.
                // GRDB 7 bietet keinen fertigen `.trigram()`-Deskriptor → direkt konstruieren.
                t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"])
                t.column("filename")
                t.column("relativePath")
            }
        }

        migrator.registerMigration("v2-content") { db in
            // Maßgebliche Quelle des extrahierten Textes (unabhängig vom Suchindex).
            try db.create(table: "chunks") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("fileId", .integer).notNull()
                    .indexed()
                    .references("files", onDelete: .cascade)
                t.column("ordinal", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("locationType", .text).notNull().defaults(to: "none")
                t.column("locationValue", .text).notNull().defaults(to: "")
                t.column("textHash", .text).notNull().defaults(to: "")
                t.column("tokenCount", .integer).notNull().defaults(to: 0)
                t.uniqueKey(["fileId", "ordinal"])
            }

            // BM25-Volltextindex über Chunk-Text + denormalisierten Datei-/Pfadnamen.
            // Bewusst eigenständige FTS5-Tabelle (nicht `synchronize`): filename/path
            // stammen aus `files`, text aus `chunks` → manuell beim Chunk-Insert gefüllt.
            // unicode61 `remove_diacritics 2`: Umlaut-tolerante Suche (ü≈u) für DE-Inhalte.
            try db.create(virtualTable: "chunk_fts", using: FTS5()) { t in
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("text")
                t.column("filename")
                t.column("path")
            }

            // FTS-Zeile beim Löschen eines Chunks mitentfernen — greift auch bei
            // FK-Cascade-Löschung (Datei/Quelle entfernt) und bei replaceChunks.
            try db.execute(sql: """
                CREATE TRIGGER chunks_after_delete AFTER DELETE ON chunks BEGIN
                    DELETE FROM chunk_fts WHERE rowid = old.id;
                END
                """)
        }

        // Merkt je Datei das `mtime`, zu dem ihr Inhalt zuletzt extrahiert wurde.
        // Ein erneuter Scan extrahiert nur Dateien, deren `mtime` davon abweicht
        // (oder die noch nie extrahiert wurden) — vermeidet teure Re-Extraktion.
        migrator.registerMigration("v3-content-tracking") { db in
            try db.alter(table: "files") { t in
                t.add(column: "contentMtime", .datetime)
            }
        }

        // Additiv: Vektoren je Chunk (Float32-LE-BLOB) + Modell-Register. `_v1` kodiert
        // Dimension/Modellfamilie; eine neue Modelldimension bekäme eine neue Tabelle.
        migrator.registerMigration("v4-vectors") { db in
            try db.create(table: "chunk_vectors_v1") { t in
                t.primaryKey("chunkId", .integer)
                    .references("chunks", onDelete: .cascade)
                t.column("embedding", .blob).notNull()      // 384 × Float32 LE = 1536 Byte
                t.column("modelId", .text).notNull()
                t.column("textHash", .text).notNull()
            }
            try db.create(indexOn: "chunk_vectors_v1", columns: ["modelId"])

            try db.create(table: "models") { t in
                t.primaryKey("modelId", .text)
                t.column("name", .text).notNull().defaults(to: "")
                t.column("dimensions", .integer).notNull()
                t.column("checksum", .text).notNull().defaults(to: "")
                t.column("active", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v5-resilience") { db in
            try db.alter(table: "files") { t in
                t.add(column: "contentVersion", .text).notNull().defaults(to: "")
                t.add(column: "fileIdentity", .text)
                t.add(column: "scanGeneration", .text).notNull().defaults(to: "")
            }
            try db.create(indexOn: "files", columns: ["sourceId", "fileIdentity"])
            try db.alter(table: "chunk_vectors_v1") { t in
                t.add(column: "norm", .double).notNull().defaults(to: 0)
            }
            try db.create(table: "file_failures") { t in
                t.primaryKey("fileId", .integer).references("files", onDelete: .cascade)
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("errorCode", .text).notNull()
                t.column("nextRetry", .datetime).notNull()
            }
            try db.execute(sql: """
                CREATE TABLE embedding_failures (
                    chunkId INTEGER NOT NULL REFERENCES chunks(id) ON DELETE CASCADE,
                    modelId TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
                    nextRetry DATETIME NOT NULL, PRIMARY KEY(chunkId, modelId))
                """)
            try db.create(table: "jobs") { t in
                t.primaryKey("id", .text)
                t.column("sourceId", .text).references("sources", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("state", .text).notNull().defaults(to: "queued")
                t.column("priority", .integer).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("nextRetry", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("rerun", .boolean).notNull().defaults(to: false)
                t.column("lastError", .text).notNull().defaults(to: "")
            }
            try db.create(indexOn: "jobs", columns: ["state", "nextRetry", "priority"])
            try db.create(table: "settings") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
            try db.create(table: "favorites") { t in
                t.primaryKey("fileId", .integer).references("files", onDelete: .cascade)
            }
            let chunks = try ChunkRecord.fetchCursor(db)
            while let chunk = try chunks.next(), let id = chunk.id {
                try db.execute(sql: "UPDATE chunks SET textHash = ? WHERE id = ?",
                               arguments: [StableHash.hex(chunk.text), id])
            }
            let vectors = try Row.fetchCursor(db, sql: "SELECT chunkId, embedding FROM chunk_vectors_v1")
            while let row = try vectors.next() {
                let vector = VectorBlob.vector(from: row["embedding"])
                let norm = sqrt(vector.reduce(Double(0)) { $0 + Double($1) * Double($1) })
                let id: Int64 = row["chunkId"]
                try db.execute(sql: "UPDATE chunk_vectors_v1 SET norm = ? WHERE chunkId = ?",
                               arguments: [norm.isFinite ? norm : 0, id])
            }
            // FTS5 secure-delete is available with the supported system SQLite.
            try db.execute(sql: "INSERT INTO chunk_fts(chunk_fts, rank) VALUES('secure-delete', 1)")
            try db.execute(sql: "INSERT INTO filename_fts(filename_fts, rank) VALUES('secure-delete', 1)")
        }
        migrator.registerMigration("v6-incremental-indexing") { db in
            try db.alter(table: "files") { t in t.add(column: "contentSize", .integer) }
            try db.alter(table: "files") { t in t.add(column: "contentIdentity", .text) }
            try db.alter(table: "jobs") { t in t.add(column: "cursor", .integer).notNull().defaults(to: 0) }
            try db.execute(sql: "DROP TRIGGER IF EXISTS __filename_fts_au")
            // Establish a baseline for existing indexes without forcing a full re-extraction.
            try db.execute(sql: "UPDATE files SET contentSize = size, contentIdentity = fileIdentity WHERE contentMtime IS NOT NULL")
            try db.execute(sql: """
                CREATE TRIGGER __filename_fts_au AFTER UPDATE OF filename, relativePath ON files
                WHEN old.filename IS NOT new.filename OR old.relativePath IS NOT new.relativePath BEGIN
                    INSERT INTO filename_fts(filename_fts, rowid, filename, relativePath)
                        VALUES('delete', old.id, old.filename, old.relativePath);
                    INSERT INTO filename_fts(rowid, filename, relativePath)
                        VALUES(new.id, new.filename, new.relativePath);
                END;
                CREATE TABLE file_events(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    sourceId TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                    relativePath TEXT NOT NULL,
                    UNIQUE(sourceId, relativePath));
                CREATE TABLE ocr_cache(
                    fileId INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                    cacheKey TEXT NOT NULL, lines BLOB NOT NULL,
                    byteCount INTEGER NOT NULL, lastUsed DOUBLE NOT NULL,
                    PRIMARY KEY(fileId, cacheKey));
                CREATE INDEX ocr_cache_lru ON ocr_cache(lastUsed);
                CREATE TABLE ocr_cache_budget(id INTEGER PRIMARY KEY CHECK(id = 1), bytes INTEGER NOT NULL, entries INTEGER NOT NULL);
                INSERT INTO ocr_cache_budget VALUES(1, 0, 0);
                CREATE TRIGGER ocr_cache_insert AFTER INSERT ON ocr_cache BEGIN
                    UPDATE ocr_cache_budget SET bytes = bytes + new.byteCount, entries = entries + 1 WHERE id = 1;
                END;
                CREATE TRIGGER ocr_cache_update AFTER UPDATE OF byteCount ON ocr_cache BEGIN
                    UPDATE ocr_cache_budget SET bytes = bytes + new.byteCount - old.byteCount WHERE id = 1;
                END;
                CREATE TRIGGER ocr_cache_delete AFTER DELETE ON ocr_cache BEGIN
                    UPDATE ocr_cache_budget SET bytes = bytes - old.byteCount, entries = entries - 1 WHERE id = 1;
                END;
                """)
        }
        migrator.registerMigration("v7-vector-change-log") { db in
            try db.execute(sql: """
                CREATE TABLE vector_state(modelId TEXT PRIMARY KEY, revision INTEGER NOT NULL);
                CREATE TABLE vector_tracking(modelId TEXT PRIMARY KEY, revision INTEGER NOT NULL);
                CREATE TABLE vector_changes(modelId TEXT NOT NULL, sequence INTEGER NOT NULL,
                    chunkId INTEGER NOT NULL, PRIMARY KEY(modelId, sequence));
                """)
            let triggers = [
                ("insert", "INSERT", "", "new"),
                ("delete", "DELETE", "", "old"),
                ("update", "UPDATE", "", "new"),
                ("old_model", "UPDATE OF modelId", "WHEN old.modelId IS NOT new.modelId", "old"),
            ]
            for (name, operation, condition, row) in triggers {
                try db.execute(sql: """
                    CREATE TRIGGER vector_change_\(name) AFTER \(operation) ON chunk_vectors_v1 \(condition) BEGIN
                        INSERT INTO vector_state(modelId, revision) VALUES(\(row).modelId, 1)
                        ON CONFLICT(modelId) DO UPDATE SET revision = revision + 1;
                        INSERT INTO vector_changes(modelId, sequence, chunkId)
                        SELECT s.modelId, s.revision, \(row).chunkId FROM vector_state s
                        JOIN vector_tracking t ON t.modelId = s.modelId
                        WHERE s.modelId = \(row).modelId AND s.revision - t.revision <= 100000;
                    END;
                    """)
            }
        }
        migrator.registerMigration("v8-bounded-work-and-status") { db in
            try db.execute(sql: """
                CREATE TABLE pdf_progress (
                    fileId INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
                    mtime DATETIME, size INTEGER NOT NULL, identity TEXT, version TEXT NOT NULL,
                    nextPage INTEGER NOT NULL, totalPages INTEGER NOT NULL, bytes INTEGER NOT NULL,
                    title TEXT, ocrKeys TEXT NOT NULL DEFAULT '[]');
                CREATE TABLE pdf_pages (
                    fileId INTEGER NOT NULL REFERENCES pdf_progress(fileId) ON DELETE CASCADE,
                    page INTEGER NOT NULL, text TEXT NOT NULL, isOCR INTEGER NOT NULL,
                    PRIMARY KEY(fileId, page));
                CREATE TRIGGER favorites_revision_insert AFTER INSERT ON favorites BEGIN
                    INSERT INTO settings(key,value) VALUES('favoritesRevision', '1')
                    ON CONFLICT(key) DO UPDATE SET value = CAST(value AS INTEGER) + 1;
                END;
                CREATE TRIGGER favorites_revision_delete AFTER DELETE ON favorites BEGIN
                    INSERT INTO settings(key,value) VALUES('favoritesRevision', '1')
                    ON CONFLICT(key) DO UPDATE SET value = CAST(value AS INTEGER) + 1;
                END;
                """)
        }
        return migrator
    }

    // MARK: - Schreiben

    /// Fügt eine Quelle ein oder aktualisiert sie (nach `id`).
    public func upsertSource(_ source: SourceRecord) throws {
        try dbPool.write { db in try source.save(db) }
    }

    public func setSourceScanStatus(id: String, status: String, lastScan: Date?) throws {
        try dbPool.write { db in
            try db.execute(sql: """
                UPDATE sources SET scanStatus = ?, lastScan = ? WHERE id = ?
                """, arguments: [status, lastScan, id])
        }
    }

    /// Fügt eine Datei ein oder aktualisiert sie (nach `sourceId` + `relativePath`).
    public func upsertFile(_ file: FileRecord) throws {
        try dbPool.write { db in try Self.upsert(file, into: db) }
    }

    /// Batch-Upsert in einer einzigen Transaktion (für den Initialscan).
    public func upsertFiles(_ files: [FileRecord], generation: String? = nil) throws {
        try dbPool.write { db in
            for file in files {
                try Self.upsert(file, into: db)
                if let generation {
                    try db.execute(sql: "UPDATE files SET scanGeneration = ? WHERE sourceId = ? AND relativePath = ?",
                                   arguments: [generation, file.sourceId, file.relativePath])
                }
            }
        }
    }

    private static func upsert(_ file: FileRecord, into db: Database) throws {
        let previous = try FileRecord.fetchOne(db, sql: "SELECT * FROM files WHERE sourceId = ? AND relativePath = ?",
                                              arguments: [file.sourceId, file.relativePath])
        if let previous, previous.filename == file.filename, previous.fileExtension == file.fileExtension,
           previous.size == file.size, previous.mtime?.databaseValue == file.mtime?.databaseValue, previous.state == file.state,
           file.fileIdentity == nil || previous.fileIdentity == file.fileIdentity {
            return
        }
        try db.execute(sql: """
            DELETE FROM file_failures WHERE fileId IN (
                SELECT id FROM files WHERE sourceId = ? AND relativePath = ?
                  AND (mtime IS NOT ? OR size != ? OR (? IS NOT NULL AND fileIdentity IS NOT ?)))
            """, arguments: [file.sourceId, file.relativePath, file.mtime, file.size, file.fileIdentity, file.fileIdentity])
        // Preserve the file/chunk IDs on an actual rename; distinct hard links remain distinct files.
        if let identity = file.fileIdentity,
           try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files WHERE sourceId = ? AND relativePath = ?",
                            arguments: [file.sourceId, file.relativePath]) == 0,
           let old = try FileRecord.fetchOne(db, sql: "SELECT * FROM files WHERE sourceId = ? AND fileIdentity = ? LIMIT 1",
                                            arguments: [file.sourceId, identity]),
           let oldId = old.id,
           let rootPath = try String.fetchOne(db, sql: "SELECT path FROM sources WHERE id = ?", arguments: [file.sourceId]),
           localPathIsMissing(URL(fileURLWithPath: rootPath, isDirectory: true)
                .appendingPathComponent(old.relativePath, isDirectory: false)) {
            try db.execute(sql: "UPDATE files SET relativePath = ? WHERE id = ?", arguments: [file.relativePath, oldId])
        }
        try db.execute(sql: """
            INSERT INTO files
                (sourceId, relativePath, filename, fileExtension, size, mtime, state, fileIdentity)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(sourceId, relativePath) DO UPDATE SET
                filename = excluded.filename,
                fileExtension = excluded.fileExtension,
                size = excluded.size,
                mtime = excluded.mtime,
                state = excluded.state,
                fileIdentity = COALESCE(excluded.fileIdentity, files.fileIdentity)
            """, arguments: [file.sourceId, file.relativePath, file.filename,
                             file.fileExtension, file.size, file.mtime, file.state, file.fileIdentity])
        if previous == nil || previous?.filename != file.filename {
            try db.execute(sql: """
                UPDATE chunk_fts SET filename = ?, path = ?
                WHERE rowid IN (SELECT chunks.id FROM chunks JOIN files ON files.id = chunks.fileId
                               WHERE files.sourceId = ? AND files.relativePath = ?)
                  AND (filename != ? OR path != ?)
                """, arguments: [file.filename, file.relativePath, file.sourceId, file.relativePath, file.filename, file.relativePath])
        }
    }

    /// Entfernt eine Quelle samt zugehöriger Dateien (FK-Cascade) und FTS-Einträge.
    public func removeSource(id: String) throws {
        try dbPool.write { db in _ = try SourceRecord.deleteOne(db, key: id) }
    }

    /// Löscht alle Dateien einer Quelle, deren relativer Pfad beim letzten Scan NICHT
    /// mehr gesehen wurde (gelöscht/umbenannt). FTS wird per Trigger synchron gehalten.
    public func reconcileSource(id: String, seenRelativePaths: Set<String>) throws {
        try dbPool.write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS temp._seen")
            try db.execute(sql: "CREATE TEMP TABLE _seen(path TEXT PRIMARY KEY)")
            for path in seenRelativePaths {
                try db.execute(sql: "INSERT OR IGNORE INTO _seen(path) VALUES (?)",
                               arguments: [path])
            }
            try db.execute(sql: """
                DELETE FROM files
                WHERE sourceId = ? AND relativePath NOT IN (SELECT path FROM _seen)
                """, arguments: [id])
            try db.execute(sql: "DROP TABLE temp._seen")
        }
    }

    public func reconcileSource(id: String, completedGeneration: String, relativePath: String = "") throws {
        try dbPool.write { db in
            if relativePath.isEmpty {
                try db.execute(sql: "DELETE FROM files WHERE sourceId = ? AND scanGeneration != ?",
                               arguments: [id, completedGeneration])
            } else {
                try db.execute(sql: """
                    DELETE FROM files WHERE sourceId = ? AND scanGeneration != ?
                    AND (relativePath = ? OR relativePath LIKE ? ESCAPE '\\')
                    """, arguments: [id, completedGeneration, relativePath, Self.escapeLike(relativePath) + "/%"])
            }
            try db.execute(sql: "UPDATE sources SET scanStatus = 'idle', lastScan = ? WHERE id = ?",
                           arguments: [Date(), id])
        }
    }

    /// Ersetzt alle Chunks einer Datei durch `chunks` (vollständige Neu-Extraktion).
    /// Alte Chunks werden gelöscht (Trigger entfernt deren FTS-Zeilen); die neuen
    /// Chunks werden eingefügt und ihr Text zusammen mit dem denormalisierten
    /// Datei-/Pfadnamen in `chunk_fts` indiziert. `ordinal` folgt der Reihenfolge.
    public func replaceChunks(fileId: Int64, chunks: [ChunkRecord]) throws {
        try dbPool.write { db in
            try Self.writeChunks(fileId: fileId, chunks: chunks, in: db)
        }
    }

    /// Stempelt den `mtime`-Stand, zu dem der Inhalt einer Datei extrahiert wurde,
    /// damit unveränderte Dateien bei künftigen Scans nicht erneut extrahiert werden.
    public func markContentIndexed(fileId: Int64, mtime: Date) throws {
        try dbPool.write { db in
            try db.execute(sql: "UPDATE files SET contentMtime = ?, contentVersion = ?, contentSize = size, contentIdentity = fileIdentity WHERE id = ?",
                           arguments: [mtime, DocumentChunker.defaultVersion, fileId])
        }
    }

    // MARK: - Lesen

    public func fileCount() throws -> Int {
        try dbPool.read { db in
            try FileRecord.filter(sql: "state != 'deleted'").fetchCount(db)
        }
    }

    public func sourceCount() throws -> Int {
        try dbPool.read { db in try SourceRecord.fetchCount(db) }
    }

    public func allSources() throws -> [SourceRecord] {
        try dbPool.read { db in try SourceRecord.order(Column("path")).fetchAll(db) }
    }

    /// Dateianzahl je Quelle (nur nicht gelöschte).
    public func fileCount(forSource id: String) throws -> Int {
        try dbPool.read { db in
            try FileRecord
                .filter(sql: "sourceId = ? AND state != 'deleted'", arguments: [id])
                .fetchCount(db)
        }
    }

    public func chunkCount() throws -> Int {
        try dbPool.read { db in try ChunkRecord.fetchCount(db) }
    }

    /// Liefert vorhandene, extrahierbare Dateien einer Quelle, deren Inhalt noch
    /// nie oder zu einem älteren `mtime` extrahiert wurde (neu/geändert).
    /// `extensions` begrenzt auf die vom Registry unterstützten Endungen (lowercase).
    public func filesNeedingContentExtraction(sourceId: String,
                                              extensions: Set<String>, version: String = DocumentChunker.defaultVersion,
                                              afterId: Int64 = 0, limit: Int = 256) throws -> [FileRecord] {
        guard !extensions.isEmpty else { return [] }
        let placeholders = extensions.map { _ in "?" }.joined(separator: ", ")
        let args: [DatabaseValueConvertible] = [sourceId] + extensions.map { $0 } + [version, afterId, Date(), limit]
        return try dbPool.read { db in
            try FileRecord.fetchAll(db, sql: """
                SELECT * FROM files
                WHERE sourceId = ? AND state = 'present'
                  AND fileExtension IN (\(placeholders))
                  AND (contentMtime IS NULL OR contentMtime != COALESCE(mtime, '1970-01-01 00:00:00.000')
                       OR contentSize IS NOT size OR contentIdentity IS NOT fileIdentity OR contentVersion != ?)
                  AND id > ?
                  AND NOT EXISTS (SELECT 1 FROM file_failures ff WHERE ff.fileId = files.id AND (ff.attempts >= 5 OR ff.nextRetry > ?))
                ORDER BY id
                LIMIT ?
                """, arguments: StatementArguments(args))
        }
    }

    /// Volltextsuche über Chunk-Inhalte (FTS5 BM25) mit typisierter Suchsyntax
    /// (`QueryParser`): Phrasen (`"…"`), freie Tokens (AND) sowie die Filter
    /// `ext:`/`type:`, `path:`, `after:`/`before:`. Nutzertext gelangt nie roh in
    /// SQL/FTS5 — der FTS5-Ausdruck wird aus `FTS5Pattern`-Teilen zusammengesetzt,
    /// Filter als gebundene Parameter übergeben. Liefert pro Treffer Datei,
    /// Fundstelle, markiertes Snippet und BM25-Score, sortiert nach Relevanz.
    public func searchChunks(_ rawQuery: String, limit: Int = 100, filters: SearchFilters = SearchFilters(), distinctDocuments: Bool = false) throws -> [ContentSearchHit] {
        let parsed = QueryParser.parse(rawQuery)
        guard parsed.hasTextMatch, let pattern = Self.ftsPattern(for: parsed) else { return [] }

        let constraints = Self.fileConstraints(parsed, filters: filters)
        let whereClause = "chunk_fts MATCH ? AND " + constraints.sql
        var args: [any DatabaseValueConvertible] = [pattern.rawPattern] + constraints.args
        args.append(max(0, limit))

        return try dbPool.read { db in
            let select = """
                SELECT chunks.id        AS chunkId,
                       files.id         AS fileId,
                       files.sourceId   AS sourceId,
                       files.relativePath AS relativePath,
                       files.filename   AS filename,
                       chunks.ordinal   AS ordinal,
                       chunks.locationType  AS locationType,
                       chunks.locationValue AS locationValue,
                       snippet(chunk_fts, 0, '[', ']', '…', 12) AS snippet,
                       bm25(chunk_fts, 1.0, 3.0, 0.5) AS bm25,
                       \(Self.cachedStateSQL) AS fileState, \(Self.favoriteSQL) AS isFavorite
                FROM chunk_fts
                JOIN chunks ON chunks.id = chunk_fts.rowid
                JOIN files  ON files.id  = chunks.fileId
                WHERE \(whereClause)
                ORDER BY bm25
                """
            let sql = distinctDocuments ? """
                WITH matches AS MATERIALIZED (\(select)),
                ranked AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY fileId ORDER BY bm25, chunkId) AS documentRank FROM matches)
                SELECT * FROM ranked WHERE documentRank = 1 ORDER BY bm25, chunkId LIMIT ?
                """ : select + " LIMIT ?"
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))

            return rows.map { row in
                ContentSearchHit(
                    chunkId: row["chunkId"], fileId: row["fileId"],
                    sourceId: row["sourceId"], relativePath: row["relativePath"],
                    filename: row["filename"], ordinal: row["ordinal"],
                    locationType: row["locationType"], locationValue: row["locationValue"],
                    snippet: row["snippet"], bm25: row["bm25"],
                    fileState: row["fileState"], isFavorite: row["isFavorite"])
            }
        }
    }

    /// Setzt einen FTS5-Ausdruck sicher aus sanitisierten Teilen zusammen: jede
    /// Phrase und jedes Token wird einzeln über einen `FTS5Pattern`-Initializer
    /// bereinigt, dann mit Leerzeichen (FTS5-implizites AND) verbunden.
    private static func ftsPattern(for query: ParsedQuery) -> FTS5Pattern? {
        var parts: [String] = []
        for phrase in query.phrases {
            if let p = try? FTS5Pattern(matchingPhrase: phrase) { parts.append(p.rawPattern) }
        }
        for term in query.terms {
            if let p = FTS5Pattern(matchingAllTokensIn: term) { parts.append(p.rawPattern) }
        }
        let combined = parts.filter { !$0.isEmpty }.joined(separator: " ")
        guard !combined.isEmpty else { return nil }
        return try? FTS5Pattern(rawPattern: combined)
    }

    /// Dateinamen-Suche. Ab 3 Zeichen über Trigram-FTS5 (Substring), sonst LIKE-Fallback.
    public func searchFilenames(_ rawQuery: String, limit: Int = 200, filters: SearchFilters = SearchFilters()) throws -> [FileRecord] {
        try dbPool.read { try Self.filenameRows(rawQuery, limit: limit, filters: filters, in: $0) }
    }

    public func searchFilenamesAsync(_ rawQuery: String, limit: Int = 200, filters: SearchFilters = SearchFilters()) async throws -> [FileRecord] {
        try await dbPool.read { try Self.filenameRows(rawQuery, limit: limit, filters: filters, in: $0) }
    }

    private static func filenameRows(_ rawQuery: String, limit: Int, filters: SearchFilters, in db: Database) throws -> [FileRecord] {
        let parsed = QueryParser.parse(rawQuery)
        let constraints = Self.fileConstraints(parsed, filters: filters)
        let terms = parsed.terms + parsed.phrases
        guard parsed.hasTextMatch || parsed.hasFilters || !filters.isEmpty else { return [] }
        var conditions = [constraints.sql]
        var args = constraints.args
        let longTerms = terms.filter { $0.count >= 3 }
        let join = longTerms.isEmpty ? "" : "JOIN filename_fts ON filename_fts.rowid = files.id"
        if !longTerms.isEmpty {
            let literal = longTerms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND ")
            let pattern = try FTS5Pattern(rawPattern: literal)
            conditions.append("filename_fts MATCH ?"); args.append(pattern.rawPattern)
        }
        for term in terms where term.count < 3 {
            conditions.append("files.relativePath LIKE ? ESCAPE '\\'")
            args.append("%" + Self.escapeLike(term) + "%")
        }
        args.append(parsed.searchText)
        args.append(max(0, limit))
        return try FileRecord.fetchAll(db, sql: """
                SELECT files.* FROM files \(join) WHERE \(conditions.joined(separator: " AND "))
                ORDER BY CASE WHEN lower(files.filename) = lower(?) THEN 0 ELSE 1 END,
                         length(files.filename), files.filename COLLATE NOCASE, files.id LIMIT ?
                """, arguments: StatementArguments(args))
    }

    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "%", with: "\\%")
         .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: - Phase 4: Vektoren

    /// Fügt/aktualisiert den Vektor eines Chunks für ein Modell (BLOB = Float32 LE).
    public func upsertEmbedding(chunkId: Int64, modelId: String,
                                textHash: String, vector: [Float]) throws {
        let blob = VectorBlob.data(from: vector)
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO chunk_vectors_v1 (chunkId, embedding, modelId, textHash, norm)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(chunkId) DO UPDATE SET
                    embedding = excluded.embedding,
                    modelId   = excluded.modelId,
                    textHash  = excluded.textHash,
                    norm      = excluded.norm
                """, arguments: [chunkId, blob, modelId, textHash,
                                  sqrt(vector.reduce(Double(0)) { $0 + Double($1) * Double($1) })])
            try db.execute(sql: "DELETE FROM embedding_failures WHERE chunkId = ? AND modelId = ?", arguments: [chunkId, modelId])
        }
    }

    public func removeEmbeddings(chunkIds: [Int64]) throws {
        guard !chunkIds.isEmpty else { return }
        let placeholders = chunkIds.map { _ in "?" }.joined(separator: ", ")
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM chunk_vectors_v1 WHERE chunkId IN (\(placeholders))",
                           arguments: StatementArguments(chunkIds))
        }
    }

    public func embeddingCount() throws -> Int {
        try dbPool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunk_vectors_v1") ?? 0 }
    }

    public func embeddingCount(modelId: String) throws -> Int {
        try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunk_vectors_v1 WHERE modelId = ?",
                             arguments: [modelId]) ?? 0
        }
    }

    /// Lädt alle (chunkId, Vektor) für ein Modell — Grundlage des Brute-Force-Sweeps.
    public func allEmbeddings(modelId: String) throws -> [(chunkId: Int64, vector: [Float])] {
        try dbPool.read { db in
            try Row.fetchAll(db, sql: "SELECT chunkId, embedding FROM chunk_vectors_v1 WHERE modelId = ?",
                             arguments: [modelId]).map { row in
                (chunkId: row["chunkId"], vector: VectorBlob.vector(from: row["embedding"]))
            }
        }
    }

    /// Chunks, die für `modelId` noch keinen oder einen veralteten Vektor haben
    /// (Hash-Vergleich in Swift: `StableHash.hex(text)` vs. gespeicherter `textHash`).
    public func chunksNeedingEmbedding(modelId: String, limit: Int = 256,
                                      afterId: Int64 = 0, sourceId: String? = nil) throws -> [ChunkRecord] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT chunks.*
                FROM chunks
                LEFT JOIN chunk_vectors_v1 cv ON cv.chunkId = chunks.id AND cv.modelId = ?
                JOIN files ON files.id = chunks.fileId
                WHERE chunks.id > ? AND (? IS NULL OR files.sourceId = ?)
                  AND files.state != 'deleted'
                  AND (cv.chunkId IS NULL OR cv.textHash != chunks.textHash)
                  AND NOT EXISTS (SELECT 1 FROM embedding_failures ef WHERE ef.chunkId = chunks.id
                                  AND ef.modelId = ? AND (ef.attempts >= 5 OR ef.nextRetry > ?))
                ORDER BY chunks.id
                LIMIT ?
                """, arguments: [modelId, afterId, sourceId, sourceId, modelId, Date(), limit])
            return try rows.map { try ChunkRecord(row: $0) }
        }
    }

    // MARK: - Phase 4: Modelle

    public func upsertModel(_ model: ModelRecord) throws {
        try dbPool.write { db in try model.save(db) }
    }

    public func setActiveModel(modelId: String) throws {
        try dbPool.write { db in
            try db.execute(sql: "UPDATE models SET active = 0")
            try db.execute(sql: "UPDATE models SET active = 1 WHERE modelId = ?", arguments: [modelId])
        }
    }

    public func activeModel() throws -> ModelRecord? {
        try dbPool.read { db in try ModelRecord.filter(sql: "active = 1").fetchOne(db) }
    }

    /// Baut `ContentSearchHit` für gegebene chunkIds (Reihenfolge der Eingabe erhalten).
    /// Snippet = Textpräfix (kein FTS-Match), `bm25 = 0`. Für Vektor-/Hybrid-Treffer.
    public func fetchChunkHits(chunkIds: [Int64]) throws -> [ContentSearchHit] {
        guard !chunkIds.isEmpty else { return [] }
        let placeholders = chunkIds.map { _ in "?" }.joined(separator: ", ")
        let byId: [Int64: ContentSearchHit] = try dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT chunks.id AS chunkId, files.id AS fileId, files.sourceId AS sourceId,
                       files.relativePath AS relativePath, files.filename AS filename,
                       chunks.ordinal AS ordinal, chunks.locationType AS locationType,
                       chunks.locationValue AS locationValue, chunks.text AS text,
                       \(Self.cachedStateSQL) AS fileState, \(Self.favoriteSQL) AS isFavorite
                FROM chunks JOIN files ON files.id = chunks.fileId
                WHERE chunks.id IN (\(placeholders)) AND files.state != 'deleted'
                """, arguments: StatementArguments(chunkIds))
            var map: [Int64: ContentSearchHit] = [:]
            for row in rows {
                let text: String = row["text"]
                let snippet = String(text.prefix(160))
                let id: Int64 = row["chunkId"]
                map[id] = ContentSearchHit(
                    chunkId: id, fileId: row["fileId"], sourceId: row["sourceId"],
                    relativePath: row["relativePath"], filename: row["filename"],
                    ordinal: row["ordinal"], locationType: row["locationType"],
                    locationValue: row["locationValue"], snippet: snippet, bm25: 0,
                    fileState: row["fileState"], isFavorite: row["isFavorite"])
            }
            return map
        }
        return chunkIds.compactMap { byId[$0] }
    }
}
