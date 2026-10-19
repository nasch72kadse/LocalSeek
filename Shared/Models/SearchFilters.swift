import Foundation

public struct SearchFilters: Sendable, Equatable {
    public var extensions: Set<String>
    public var sourceId: String?
    public var pathContains: String
    public var after: Date?
    public var before: Date?
    public var minimumBytes: Int64?
    public var maximumBytes: Int64?
    public var favoritesOnly: Bool

    public init(extensions: Set<String> = [], sourceId: String? = nil, pathContains: String = "",
                after: Date? = nil, before: Date? = nil, minimumBytes: Int64? = nil,
                maximumBytes: Int64? = nil, favoritesOnly: Bool = false) {
        self.extensions = extensions; self.sourceId = sourceId; self.pathContains = pathContains
        self.after = after; self.before = before; self.minimumBytes = minimumBytes
        self.maximumBytes = maximumBytes; self.favoritesOnly = favoritesOnly
    }
    public var isEmpty: Bool { self == SearchFilters() }
}
