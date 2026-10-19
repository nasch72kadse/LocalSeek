import Foundation
import SharedCore
import LlamaBridge

/// Swift-Eigentümer des nativen Kontexts. Die Inferenz bleibt im Provider-Actor;
/// auch beim Freigeben des Actors wird der C-Kontext zuverlässig zerstört.
private final class LlamaContext {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    deinit { ls_llama_free(pointer) }
}

/// Serialisiert den nicht thread-sicheren llama-Kontext (Swift 6 strict concurrency).
/// Lädt das Modell on demand, präfigiert e5 (query:/passage:), normiert im Shim.
/// Gibt den Kontext nach ~2 min Inaktivität frei (RAM); nächster `embed` lädt neu.
actor LlamaEmbeddingProvider: EmbeddingProvider, TextTokenizer {
    nonisolated let dimensions: Int = 384
    private let modelURL: URL
    private var ctx: LlamaContext?
    private var lastUse = Date()
    private var reaper: Task<Void, Never>?

    init(modelURL: URL) { self.modelURL = modelURL }

    private func ensureLoaded() throws {
        lastUse = Date()
        if ctx != nil { return }
        guard FileManager.default.isReadableFile(atPath: modelURL.path) else {
            throw EmbeddingError.modelMissing
        }
        guard let c = ls_llama_load(modelURL.path) else { throw EmbeddingError.modelLoadFailed }
        let n = Int(ls_llama_n_embd(c))
        guard n == dimensions else { ls_llama_free(c); throw EmbeddingError.dimensionMismatch(expected: dimensions, got: n) }
        ctx = LlamaContext(c)
        startReaper()
    }

    /// Prüft Ladefähigkeit und Dimension, bevor die App das Modell als aktiv meldet.
    func prepare() throws { try ensureLoaded() }

    func countTokens(in text: String) throws -> Int {
        try ensureLoaded()
        guard let ctx else { throw EmbeddingError.modelMissing }
        let count = ls_llama_token_count(ctx.pointer, "passage: " + text.replacingOccurrences(of: "\0", with: " "))
        guard count >= 0 else { throw EmbeddingError.inferenceFailed }
        return Int(count)
    }

    func maximumTokens() throws -> Int {
        try ensureLoaded()
        guard let ctx else { throw EmbeddingError.modelMissing }
        return Int(ls_llama_max_tokens(ctx.pointer))
    }

    func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]] {
        try ensureLoaded()
        guard let ctx else { throw EmbeddingError.modelMissing }
        let prefix = kind == .query ? "query: " : "passage: "
        defer { lastUse = Date() }
        var result: [[Float]] = []
        for start in stride(from: 0, to: texts.count, by: 4) {
            try Task.checkCancellation()
            let group = texts[start..<min(start + 4, texts.count)]
            let allocated = group.map { strdup(prefix + $0.replacingOccurrences(of: "\0", with: " ")) }
            defer { for pointer in allocated { free(pointer) } }
            guard allocated.allSatisfy({ $0 != nil }) else { throw EmbeddingError.inferenceFailed }
            let pointers = allocated.map { $0.map { UnsafePointer<CChar>($0) } }
            let capacity = dimensions * group.count
            var out = [Float](repeating: 0, count: capacity)
            let written = pointers.withUnsafeBufferPointer { input in
                out.withUnsafeMutableBufferPointer {
                    ls_llama_embed_batch(ctx.pointer, input.baseAddress, Int32(group.count),
                                         $0.baseAddress, Int32(capacity))
                }
            }
            guard written == Int32(capacity) else { throw EmbeddingError.inferenceFailed }
            for index in 0..<group.count {
                result.append(Array(out[(index * dimensions)..<((index + 1) * dimensions)]))
            }
            if start + 4 < texts.count { await Task.yield() }
        }
        return result
    }

    func unload() {
        reaper?.cancel(); reaper = nil
        freeCtx()
    }

    private func freeCtx() {
        ctx = nil
    }

    /// Prüft periodisch auf Inaktivität und gibt den Kontext nach 120 s frei.
    private func startReaper() {
        reaper?.cancel()
        reaper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                if await self.reapIfIdle() { return }
            }
        }
    }

    private func reapIfIdle() -> Bool {
        guard ctx != nil else { reaper = nil; return true }
        if Date().timeIntervalSince(lastUse) >= 120 {
            freeCtx()
            reaper = nil
            return true
        }
        return false
    }
}
