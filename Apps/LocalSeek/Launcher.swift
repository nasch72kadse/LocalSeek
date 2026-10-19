import SwiftUI
import Foundation
import SharedCore
import Darwin
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

@main
enum Launcher {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        if args.contains("--self-test") || args.contains("--benchmark") {
            do {
                let report = try await SelfTest.run(benchmark: args.contains("--benchmark"))
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                if let flag = args.firstIndex(of: "--report"), args.indices.contains(flag + 1) {
                    try data.write(to: URL(fileURLWithPath: args[flag + 1]), options: .atomic)
                }
                print(String(decoding: data, as: UTF8.self)); exit(EXIT_SUCCESS)
            } catch { print("LocalSeek self-test failed: \(error)"); exit(EXIT_FAILURE) }
        } else { LocalSeekApp.main() }
    }
}

enum SelfTest {
    static func run(benchmark: Bool) async throws -> [String: Any] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("localseek-selftest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        guard let model = Bundle.main.url(forResource: "multilingual-e5-small-q8_0", withExtension: "gguf", subdirectory: "Models"),
              try ModelLocator.checksum(of: model) == "e011debc1208e31bf7b6aebee2d9fc8bd2ca11694a77ed66ac9d0c9d0a877c93" else { throw EmbeddingError.modelMissing }
        let provider = LlamaEmbeddingProvider(modelURL: model)
        let documents = [
            ("invoice.txt", "Invoices are payable within thirty days by bank transfer.", "Wann muss ich die Rechnung bezahlen?"),
            ("garden.txt", "Tomatoes need sunlight and regular watering in the vegetable garden.", "Wie pflege ich Tomaten im Garten?"),
            ("travel.txt", "The train journey to Paris takes four hours. Book a seat in advance.", "Wie lange dauert die Zugfahrt nach Paris?"),
            ("backup.txt", "Create encrypted daily backups and test restoring lost files.", "Wie sichere ich meine Daten gegen Verlust?"),
            ("meeting.txt", "The project meeting is scheduled for Tuesday at ten in the conference room.", "Wann findet die Projektbesprechung statt?"),
            ("security.txt", "Use multi-factor authentication and a password manager to protect accounts.", "Wie schütze ich meine Benutzerkonten?"),
            ("recipe.txt", "Bake the chocolate cake in the oven at 180 degrees for forty minutes.", "Wie backe ich den Schokoladenkuchen?"),
            ("lease.txt", "The rental contract requires three months notice before moving out.", "Welche Kündigungsfrist hat die Wohnung?"),
            ("weather.txt", "Heavy snow and freezing temperatures are forecast for the mountain region.", "Wie wird das Wetter in den Bergen?"),
            ("delivery.txt", "Your parcel is delivered tomorrow. Track the shipment using its number.", "Wann kommt mein Paket an?")]
        do {
            let db = try IndexDatabase(url: root.appendingPathComponent("index.sqlite"))
            defer { try? db.dbPool.close() }
            let sourceURL = root.appendingPathComponent("documents")
            try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
            for doc in documents { try Data(doc.1.utf8).write(to: sourceURL.appendingPathComponent(doc.0)) }
            let source = SourceRecord(id: sourceURL.path, path: sourceURL.path); try db.upsertSource(source)
            try DirectoryScanner().scan(source: source, into: db)
            let chunker = DocumentChunker(tokenizer: provider, version: "self-test")
            try await ContentIndexer(chunker: chunker).indexContent(source: source, into: db)
            try db.upsertModel(ModelRecord(modelId: "selftest", name: model.lastPathComponent, dimensions: 384, checksum: "verified", active: true))
            try await EmbeddingIndexer(provider: provider, store: BruteForceVectorStore(db: db)).indexEmbeddings(modelId: "selftest", into: db)
            let engine = HybridSearchEngine(db: db, provider: provider, store: BruteForceVectorStore(db: db), modelId: "selftest")
            var correct = 0, top3 = 0, times: [Double] = [], failedIndices: [Int] = []
            var referenceTop3: [[Int64]] = []
            for (number, doc) in documents.enumerated() {
                let began = Date(); let hits = try await engine.search(doc.2, strategy: .semantic)
                times.append(Date().timeIntervalSince(began) * 1000)
                referenceTop3.append(hits.prefix(3).map(\.chunkId))
                if hits.first?.filename == doc.0 { correct += 1 } else { failedIndices.append(number) }
                if hits.prefix(3).contains(where: { $0.filename == doc.0 }) { top3 += 1 }
            }
            if correct != documents.count { print("Synthetic quality: \(correct)/\(documents.count), failed fixture indices: \(failedIndices)") }
            guard top3 == documents.count, correct >= 9 else {
                print("Synthetic retrieval quality failed: top1=\(correct), top3=\(top3), total=\(documents.count)")
                throw EmbeddingError.inferenceFailed
            }
            guard try db.checkIntegrity(repair: false).removedInvalidVectors == 0 else {
                print("Self-test vector integrity check failed")
                throw EmbeddingError.inferenceFailed
            }
            var report: [String: Any] = ["passed": true, "offlineModel": true, "crossLingualTop1": correct, "crossLingualTop3": top3, "top1MissFixtureIndices": failedIndices, "qualityQueries": documents.count, "qualityCorpus": "synthetic English passages / German questions", "queryP95Milliseconds": times.sorted()[Int(ceil(Double(times.count) * 0.95)) - 1]]
            try verifyBundledOCR(at: root)
            report["isolatedOCR"] = true
            let graph = AdaptiveVectorIndex(database: db, minimumVectors: 1)
            guard try await graph.prepare(modelId: "selftest", dimensions: provider.dimensions) else {
                print("Self-test accelerated vector index was not prepared")
                throw EmbeddingError.inferenceFailed
            }
            let accelerated = HybridSearchEngine(db: db, provider: provider,
                store: AdaptiveVectorStore(db: db, index: graph), modelId: "selftest")
            // Acceleration must preserve the exact search's ranking on this small
            // corpus, including any retrieval misses already measured above.
            for (number, doc) in documents.enumerated() {
                let hits = try await accelerated.search(doc.2, strategy: .semantic)
                guard hits.prefix(3).map(\.chunkId) == referenceTop3[number] else {
                    print("Accelerated ranking differs from exact search for fixture \(number)")
                    throw EmbeddingError.inferenceFailed
                }
            }
            report["acceleratedVectorSearch"] = true
            report["acceleratedAgreementQueries"] = documents.count
            graph.release()
            if benchmark {
                let probe = await MainActor.run { MainThreadProbe() }
                let performance = try await Task.detached(priority: .utility) { try IndexBenchmark.run(at: root) }.value
                report["performance"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(performance))
                report["hybrid100kP95Milliseconds"] = try await IndexBenchmark.hybridP95(at: root, provider: provider)
                report["mainThreadMaxDelayMilliseconds"] = await MainActor.run { probe.stop() }
            }
            await provider.unload()
            return report
        } catch { await provider.unload(); throw error }
    }

    /// Exercise the shipped helper through the same lookup and IPC as indexing.
    private static func verifyBundledOCR(at root: URL) throws {
        guard let bitmap = CGContext(data: nil, width: 519, height: 196, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ExtractionError.unreadable }
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 519, height: 196))
        bitmap.textPosition = CGPoint(x: 20, y: 70)
        let text = NSAttributedString(string: "LocalSeek OCR", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 48, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        CTLineDraw(CTLineCreateWithAttributedString(text), bitmap)
        let url = root.appendingPathComponent("ocr-self-test.png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
            UTType.png.identifier as CFString, 1, nil), let image = bitmap.makeImage() else {
            throw ExtractionError.unreadable
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ExtractionError.unreadable }
        let document = try ImageOCRExtractor().extract(fileURL: url, context: .init())
        guard document.segments.contains(where: { $0.text.contains("LocalSeek") }) else {
            throw ExtractionError.ocrFailed
        }
    }
}

@MainActor
private final class MainThreadProbe {
    private var maxDelay = 0.0
    private var task: Task<Void, Never>?
    init() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                let began = Date()
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
                self?.maxDelay = max(self?.maxDelay ?? 0, max(0, Date().timeIntervalSince(began) * 1000 - 25))
            }
        }
    }
    func stop() -> Double { task?.cancel(); return maxDelay }
    deinit { task?.cancel() }
}
