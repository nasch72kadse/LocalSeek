import Foundation

struct DirectoryScanBatch: Sendable {
    let complete: Bool
    let files: Int
}

/// Owned by the serial scan coordinator. Enumerator state survives job slices;
/// a process restart safely starts a new generation without deleting partial data.
final class DirectoryScanPlan {
    private struct Scope {
        let path: String
        let url: URL
        let identity: String
        let enumerator: FileManager.DirectoryEnumerator
    }
    private final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var failed = false
        func record() { lock.withLock { failed = true } }
        var any: Bool { lock.withLock { failed } }
    }
    private let scanner: DirectoryScanner
    private let source: SourceRecord
    private let root: URL
    private let rootIdentity: String
    private let generation = UUID().uuidString
    private let failures: Failures
    private let scopes: [Scope]
    private let direct: [FileRecord]
    private let missing: [String]
    private var scopeIndex = 0
    private var directStored = false

    init(scanner: DirectoryScanner, source: SourceRecord, relativePaths: [String]) throws {
        self.scanner = scanner; self.source = source
        let root = URL(fileURLWithPath: source.path, isDirectory: true).standardizedFileURL
        self.root = root
        let setup = try withoutFileMaterialization { () -> (String, Failures, [Scope], [FileRecord], [String]) in
            guard relativePaths.allSatisfy(DirectoryScanner.validRelativePath) else { throw FileAccessError.notRegular }
            let info = try scanner.metadata.metadata(for: root)
            guard info.isDirectory, !info.isDataless, !info.isSymbolicLink else { throw DirectoryScanner.ScanError.notEnumerable }
            var directories: [String] = [], files: [FileRecord] = [], absent: [String] = []
            for path in Set(relativePaths).sorted() {
                try Task.checkCancellation()
                try scanner.validateAncestors(of: path, under: root)
                guard try path.isEmpty || scanner.includedInChanges(path, under: root) else { continue }
                let url = path.isEmpty ? root : root.appendingPathComponent(path)
                do {
                    let value = try scanner.metadata.metadata(for: url)
                    if value.isSymbolicLink { continue }
                    if value.isDirectory {
                        guard !value.isDataless else { throw FileAccessError.placeholder }
                        directories.append(path)
                    } else if value.isRegular {
                        files.append(Self.record(source: source, path: path, info: value))
                    }
                } catch {
                    guard !path.isEmpty, localPathIsMissing(url) else { throw error }
                    absent.append(path)
                }
            }
            // Keep disjoint subtrees rather than widening them to a common ancestor.
            var minimal: [String] = []
            for path in directories.sorted(by: { $0.count < $1.count }) {
                if !minimal.contains(where: { $0.isEmpty || path == $0 || path.hasPrefix($0 + "/") }) { minimal.append(path) }
            }
            let failures = Failures()
            let scopes = try minimal.map { path -> Scope in
                let url = path.isEmpty ? root : root.appendingPathComponent(path)
                let value = try scanner.metadata.metadata(for: url)
                guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in failures.record(); return true })
                else { throw DirectoryScanner.ScanError.notEnumerable }
                return Scope(path: path, url: url, identity: value.identity, enumerator: enumerator)
            }
            return (info.identity, failures, scopes, files, absent)
        }
        rootIdentity = setup.0; failures = setup.1; scopes = setup.2; direct = setup.3; missing = setup.4
    }

    private static func record(source: SourceRecord, path: String, info: LocalFileMetadata) -> FileRecord {
        let url = URL(fileURLWithPath: path)
        return FileRecord(sourceId: source.id, relativePath: path, filename: url.lastPathComponent,
            fileExtension: url.pathExtension.lowercased(), size: info.size, mtime: info.modificationDate,
            state: info.isDataless ? "cloudOnly" : "present", fileIdentity: info.identity)
    }

    func advance(into db: IndexDatabase, maxEntries: Int = 256, maxSeconds: TimeInterval = 1,
                 checkpoint: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> DirectoryScanBatch {
        try withoutFileMaterialization {
            try checkpoint()
            guard try scanner.metadata.metadata(for: root).identity == rootIdentity else { throw DirectoryScanner.ScanError.partialEnumeration }
            try db.setSourceScanStatus(id: source.id, status: "scanning", lastScan: source.lastScan)
            var batch: [FileRecord] = []
            var visited = 0
            let deadline = ProcessInfo.processInfo.systemUptime + maxSeconds
            if !directStored { try db.upsertFiles(direct, generation: generation); directStored = true }
            while scopeIndex < scopes.count {
                if visited >= max(1, maxEntries) || ProcessInfo.processInfo.systemUptime >= deadline { break }
                try checkpoint()
                let scope = scopes[scopeIndex]
                guard let url = scope.enumerator.nextObject() as? URL else { scopeIndex += 1; continue }
                visited += 1
                let info: LocalFileMetadata
                do { info = try scanner.metadata.metadata(for: url) }
                catch is CancellationError { throw CancellationError() }
                catch { failures.record(); continue }
                if info.isSymbolicLink { scope.enumerator.skipDescendants(); continue }
                if info.isDirectory && info.isDataless { scope.enumerator.skipDescendants(); failures.record(); continue }
                guard info.isRegular else { continue }
                let prefix = root.path == "/" ? 1 : root.path.count + 1
                let path = String(url.standardizedFileURL.path.dropFirst(prefix))
                batch.append(Self.record(source: source, path: path, info: info))
            }
            try checkpoint()
            if !batch.isEmpty { try db.upsertFiles(batch, generation: generation) }
            guard scopeIndex == scopes.count else { return .init(complete: false, files: batch.count) }
            // Upsert every scope before removing missing paths, preserving cross-scope renames.
            guard !failures.any, try scanner.metadata.metadata(for: root).identity == rootIdentity else {
                try db.setSourceScanStatus(id: source.id, status: "unavailable", lastScan: source.lastScan)
                throw DirectoryScanner.ScanError.partialEnumeration
            }
            for scope in scopes {
                try scanner.validateAncestors(of: scope.path, under: root)
                guard try scanner.metadata.metadata(for: scope.url).identity == scope.identity else { throw DirectoryScanner.ScanError.partialEnumeration }
            }
            for path in missing {
                try scanner.validateAncestors(of: path, under: root)
                guard localPathIsMissing(root.appendingPathComponent(path)) else { throw DirectoryScanner.ScanError.partialEnumeration }
            }
            for scope in scopes { try db.reconcileSource(id: source.id, completedGeneration: generation, relativePath: scope.path) }
            for path in missing { try db.removeMissingPath(sourceId: source.id, relativePath: path) }
            if scopes.isEmpty { try db.setSourceScanStatus(id: source.id, status: "idle", lastScan: source.lastScan) }
            return .init(complete: true, files: batch.count + direct.count)
        }
    }
}

actor IndexScanCoordinator {
    private var metadata: [String: DirectoryScanPlan] = [:]
    private var changes: [String: (plan: DirectoryScanPlan, events: [PendingFileEvent])] = [:]

    func metadataBatch(source: SourceRecord, job: IndexJob, db: IndexDatabase) throws -> Bool {
        if changes[source.id] != nil { return false }
        if job.cursor == 0 { metadata[source.id] = nil }
        do {
            let plan = try metadata[source.id] ?? DirectoryScanPlan(scanner: DirectoryScanner(), source: source, relativePaths: [""])
            metadata[source.id] = plan
            let result = try plan.advance(into: db)
            if result.complete { metadata[source.id] = nil }
            return result.complete
        } catch is CancellationError {
            metadata[source.id] = nil
            try? db.setSourceScanStatus(id: source.id, status: "idle", lastScan: source.lastScan)
            throw CancellationError()
        } catch DirectoryScanner.ScanError.partialEnumeration {
            metadata[source.id] = nil
            try? db.setSourceScanStatus(id: source.id, status: "unavailable", lastScan: source.lastScan)
            throw DirectoryScanner.ScanError.partialEnumeration
        } catch {
            metadata[source.id] = nil
            try? db.markSourceUnavailable(id: source.id)
            throw DirectoryScanner.ScanError.notEnumerable
        }
    }

    func changesBatch(source: SourceRecord, job: IndexJob, db: IndexDatabase) throws -> Bool {
        // Changes can otherwise invalidate a partially enumerated full generation.
        metadata[source.id] = nil
        do {
            if changes[source.id] == nil {
                let events = try db.pendingFileEvents(sourceId: source.id)
                guard !events.isEmpty else { return true }
                changes[source.id] = (try DirectoryScanPlan(scanner: DirectoryScanner(), source: source,
                    relativePaths: events.map(\.relativePath)), events)
            }
            guard let state = changes[source.id] else { return true }
            if try state.plan.advance(into: db).complete {
                try db.completeFileEvents(state.events, job: job)
                changes[source.id] = nil
                return true
            }
            return false
        } catch is CancellationError {
            changes[source.id] = nil
            try? db.setSourceScanStatus(id: source.id, status: "idle", lastScan: source.lastScan)
            throw CancellationError()
        } catch {
            changes[source.id] = nil
            try? db.setSourceScanStatus(id: source.id, status: "unavailable", lastScan: source.lastScan)
            throw error
        }
    }
}
