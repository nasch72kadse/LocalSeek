import Foundation
import GRDB

public enum IndexJobKind: String, Codable, Sendable {
    case metadata, changes, content, embeddings, vectorIndex, maintenance
    public var priority: Int {
        switch self {
        case .metadata, .changes: 0
        case .content: 10
        case .embeddings: 20
        case .vectorIndex: 80
        case .maintenance: 100
        }
    }
}

public struct IndexJobRequest: Sendable {
    public let sourceId: String?
    public let kind: IndexJobKind
    public let notBefore: Date
    public let priority: Int
    public let cursor: Int64
    public var id: String { "\(kind.rawValue):\(sourceId ?? "global")" }
    public init(sourceId: String? = nil, kind: IndexJobKind, notBefore: Date = Date(), priority: Int? = nil,
                cursor: Int64 = 0) {
        self.sourceId = sourceId; self.kind = kind; self.notBefore = notBefore
        self.priority = priority ?? kind.priority
        self.cursor = cursor
    }
}

public struct IndexJob: Codable, FetchableRecord, Sendable {
    public static let databaseTableName = "jobs"
    public var id: String
    public var sourceId: String?
    public var kind: IndexJobKind
    public var state: String
    public var priority: Int
    public var attempts: Int
    public var nextRetry: Date
    public var updatedAt: Date
    public var rerun: Bool
    public var lastError: String
    public var cursor: Int64 = 0
}

public struct JobCounts: Sendable, Equatable {
    public var pending: Int = 0
    public var running: Int = 0
    public var failed: Int = 0
    public var extractionFailures: Int = 0
    public var embeddingFailures: Int = 0
    public init() {}
}
