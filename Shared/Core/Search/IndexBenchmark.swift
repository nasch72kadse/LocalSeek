import Foundation
import GRDB

public struct BenchmarkReport: Codable, Sendable {
    public let files: Int
    public let vectors: Int
    public let dimensions: Int
    public let setupSeconds: Double
    public let metadataScanSeconds: Double
    public let unchangedRescanSeconds: Double
    public let targetedFileUpdateMilliseconds: Double
    public let vectorMedianMilliseconds: Double
    public let vectorP95Milliseconds: Double
    public let filenameP95Milliseconds: Double
    public let fullTextP95Milliseconds: Double
    public let databaseBytes: Int64
}

/// Explicit performance fixture, never a measure of semantic retrieval quality.
public enum IndexBenchmark {
    public static func hybridP95(at root: URL, provider: any EmbeddingProvider) async throws -> Double {
        let db = try IndexDatabase(url: root.appendingPathComponent("benchmark.sqlite"))
        defer { try? db.dbPool.close() }
        let engine = HybridSearchEngine(db: db, provider: provider, store: BruteForceVectorStore(db: db), modelId: "benchmark")
        var times: [Double] = []
        for i in 0..<22 {
            let start = Date()
            let hits = try await engine.search(i % 2 == 0 ? "Wann muss ich die Rechnung bezahlen?" : "Wie sichere ich meine Daten?", strategy: .hybrid)
            guard !hits.isEmpty else { throw EmbeddingError.inferenceFailed }
            if i >= 2 { times.append(Date().timeIntervalSince(start) * 1000) }
        }
        return times.sorted()[Int(ceil(Double(times.count) * 0.95)) - 1]
    }

    public static func run(at root: URL, fileCount: Int = 10_000, vectorsPerFile: Int = 10) throws -> BenchmarkReport {
        let db = try IndexDatabase(url: root.appendingPathComponent("benchmark.sqlite"))
        defer { try? db.dbPool.close() }
        let sourceURL = root.appendingPathComponent("benchmark-documents")
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        for i in 0..<fileCount {
            try Data("Synthetic performance fixture \(i)".utf8).write(to: sourceURL.appendingPathComponent("report-\(i).txt"))
        }
        let source = SourceRecord(id: "benchmark", path: sourceURL.path)
        try db.upsertSource(source)
        let scanStart = Date()
        try DirectoryScanner().scan(source: source, into: db)
        let scanSeconds = Date().timeIntervalSince(scanStart)
        guard try db.fileCount() == fileCount else { throw IndexIntegrityError.corruptDatabase }
        let rescanStart = Date()
        try DirectoryScanner().scan(source: source, into: db)
        let rescanSeconds = Date().timeIntervalSince(rescanStart)
        let changedURL = sourceURL.appendingPathComponent("report-0.txt")
        try Data("Changed synthetic performance fixture".utf8).write(to: changedURL)
        let updateStart = Date()
        try DirectoryScanner().scanChanges(source: source, relativePaths: ["report-0.txt"], into: db)
        let updateMilliseconds = Date().timeIntervalSince(updateStart) * 1000
        try db.upsertModel(ModelRecord(modelId: "benchmark", name: "synthetic", dimensions: 384, checksum: "fixture", active: true))
        let start = Date()
        try db.dbPool.write { conn in
            let chunk = try conn.makeStatement(sql: "INSERT INTO chunks(id,fileId,ordinal,text,locationType,locationValue,textHash,tokenCount) VALUES (?,?,?,'performance fixture','none','','fixture',2)")
            let fulltext = try conn.makeStatement(sql: "INSERT INTO chunk_fts(rowid,text,filename,path) VALUES (?,'performance fixture',?,?)")
            let vector = try conn.makeStatement(sql: "INSERT INTO chunk_vectors_v1(chunkId,modelId,textHash,embedding,norm) VALUES (?,'benchmark','fixture',?,?)")
            var embeddings: [Data] = []
            for i in 0..<384 {
                var values = [Float](repeating: 0, count: 384); values[i] = 1; values[(i + 1) % 384] = 0.5
                embeddings.append(VectorBlob.data(from: values))
            }
            for i in 0..<fileCount {
                try Task.checkCancellation()
                let record = try Row.fetchOne(conn, sql: "SELECT filename, relativePath FROM files WHERE id = ?", arguments: [i + 1])!
                let name: String = record["filename"], path: String = record["relativePath"]
                for j in 0..<vectorsPerFile {
                    let id = i * vectorsPerFile + j + 1
                    try chunk.execute(arguments: [id, i + 1, j])
                    try fulltext.execute(arguments: [id, name, path])
                    try vector.execute(arguments: [id, embeddings[id % 384], sqrt(1.25)])
                }
            }
        }
        _ = try db.checkIntegrity(repair: false)
        try db.checkpoint()
        let setup = Date().timeIntervalSince(start)
        let store = BruteForceVectorStore(db: db)
        var vectorTimes: [Double] = [], nameTimes: [Double] = [], textTimes: [Double] = []
        for iteration in 0..<22 {
            var query = [Float](repeating: 0, count: 384); query[iteration] = 1
            var began = Date(); let hits = try store.nearest(to: query, modelId: "benchmark", limit: 50)
            guard hits.count == 50 else { throw IndexIntegrityError.corruptDatabase }
            if iteration >= 2 { vectorTimes.append(Date().timeIntervalSince(began) * 1000) }
            began = Date(); _ = try db.searchFilenames("report-\(iteration + 100)")
            if iteration >= 2 { nameTimes.append(Date().timeIntervalSince(began) * 1000) }
            began = Date(); _ = try db.searchChunks("performance", limit: 50)
            if iteration >= 2 { textTimes.append(Date().timeIntervalSince(began) * 1000) }
        }
        func percentile(_ values: [Double], _ fraction: Double) -> Double { let sorted = values.sorted(); return sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1)] }
        let size = (try FileManager.default.attributesOfItem(atPath: db.storageURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        return BenchmarkReport(files: fileCount, vectors: fileCount * vectorsPerFile, dimensions: 384,
            setupSeconds: setup, metadataScanSeconds: scanSeconds, unchangedRescanSeconds: rescanSeconds,
            targetedFileUpdateMilliseconds: updateMilliseconds, vectorMedianMilliseconds: percentile(vectorTimes, 0.5), vectorP95Milliseconds: percentile(vectorTimes, 0.95), filenameP95Milliseconds: percentile(nameTimes, 0.95), fullTextP95Milliseconds: percentile(textTimes, 0.95), databaseBytes: size)
    }
}
