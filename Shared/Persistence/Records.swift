import Foundation
import GRDB

/// Eine indizierte Quelle (Wurzelordner). Entspricht Tabelle `sources`.
public struct SourceRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public var id: String
    public var path: String
    public var enabled: Bool
    public var scanStatus: String
    public var lastScan: Date?

    public static let databaseTableName = "sources"

    public init(id: String, path: String, enabled: Bool = true,
                scanStatus: String = "idle", lastScan: Date? = nil) {
        self.id = id
        self.path = path
        self.enabled = enabled
        self.scanStatus = scanStatus
        self.lastScan = lastScan
    }
}

/// Eine indizierte Datei (nur Metadaten in Phase 2). Entspricht Tabelle `files`.
/// `id` ist der autoincrement-rowid; dieselbe Spalte dient als FTS5-rowid.
public struct FileRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable, Equatable {
    public var id: Int64?
    public var sourceId: String
    public var relativePath: String
    public var filename: String
    public var fileExtension: String
    public var size: Int64
    public var mtime: Date?
    public var state: String
    /// `mtime`-Stand, zu dem der Inhalt zuletzt extrahiert wurde (`nil` = nie). Nur Phase 3.
    public var contentMtime: Date?
    public var contentSize: Int64?
    public var contentIdentity: String?
    public var contentVersion: String
    public var fileIdentity: String?

    public static let databaseTableName = "files"

    public init(id: Int64? = nil, sourceId: String, relativePath: String,
                filename: String, fileExtension: String, size: Int64,
                mtime: Date?, state: String = "present", contentMtime: Date? = nil,
                contentVersion: String = "", fileIdentity: String? = nil, contentSize: Int64? = nil,
                contentIdentity: String? = nil) {
        self.id = id
        self.sourceId = sourceId
        self.relativePath = relativePath
        self.filename = filename
        self.fileExtension = fileExtension
        self.size = size
        self.mtime = mtime
        self.state = state
        self.contentMtime = contentMtime
        self.contentSize = contentSize
        self.contentIdentity = contentIdentity
        self.contentVersion = contentVersion
        self.fileIdentity = fileIdentity
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Ein extrahierter Textabschnitt einer Datei (Phase 3). Entspricht Tabelle `chunks`.
/// `locationType`/`locationValue` lokalisieren die Fundstelle (z. B. page/„3",
/// slide/„5", sheet/„Tabelle1!A1:C10", section/„Einleitung"). Maßgebliche Quelle
/// des extrahierten Textes; FTS5 (`chunk_fts`) ist nur der rekonstruierbare Suchindex.
public struct ChunkRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Sendable, Equatable {
    public var id: Int64?
    public var fileId: Int64
    public var ordinal: Int
    public var text: String
    public var locationType: String
    public var locationValue: String
    public var textHash: String
    public var tokenCount: Int

    public static let databaseTableName = "chunks"

    public init(id: Int64? = nil, fileId: Int64, ordinal: Int, text: String,
                locationType: String = "none", locationValue: String = "",
                textHash: String = "", tokenCount: Int = 0) {
        self.id = id
        self.fileId = fileId
        self.ordinal = ordinal
        self.text = text
        self.locationType = locationType
        self.locationValue = locationValue
        self.textHash = textHash
        self.tokenCount = tokenCount
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Ein Volltext-Treffer der Chunk-Suche: Datei + Fundstelle + Snippet + BM25-Score.
/// `bm25` ist der SQLite-FTS5-Score (kleiner/negativer = relevanter).
public struct ContentSearchHit: Sendable, Equatable, Identifiable {
    public var chunkId: Int64
    public var fileId: Int64
    public var sourceId: String
    public var relativePath: String
    public var filename: String
    public var ordinal: Int
    public var locationType: String
    public var locationValue: String
    public var snippet: String
    public var bm25: Double
    public var fileState: String
    public var isFavorite: Bool

    public var id: Int64 { chunkId }

    public init(chunkId: Int64, fileId: Int64, sourceId: String, relativePath: String,
                filename: String, ordinal: Int, locationType: String, locationValue: String,
                snippet: String, bm25: Double, fileState: String = "present", isFavorite: Bool = false) {
        self.chunkId = chunkId
        self.fileId = fileId
        self.sourceId = sourceId
        self.relativePath = relativePath
        self.filename = filename
        self.ordinal = ordinal
        self.locationType = locationType
        self.locationValue = locationValue
        self.snippet = snippet
        self.bm25 = bm25
        self.fileState = fileState
        self.isFavorite = isFavorite
    }
}

/// Ein registriertes Embedding-Modell (Phase 4). Entspricht Tabelle `models`.
public struct ModelRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public var modelId: String
    public var name: String
    public var dimensions: Int
    public var checksum: String
    public var active: Bool

    public var id: String { modelId }
    public static let databaseTableName = "models"

    public init(modelId: String, name: String, dimensions: Int, checksum: String, active: Bool = false) {
        self.modelId = modelId
        self.name = name
        self.dimensions = dimensions
        self.checksum = checksum
        self.active = active
    }
}
