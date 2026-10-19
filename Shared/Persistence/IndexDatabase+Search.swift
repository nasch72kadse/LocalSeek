import Foundation
import GRDB

extension IndexDatabase {
    static func fileConstraints(_ parsed: ParsedQuery, filters: SearchFilters) -> (sql: String, args: [any DatabaseValueConvertible]) {
        var conditions = ["files.state != 'deleted'", "EXISTS (SELECT 1 FROM sources WHERE sources.id = files.sourceId AND sources.enabled = 1)"]
        var args: [any DatabaseValueConvertible] = []
        for extensions in [parsed.extensions, filters.extensions] where !extensions.isEmpty {
            let values = extensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.sorted()
            conditions.append("files.fileExtension IN (\(values.map { _ in "?" }.joined(separator: ",")))")
            args.append(contentsOf: values)
        }
        if let source = filters.sourceId { conditions.append("files.sourceId = ?"); args.append(source) }
        for source in parsed.sourceContains {
            conditions.append("files.sourceId LIKE ? ESCAPE '\\'"); args.append("%" + escapeLike(source) + "%")
        }
        for path in parsed.pathContains + (filters.pathContains.isEmpty ? [] : [filters.pathContains]) {
            conditions.append("files.relativePath LIKE ? ESCAPE '\\'"); args.append("%" + escapeLike(path) + "%")
        }
        for after in [parsed.after, filters.after].compactMap({ $0 }) { conditions.append("files.mtime >= ?"); args.append(after) }
        for before in [parsed.before, filters.before].compactMap({ $0 }) { conditions.append("files.mtime < ?"); args.append(before) }
        for minimum in [parsed.minimumBytes, filters.minimumBytes].compactMap({ $0 }) { conditions.append("files.size >= ?"); args.append(minimum) }
        for maximum in [parsed.maximumBytes, filters.maximumBytes].compactMap({ $0 }) { conditions.append("files.size <= ?"); args.append(maximum) }
        if parsed.favoritesOnly || filters.favoritesOnly {
            conditions.append("EXISTS (SELECT 1 FROM favorites WHERE favorites.fileId = files.id)")
        }
        return (conditions.joined(separator: " AND "), args)
    }

    static let cachedStateSQL = """
        CASE WHEN files.state != 'present' THEN files.state
             WHEN files.contentMtime IS NOT files.mtime OR files.contentSize IS NOT files.size
               OR files.contentIdentity IS NOT files.fileIdentity
               OR EXISTS (SELECT 1 FROM sources WHERE sources.id = files.sourceId AND sources.scanStatus = 'unavailable')
             THEN 'cached' ELSE 'present' END
        """
    static let favoriteSQL = "EXISTS (SELECT 1 FROM favorites WHERE favorites.fileId = files.id)"

    public func favoriteIDs() throws -> Set<Int64> {
        try dbPool.read { Set(try Int64.fetchAll($0, sql: "SELECT fileId FROM favorites")) }
    }
    public func toggleFavorite(fileId: Int64) throws {
        try dbPool.write { db in
            if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM favorites WHERE fileId = ?", arguments: [fileId]) == 0 {
                try db.execute(sql: "INSERT INTO favorites(fileId) VALUES (?)", arguments: [fileId])
            } else { try db.execute(sql: "DELETE FROM favorites WHERE fileId = ?", arguments: [fileId]) }
        }
    }

    /// Negative chunk IDs identify metadata-only hits. These keep non-extractable
    /// files and cloud placeholders discoverable in the unified search.
    public func filenameContentHits(_ query: String, filters: SearchFilters, limit: Int) throws -> [ContentSearchHit] {
        try searchFilenames(query, limit: limit, filters: filters).compactMap { file in
            guard let id = file.id else { return nil }
            return ContentSearchHit(chunkId: -id, fileId: id, sourceId: file.sourceId,
                relativePath: file.relativePath, filename: file.filename, ordinal: 0,
                locationType: "filename", locationValue: "", snippet: file.filename, bm25: -1,
                fileState: file.state)
        }
    }
}
