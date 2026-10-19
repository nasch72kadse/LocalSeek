import Foundation

/// Reconcile only a complete generation. Cancellation and partial availability
/// preserve previously indexed content. The traversal never materializes cloud files.
public struct DirectoryScanner: Sendable {
    public enum ScanError: Error { case notEnumerable, partialEnumeration }
    let metadata: any FileMetadataProviding
    public init(metadata: any FileMetadataProviding = LocalFileMetadataProvider()) { self.metadata = metadata }

    private final class EnumerationState: @unchecked Sendable {
        private let lock = NSLock()
        private var failed = false
        func recordFailure() { lock.lock(); failed = true; lock.unlock() }
        var isIncomplete: Bool { lock.lock(); defer { lock.unlock() }; return failed }
    }

    @discardableResult
    public func scan(source: SourceRecord, into db: IndexDatabase, batchSize: Int = 1000,
                     relativePath: String = "",
                     checkpoint: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> Int {
        let sourceRoot = URL(fileURLWithPath: source.path, isDirectory: true).standardizedFileURL
        guard Self.validRelativePath(relativePath) else { throw FileAccessError.notRegular }
        let root = relativePath.isEmpty ? sourceRoot : sourceRoot.appendingPathComponent(relativePath)
        do {
            return try withoutFileMaterialization {
                try validateAncestors(of: relativePath, under: sourceRoot)
                let rootInfo = try metadata.metadata(for: root)
                guard rootInfo.isDirectory, !rootInfo.isDataless, !rootInfo.isSymbolicLink else {
                    throw ScanError.notEnumerable
                }
                let state = EnumerationState()
                guard let enumerator = FileManager.default.enumerator(at: root,
                    includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { _, _ in state.recordFailure(); return true }) else { throw ScanError.notEnumerable }
                try db.setSourceScanStatus(id: source.id, status: "scanning", lastScan: source.lastScan)
                let generation = UUID().uuidString
                let capacity = max(1, min(batchSize, 4096))
                var batch: [FileRecord] = []
                batch.reserveCapacity(capacity)
                var total = 0
                for case let url as URL in enumerator {
                    try checkpoint()
                    let info: LocalFileMetadata
                    do { info = try metadata.metadata(for: url) }
                    catch is CancellationError { throw CancellationError() }
                    catch { state.recordFailure(); continue }
                    if info.isSymbolicLink { enumerator.skipDescendants(); continue }
                    if info.isDirectory && info.isDataless {
                        enumerator.skipDescendants(); state.recordFailure(); continue
                    }
                    guard info.isRegular else { continue }
                    let prefixLength = sourceRoot.path == "/" ? 1 : sourceRoot.path.count + 1
                    let relative = String(url.standardizedFileURL.path.dropFirst(prefixLength))
                    batch.append(FileRecord(sourceId: source.id, relativePath: relative,
                        filename: url.lastPathComponent, fileExtension: url.pathExtension.lowercased(),
                        size: info.size, mtime: info.modificationDate,
                        state: info.isDataless ? "cloudOnly" : "present", fileIdentity: info.identity))
                    if batch.count >= capacity {
                        // A database write failure must escape immediately, not grow an
                        // uncommitted batch for the remainder of a large source.
                        try db.upsertFiles(batch, generation: generation)
                        total += batch.count; batch.removeAll(keepingCapacity: true)
                    }
                }
                try checkpoint()
                if !batch.isEmpty { try db.upsertFiles(batch, generation: generation); total += batch.count }
                guard !state.isIncomplete,
                      (try metadata.metadata(for: root)).identity == rootInfo.identity else {
                    try db.setSourceScanStatus(id: source.id, status: "unavailable", lastScan: source.lastScan)
                    throw ScanError.partialEnumeration
                }
                try db.reconcileSource(id: source.id, completedGeneration: generation, relativePath: relativePath)
                return total
            }
        } catch is CancellationError {
            try? db.setSourceScanStatus(id: source.id, status: "idle", lastScan: source.lastScan)
            throw CancellationError()
        } catch ScanError.partialEnumeration {
            throw ScanError.partialEnumeration
        } catch {
            try? db.markSourceUnavailable(id: source.id)
            throw ScanError.notEnumerable
        }
    }
}
