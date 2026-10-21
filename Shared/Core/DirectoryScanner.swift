import Foundation

public struct DirectoryScanner: Sendable {
    public enum ScanError: Error { case notEnumerable, partialEnumeration }
    let metadata: any FileMetadataProviding
    public init(metadata: any FileMetadataProviding = LocalFileMetadataProvider()) { self.metadata = metadata }

    @discardableResult
    public func scan(source: SourceRecord, into db: IndexDatabase, batchSize: Int = 1000,
                     relativePath: String = "",
                     checkpoint: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> Int {
        do {
            guard Self.validRelativePath(relativePath) else { throw FileAccessError.notRegular }
            try withoutFileMaterialization {
                let root = URL(fileURLWithPath: source.path, isDirectory: true).standardizedFileURL
                let url = relativePath.isEmpty ? root : root.appendingPathComponent(relativePath)
                let info = try metadata.metadata(for: url)
                guard info.isDirectory, !info.isDataless, !info.isSymbolicLink else { throw ScanError.notEnumerable }
            }
            let plan = try DirectoryScanPlan(scanner: self, source: source, relativePaths: [relativePath])
            var count = 0
            while true {
                let batch = try plan.advance(into: db, maxEntries: max(1, min(batchSize, 4096)), maxSeconds: .infinity, checkpoint: checkpoint)
                count += batch.files
                if batch.complete { return count }
            }
        } catch is CancellationError {
            try? db.setSourceScanStatus(id: source.id, status: "idle", lastScan: source.lastScan)
            throw CancellationError()
        } catch ScanError.partialEnumeration {
            try? db.setSourceScanStatus(id: source.id, status: "unavailable", lastScan: source.lastScan)
            throw ScanError.partialEnumeration
        }
        catch { try? db.markSourceUnavailable(id: source.id); throw ScanError.notEnumerable }
    }
}
