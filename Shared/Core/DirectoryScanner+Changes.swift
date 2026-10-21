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
    func includedInChanges(_ relativePath: String, under root: URL) throws -> Bool {
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

    /// Reconcile only the minimal affected subtrees, with a two-phase hand-off.
    @discardableResult
    public func scanChanges(source: SourceRecord, relativePaths: [String], into db: IndexDatabase,
                            checkpoint: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> Int {
        guard !relativePaths.isEmpty else { return 0 }
        let plan = try DirectoryScanPlan(scanner: self, source: source, relativePaths: relativePaths)
        var count = 0
        while true {
            let batch = try plan.advance(into: db, maxEntries: 1000, maxSeconds: .infinity, checkpoint: checkpoint)
            count += batch.files
            if batch.complete { return count }
        }
    }
}
