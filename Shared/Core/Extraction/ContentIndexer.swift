import Foundation

public enum IndexWorkload: String, Sendable { case metadata, extraction, ocr, embedding, maintenance }
public typealias IndexCheckpoint = @Sendable (IndexWorkload) async throws -> Void

public struct ContentBatchResult: Sendable {
    public var processed: Int = 0
    public var lastID: Int64 = 0
    public var batteryDeferred = false
}

public struct ContentIndexer: Sendable {
    private let registry: ExtractorRegistry
    private let context: ExtractionContext
    private let chunker: DocumentChunker
    private let access: CoordinatedFileAccess

    public init(registry: ExtractorRegistry = .standard, context: ExtractionContext = ExtractionContext(),
                chunker: DocumentChunker = DocumentChunker(), access: CoordinatedFileAccess = CoordinatedFileAccess()) {
        self.registry = registry; self.context = context; self.chunker = chunker; self.access = access
    }

    public func hasRemainingContent(sourceId: String, in db: IndexDatabase, afterId: Int64 = 0) throws -> Bool {
        !(try db.filesNeedingContentExtraction(sourceId: sourceId, extensions: registry.supportedExtensions,
                                              version: chunker.version, afterId: afterId, limit: 1)).isEmpty
    }

    @discardableResult
    public func indexContent(source: SourceRecord, into db: IndexDatabase,
                             checkpoint: IndexCheckpoint = { _ in try Task.checkCancellation() }) async throws -> Int {
        try await indexBatch(source: source, into: db, maxFiles: .max, maxSeconds: .infinity,
                             checkpoint: checkpoint).processed
    }

    public func indexBatch(source: SourceRecord, into db: IndexDatabase, afterId startingAfter: Int64 = 0,
                           maxFiles: Int = 8, maxSeconds: TimeInterval = 2,
                           checkpoint: IndexCheckpoint = { _ in try Task.checkCancellation() }) async throws -> ContentBatchResult {
        guard maxFiles > 0, maxSeconds > 0 else { throw ExtractionError.resourceLimit }
        let root = URL(fileURLWithPath: source.path, isDirectory: true)
        var result = ContentBatchResult(lastID: startingAfter)
        var afterId = startingAfter, attempted = 0
        let deadline = ProcessInfo.processInfo.systemUptime + maxSeconds
        let heavy: Set<String> = ["pdf", "png", "jpg", "jpeg", "tiff", "tif", "heic", "heif", "bmp", "gif"]
        while true {
            let files = try db.filesNeedingContentExtraction(sourceId: source.id,
                extensions: registry.supportedExtensions, version: chunker.version, afterId: afterId)
            if files.isEmpty { break }
            for file in files {
                guard let fileId = file.id else { continue }
                if attempted >= maxFiles || ProcessInfo.processInfo.systemUptime >= deadline { return result }
                afterId = fileId
                result.lastID = fileId
                attempted += 1
                do { try await checkpoint(heavy.contains(file.fileExtension) ? .ocr : .extraction) }
                catch let deferred as ResourceDeferred where deferred.reason == .battery {
                    result.batteryDeferred = true
                    continue // Other locally available plain-text files can still be indexed.
                }
                let url = root.appendingPathComponent(file.relativePath, isDirectory: false)
                do {
                    try context.checkpoint()
                    guard file.size <= Int64(context.maxBytes) else { throw ExtractionError.resourceLimit }
                    let cache = DatabaseOCRCache(db: db, fileId: fileId)
                    var fileContext = context
                    if fileContext.ocrCache == nil { fileContext.ocrCache = cache }
                    let pdf = registry.extractor(for: file.fileExtension) as? PDFExtractor
                    let progress = try pdf == nil ? nil : db.pdfProgress(file: file, version: chunker.version)
                    var pdfBatch: PDFPageBatch?
                    let extracted: ExtractedDocument? = try access.read(at: url) { coordinatedURL in
                        let actual = try LocalFileMetadataProvider().metadata(for: coordinatedURL)
                        guard actual.size == file.size,
                              file.fileIdentity == nil || file.fileIdentity == actual.identity else {
                            throw ExtractionError.changedDuringRead
                        }
                        if let expected = file.mtime {
                            guard abs(actual.modificationDate.timeIntervalSince(expected)) < 0.0011 else { throw ExtractionError.changedDuringRead }
                        }
                        if let pdf {
                            var pageContext = fileContext
                            pageContext.maxBytes -= progress?.bytes ?? 0
                            pdfBatch = try pdf.extractBatch(fileURL: coordinatedURL, startPage: progress?.nextPage ?? 0,
                                maxPages: maxSeconds.isFinite ? 16 : .max,
                                maxSeconds: max(0.001, deadline - ProcessInfo.processInfo.systemUptime), context: pageContext)
                            return nil
                        }
                        return try registry.extract(fileURL: coordinatedURL, context: fileContext)
                    }
                    var document = extracted
                    var usedKeys = context.ocrCache == nil ? cache.usedKeys : nil
                    if let pdfBatch {
                        try db.savePDFBatch(pdfBatch, file: file, version: chunker.version, previous: progress,
                            keys: usedKeys ?? [], maxBytes: context.maxBytes)
                        guard pdfBatch.nextPage == pdfBatch.totalPages else { return result }
                        document = try db.completedPDF(fileId: fileId)
                        usedKeys = context.ocrCache == nil ? (progress?.ocrKeys ?? []).union(usedKeys ?? []) : nil
                    }
                    if let document {
                        let chunks = try await chunker.chunks(from: document, fileId: fileId)
                        try Task.checkCancellation()
                        try db.storeContent(fileId: fileId, chunks: chunks,
                            mtime: file.mtime ?? Date(timeIntervalSince1970: 0), version: chunker.version,
                            usedOCRKeys: usedKeys)
                    }
                    result.processed += 1
                } catch is CancellationError { throw CancellationError() }
                catch let error as ResourceDeferred { throw error }
                catch FileAccessError.placeholder { try db.setFileState(id: fileId, state: "cloudOnly") }
                catch FileAccessError.unavailable { try db.setFileState(id: fileId, state: "unavailable") }
                catch {
                    // Keep the last successful content and retry with backoff.
                    let code: String
                    switch error {
                    case ExtractionError.ocrTimedOut: code = "ocrTimeout"
                    case ExtractionError.ocrFailed: code = "ocrFailed"
                    case ExtractionError.ocrUnavailable: code = "ocrUnavailable"
                    default: code = error is ExtractionError ? "extraction" : "read"
                    }
                    try db.recordExtractionFailure(fileId: fileId, code: code)
                }
            }
        }
        return result
    }
}
