import Foundation

extension DirectoryScanner {
    public static func validRelativePath(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.contains("\0")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                $0 != ".." && $0 != "." && (!$0.isEmpty || path.isEmpty)
            }
    }

    func validateAncestors(of relativePath: String, under root: URL) throws {
        let rootInfo = try metadata.metadata(for: root)
        guard rootInfo.isDirectory, !rootInfo.isDataless, !rootInfo.isSymbolicLink else {
            throw FileAccessError.unavailable
        }
        var current = root
        for component in relativePath.split(separator: "/").dropLast() {
            current.appendPathComponent(String(component))
            do {
                let info = try metadata.metadata(for: current)
                guard info.isDirectory, !info.isSymbolicLink else { throw FileAccessError.notRegular }
                guard !info.isDataless else { throw FileAccessError.placeholder }
            } catch {
                if localPathIsMissing(current) { return }
                throw error
            }
        }
    }

    /// Match the full enumerator's hidden/package policy for narrow file events.
    private func includedInChanges(_ relativePath: String, under root: URL) throws -> Bool {
        var current = root
        for component in relativePath.split(separator: "/") {
            if component.hasPrefix(".") { return false }
            current.appendPathComponent(String(component))
            do {
                let info = try metadata.metadata(for: current)
                if info.isSymbolicLink { return false }
                if info.isDataless { return true } // No resource reads into cloud placeholders.
                let values = try current.resourceValues(forKeys: [.isHiddenKey, .isPackageKey])
                if values.isHidden == true || values.isPackage == true { return false }
            } catch {
                if localPathIsMissing(current) { return true }
                throw error
            }
        }
        return true
    }

    /// File events stay narrow. If directories occur, reconcile their common
    /// subtree once, preserving rename identities before deleting missing rows.
    @discardableResult
    public func scanChanges(source: SourceRecord, relativePaths: [String], into db: IndexDatabase,
                            checkpoint: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> Int {
        guard !relativePaths.isEmpty else { return 0 }
        guard relativePaths.allSatisfy(Self.validRelativePath) else { throw FileAccessError.notRegular }
        if relativePaths.contains("") { return try scan(source: source, into: db, checkpoint: checkpoint) }
        let root = URL(fileURLWithPath: source.path, isDirectory: true).standardizedFileURL
        return try withoutFileMaterialization {
            let initial = try metadata.metadata(for: root)
            try validateAncestors(of: "", under: root)
            var present: [(String, LocalFileMetadata)] = []
            var missing: [String] = []
            for path in Set(relativePaths).sorted() {
                try checkpoint()
                try validateAncestors(of: path, under: root)
                guard try includedInChanges(path, under: root) else { continue }
                let url = root.appendingPathComponent(path)
                do { present.append((path, try metadata.metadata(for: url))) }
                catch {
                    guard localPathIsMissing(url) else { throw error }
                    missing.append(path)
                }
            }
            if present.contains(where: { $0.1.isDirectory && !$0.1.isSymbolicLink && !$0.1.isDataless }) {
                let scopes = present.map { path, info in
                    info.isDirectory ? path.split(separator: "/").map(String.init)
                        : path.split(separator: "/").dropLast().map(String.init)
                } + missing.map { $0.split(separator: "/").dropLast().map(String.init) }
                var common = scopes.first ?? []
                for scope in scopes.dropFirst() {
                    common = Array(zip(common, scope).prefix(while: { $0.0 == $0.1 }).map { $0.0 })
                }
                return try scan(source: source, into: db, relativePath: common.joined(separator: "/"), checkpoint: checkpoint)
            }
            var count = 0
            for (path, info) in present {
                try checkpoint()
                if info.isSymbolicLink { continue }
                if info.isDirectory && info.isDataless { throw FileAccessError.placeholder }
                guard info.isRegular else { continue }
                let url = root.appendingPathComponent(path)
                try db.upsertFile(FileRecord(sourceId: source.id, relativePath: path,
                    filename: url.lastPathComponent, fileExtension: url.pathExtension.lowercased(),
                    size: info.size, mtime: info.modificationDate,
                    state: info.isDataless ? "cloudOnly" : "present", fileIdentity: info.identity))
                count += 1
            }
            try checkpoint()
            guard try metadata.metadata(for: root).identity == initial.identity else { throw ScanError.partialEnumeration }
            for path in missing {
                let url = root.appendingPathComponent(path)
                try validateAncestors(of: path, under: root)
                guard localPathIsMissing(url) else { throw ScanError.partialEnumeration }
                try db.removeMissingPath(sourceId: source.id, relativePath: path)
            }
            return count
        }
    }
}
