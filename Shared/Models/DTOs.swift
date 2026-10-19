import Foundation

/// Scan-/Verfügbarkeitszustand einer Quelle (Spec §3.2: `unavailable` statt löschen).
public enum SourceState: Int, Sendable, Equatable {
    case idle = 0
    case scanning = 1
    case unavailable = 2
    case error = 3
}

/// Status einer einzelnen indizierten Quelle.
public struct SourceStatusDTO: Sendable, Equatable, Identifiable {
    public let id: String
    public let displayPath: String
    public let state: SourceState
    public let fileCount: Int
    public let isEnabled: Bool
    public let lastScan: Date?

    public init(id: String, displayPath: String, state: SourceState, fileCount: Int, isEnabled: Bool = true, lastScan: Date? = nil) {
        self.id = id
        self.displayPath = displayPath
        self.state = state
        self.fileCount = fileCount
        self.isEnabled = isEnabled
        self.lastScan = lastScan
    }
}

/// Gesamtzustand des Index (Spec §7: Status mit Datei-/Chunk-/Embedding-Anzahl).
public struct IndexStatusDTO: Sendable, Equatable {
    public let fileCount: Int
    public let chunkCount: Int
    public let embeddingCount: Int
    public let sourceCount: Int
    public let isPaused: Bool

    public init(fileCount: Int, chunkCount: Int, embeddingCount: Int, sourceCount: Int, isPaused: Bool) {
        self.fileCount = fileCount
        self.chunkCount = chunkCount
        self.embeddingCount = embeddingCount
        self.sourceCount = sourceCount
        self.isPaused = isPaused
    }

    public static let empty = IndexStatusDTO(
        fileCount: 0, chunkCount: 0, embeddingCount: 0, sourceCount: 0, isPaused: false)
}
