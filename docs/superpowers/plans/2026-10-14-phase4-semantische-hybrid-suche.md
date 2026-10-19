# Phase 4 — Semantische Hybrid-Suche: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** LocalSeek um lokale semantische Suche (e5-small via llama.cpp) erweitern und per RRF mit der bestehenden FTS5/BM25-Suche zu einer hybriden Suche fusionieren.

**Architecture:** Additive DB-Migration `v4-vectors` (Vektoren als Float32-BLOB + Modell-Register). Alle Logik hinter schmalen Protokollen (`EmbeddingProvider`, `VectorStore`), isoliert gegen `SharedCore` testbar mit einem Fake-Provider — kein llama im Standard-Testlauf. llama.cpp wird als statisch gelinktes Native-Target (`LlamaBridge`) nur hinter dem `LlamaEmbeddingProvider`-Actor gekapselt. Bestehende Phase-1–3-Teile bleiben unangetastet; Phase 4 hängt sich nur an `IndexService`, `SearchView` und die Migration ein.

**Tech Stack:** Swift 6 (strict concurrency), GRDB 7 (SQLite), CryptoKit (SHA-256), Accelerate/vDSP (Cosinus), llama.cpp (gepinnter Release, Metal), multilingual-e5-small GGUF (384-dim).

---

## Grundsatzentscheidungen (gegenüber Design-Spec präzisiert)

Die Design-Spec (`docs/superpowers/specs/2026-10-13-phase4-semantische-hybrid-suche-design.md`) ist die Vorgabe. Beim Verankern am realen Code wurden drei Punkte präzisiert — **vor der Umsetzung bestätigen**:

1. **Stabiler Inhalts-Hash statt `chunks.textHash`.** Die Design-Spec sagt „inkrementell über `chunks.textHash`". Im Ist-Code setzt `ContentIndexer.chunks()` `textHash` **nicht** (bleibt `""`), und Swifts `hashValue` ist nicht lauf-stabil. **Entscheidung:** Phase 4 berechnet den Hash selbst via `StableHash.hex(text)` (SHA-256-Hex) und speichert ihn in `chunk_vectors_v1.textHash`. Phase-3-Code (`ContentIndexer`) bleibt dadurch unangetastet; Staleness-Erkennung ist self-contained.
2. **`VectorStore`-Protokoll trägt `modelId` + `textHash`.** Die Design-Spec-Signatur (`upsert(chunkId:embedding:)`) reicht nicht, weil die Tabelle `modelId`/`textHash` je Zeile braucht (Modellversionen koexistieren). Signatur wird erweitert: `upsert(chunkId:modelId:textHash:embedding:)`, `nearest(to:modelId:limit:)`. Ein späterer sqlite-vec-Adapter kann dieselbe Signatur erfüllen.
3. **llama.cpp-Baumechanik ist ein Spike (Task 2), kein geratener Build.** Die reale Embedding-API ist versionssensibel (z. B. `llama_process(…, DECODE)`, `llama_get_embeddings_seq`, `common_embd_normalize`, `llama_model_n_embd_out`). Task 2 pinnt einen Release-Tag und verifiziert Build/Link gegen die reale Quelle, bevor Code als „fertig" gilt.

---

## File Structure

**Neu (SharedCore):**
- `Shared/Core/StableHash.swift` — SHA-256-Hex-Helfer (CryptoKit). Eine Verantwortung: deterministischer Textschlüssel.
- `Shared/Core/Embedding/EmbeddingProvider.swift` — `EmbeddingKind`, `EmbeddingProvider`-Protokoll.
- `Shared/Core/Embedding/EmbeddingIndexer.swift` — orchestriert Chunk→Vektor, inkrementell.
- `Shared/Core/Search/VectorStore.swift` — `VectorStore`-Protokoll, `VectorMatch`, `VectorBlob` (Float32-LE-Codec), `BruteForceVectorStore` (vDSP-Cosinus über DB-BLOBs).
- `Shared/Core/Search/HybridSearchEngine.swift` — `SearchStrategy`, RRF-Fusion (pure Funktion) + dokumentgruppierte Suche.

**Neu (App + Native):**
- `LlamaBridge/include/localseek_llama.h` + `LlamaBridge/src/localseek_llama.cpp` — dünner C-Shim über llama.cpp (Task 2, Layout final im Spike).
- `Apps/LocalSeek/LlamaEmbeddingProvider.swift` — Actor, kapselt `LlamaBridge`, e5-Präfixe, On-demand-Laden.
- `Apps/LocalSeek/ModelLocator.swift` — findet/kopiert GGUF nach `~/Library/Application Support/LocalSeek/models/`, SHA-256-Prüfsumme.

**Modifiziert:**
- `Shared/Persistence/IndexDatabase.swift` — Migration `v4-vectors`; Embedding-/Modell-APIs.
- `Shared/Persistence/Records.swift` — `ModelRecord`.
- `Apps/LocalSeek/IndexService.swift` — `EmbeddingIndexer`-Verdrahtung, echter `embeddingCount`, `searchHybridAsync`.
- `Apps/LocalSeek/Views/SearchView.swift` — Content-Submodus Hybrid/Exakt/Semantisch + Modell-Status.
- `Apps/LocalSeek/Views/StatusView.swift` — `embeddingCount` + „Modell wählen…".
- `project.yml` — `LlamaBridge`-Target + Link in `SharedCore`/`LocalSeek`.

**Neue Tests:** `Tests/UnitTests/StableHashTests.swift`, `VectorStoreTests.swift`, `EmbeddingIndexerTests.swift`, `HybridSearchEngineTests.swift`, und `FakeEmbeddingProvider.swift` (Test-Helfer, deterministische Vektoren).

---

## Task 1: Schema `v4-vectors` + `StableHash` + `VectorStore`/`BruteForceVectorStore`

Reines Swift, kein llama. Liefert Persistenz + Vektorsuche, voll per TDD testbar.

**Files:**
- Create: `Shared/Core/StableHash.swift`
- Create: `Shared/Core/Search/VectorStore.swift`
- Modify: `Shared/Persistence/Records.swift` (append `ModelRecord`)
- Modify: `Shared/Persistence/IndexDatabase.swift` (Migration + APIs)
- Test: `Tests/UnitTests/StableHashTests.swift`, `Tests/UnitTests/VectorStoreTests.swift`

- [x] **Step 1.1: `StableHash` schreiben**

`Shared/Core/StableHash.swift`:
```swift
import Foundation
import CryptoKit

/// Deterministischer, lauf-stabiler Textschlüssel (SHA-256-Hex). Dient der
/// Staleness-Erkennung beim Embedding (im Gegensatz zu Swifts nicht-stabilem hashValue).
public enum StableHash {
    public static func hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
```

- [x] **Step 1.2: `StableHashTests` schreiben + lauffähig halten**

`Tests/UnitTests/StableHashTests.swift`:
```swift
import XCTest
@testable import SharedCore

final class StableHashTests: XCTestCase {
    func testDeterministicAndSensitive() {
        XCTAssertEqual(StableHash.hex("Risiko"), StableHash.hex("Risiko"))
        XCTAssertNotEqual(StableHash.hex("Risiko"), StableHash.hex("risiko"))
        XCTAssertEqual(StableHash.hex("Risiko").count, 64)
    }
}
```

- [x] **Step 1.3: `ModelRecord` an `Records.swift` anhängen**

Am Ende von `Shared/Persistence/Records.swift`:
```swift
/// Ein registriertes Embedding-Modell (Phase 4). Entspricht Tabelle `models`.
public struct ModelRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public var modelId: String
    public var name: String
    public var dimensions: Int
    public var checksum: String
    public var active: Bool

    public var id: String { modelId }
    public static let databaseTableName = "models"

    public init(modelId: String, name: String, dimensions: Int, checksum: String, active: Bool = false) {
        self.modelId = modelId
        self.name = name
        self.dimensions = dimensions
        self.checksum = checksum
        self.active = active
    }
}
```

- [x] **Step 1.4: Migration `v4-vectors` in `IndexDatabase.migrator` ergänzen**

In `Shared/Persistence/IndexDatabase.swift`, direkt vor `return migrator`:
```swift
// Additiv: Vektoren je Chunk (Float32-LE-BLOB) + Modell-Register. `_v1` kodiert
// Dimension/Modellfamilie; eine neue Modelldimension bekäme eine neue Tabelle.
migrator.registerMigration("v4-vectors") { db in
    try db.create(table: "chunk_vectors_v1") { t in
        t.primaryKey("chunkId", .integer)
            .references("chunks", onDelete: .cascade)
        t.column("embedding", .blob).notNull()      // 384 × Float32 LE = 1536 Byte
        t.column("modelId", .text).notNull()
        t.column("textHash", .text).notNull()
    }
    try db.create(indexOn: "chunk_vectors_v1", columns: ["modelId"])

    try db.create(table: "models") { t in
        t.primaryKey("modelId", .text)
        t.column("name", .text).notNull().defaults(to: "")
        t.column("dimensions", .integer).notNull()
        t.column("checksum", .text).notNull().defaults(to: "")
        t.column("active", .boolean).notNull().defaults(to: false)
    }
}
```

- [x] **Step 1.5: Embedding-/Modell-APIs an `IndexDatabase` anhängen**

Vor der schließenden `}` von `IndexDatabase`, nach `escapeLike`:
```swift
// MARK: - Phase 4: Vektoren

/// Fügt/aktualisiert den Vektor eines Chunks für ein Modell (BLOB = Float32 LE).
public func upsertEmbedding(chunkId: Int64, modelId: String,
                            textHash: String, vector: [Float]) throws {
    let blob = VectorBlob.data(from: vector)
    try dbPool.write { db in
        try db.execute(sql: """
            INSERT INTO chunk_vectors_v1 (chunkId, embedding, modelId, textHash)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(chunkId) DO UPDATE SET
                embedding = excluded.embedding,
                modelId   = excluded.modelId,
                textHash  = excluded.textHash
            """, arguments: [chunkId, blob, modelId, textHash])
    }
}

public func removeEmbeddings(chunkIds: [Int64]) throws {
    guard !chunkIds.isEmpty else { return }
    let placeholders = chunkIds.map { _ in "?" }.joined(separator: ", ")
    try dbPool.write { db in
        try db.execute(sql: "DELETE FROM chunk_vectors_v1 WHERE chunkId IN (\(placeholders))",
                       arguments: StatementArguments(chunkIds))
    }
}

public func embeddingCount() throws -> Int {
    try dbPool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunk_vectors_v1") ?? 0 }
}

public func embeddingCount(modelId: String) throws -> Int {
    try dbPool.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunk_vectors_v1 WHERE modelId = ?",
                         arguments: [modelId]) ?? 0
    }
}

/// Lädt alle (chunkId, Vektor) für ein Modell — Grundlage des Brute-Force-Sweeps.
public func allEmbeddings(modelId: String) throws -> [(chunkId: Int64, vector: [Float])] {
    try dbPool.read { db in
        try Row.fetchAll(db, sql: "SELECT chunkId, embedding FROM chunk_vectors_v1 WHERE modelId = ?",
                         arguments: [modelId]).map { row in
            (chunkId: row["chunkId"], vector: VectorBlob.vector(from: row["embedding"]))
        }
    }
}

/// Chunks, die für `modelId` noch keinen oder einen veralteten Vektor haben
/// (Hash-Vergleich in Swift: `StableHash.hex(text)` vs. gespeicherter `textHash`).
public func chunksNeedingEmbedding(modelId: String, limit: Int = 10_000) throws -> [ChunkRecord] {
    try dbPool.read { db in
        let rows = try Row.fetchAll(db, sql: """
            SELECT chunks.*, cv.textHash AS existingHash
            FROM chunks
            LEFT JOIN chunk_vectors_v1 cv ON cv.chunkId = chunks.id AND cv.modelId = ?
            ORDER BY chunks.id
            LIMIT ?
            """, arguments: [modelId, limit])
        return try rows.compactMap { row -> ChunkRecord? in
            let chunk = try ChunkRecord(row: row)
            let existing: String? = row["existingHash"]
            if existing == nil || existing != StableHash.hex(chunk.text) { return chunk }
            return nil
        }
    }
}

// MARK: - Phase 4: Modelle

public func upsertModel(_ model: ModelRecord) throws {
    try dbPool.write { db in try model.save(db) }
}

public func setActiveModel(modelId: String) throws {
    try dbPool.write { db in
        try db.execute(sql: "UPDATE models SET active = 0")
        try db.execute(sql: "UPDATE models SET active = 1 WHERE modelId = ?", arguments: [modelId])
    }
}

public func activeModel() throws -> ModelRecord? {
    try dbPool.read { db in try ModelRecord.filter(sql: "active = 1").fetchOne(db) }
}
```

- [x] **Step 1.6: `VectorStore.swift` schreiben (Protokoll + BLOB-Codec + BruteForce)**

`Shared/Core/Search/VectorStore.swift`:
```swift
import Foundation
import Accelerate

public struct VectorMatch: Sendable, Equatable {
    public let chunkId: Int64
    public let score: Double
    public init(chunkId: Int64, score: Double) { self.chunkId = chunkId; self.score = score }
}

/// Austauschbarer Vektorspeicher. BruteForce heute, sqlite-vec später an derselben Signatur.
public protocol VectorStore: Sendable {
    func upsert(chunkId: Int64, modelId: String, textHash: String, embedding: [Float]) throws
    func remove(chunkIds: [Int64]) throws
    func nearest(to query: [Float], modelId: String, limit: Int) throws -> [VectorMatch]
}

/// Float32-Little-Endian-Codec. arm64 ist nativ LE → direkter Speichercopy.
public enum VectorBlob {
    public static func data(from v: [Float]) -> Data { v.withUnsafeBytes { Data($0) } }
    public static func vector(from d: Data) -> [Float] {
        let count = d.count / MemoryLayout<Float>.size
        return d.withUnsafeBytes { raw in Array(raw.bindMemory(to: Float.self).prefix(count)) }
    }
}

/// Brute-Force-Cosinus über alle Vektoren eines Modells (vDSP). Für persönliche
/// Korpora (zehntausende Chunks) im zweistelligen Millisekundenbereich.
public struct BruteForceVectorStore: VectorStore {
    private let db: IndexDatabase
    public init(db: IndexDatabase) { self.db = db }

    public func upsert(chunkId: Int64, modelId: String, textHash: String, embedding: [Float]) throws {
        try db.upsertEmbedding(chunkId: chunkId, modelId: modelId, textHash: textHash, vector: embedding)
    }

    public func remove(chunkIds: [Int64]) throws { try db.removeEmbeddings(chunkIds: chunkIds) }

    public func nearest(to query: [Float], modelId: String, limit: Int) throws -> [VectorMatch] {
        let all = try db.allEmbeddings(modelId: modelId)
        let scored = all.compactMap { entry -> VectorMatch? in
            guard entry.vector.count == query.count else { return nil }
            return VectorMatch(chunkId: entry.chunkId, score: Self.cosine(query, entry.vector))
        }
        return Array(scored.sorted { $0.score > $1.score }.prefix(limit))
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        let n = vDSP_Length(a.count)
        var dot: Float = 0; vDSP_dotpr(a, 1, b, 1, &dot, n)
        var sa: Float = 0; vDSP_svesq(a, 1, &sa, n)
        var sb: Float = 0; vDSP_svesq(b, 1, &sb, n)
        let denom = sqrt(sa) * sqrt(sb)
        return denom == 0 ? 0 : Double(dot / denom)
    }
}
```

- [x] **Step 1.7: `VectorStoreTests` schreiben**

`Tests/UnitTests/VectorStoreTests.swift`:
```swift
import XCTest
import GRDB
@testable import SharedCore

final class VectorStoreTests: XCTestCase {
    private func makeDB() throws -> IndexDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("localseek-vec-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("index.sqlite")
        return try IndexDatabase(url: url)
    }

    private func seedChunk(_ db: IndexDatabase, text: String, ordinal: Int = 0) throws -> Int64 {
        try db.upsertSource(SourceRecord(id: "s1", path: "/tmp/s1"))
        try db.upsertFile(FileRecord(sourceId: "s1", relativePath: "f\(ordinal).txt",
                                     filename: "f\(ordinal).txt", fileExtension: "txt",
                                     size: 1, mtime: nil))
        let fileId = try db.dbPool.read { dbc in
            try Int64.fetchOne(dbc, sql: "SELECT id FROM files WHERE relativePath = ?",
                               arguments: ["f\(ordinal).txt"])!
        }
        try db.replaceChunks(fileId: fileId, chunks: [ChunkRecord(fileId: fileId, ordinal: 0, text: text)])
        return try db.dbPool.read { dbc in
            try Int64.fetchOne(dbc, sql: "SELECT id FROM chunks WHERE fileId = ?", arguments: [fileId])!
        }
    }

    func testBlobRoundTrip() {
        let v: [Float] = [0.1, -0.5, 1.0, 0.0]
        XCTAssertEqual(VectorBlob.vector(from: VectorBlob.data(from: v)), v)
    }

    func testNearestRanksByCosine() throws {
        let db = try makeDB()
        let store = BruteForceVectorStore(db: db)
        let near = try seedChunk(db, text: "a", ordinal: 0)
        let far  = try seedChunk(db, text: "b", ordinal: 1)
        try store.upsert(chunkId: near, modelId: "m", textHash: "h1", embedding: [1, 0, 0])
        try store.upsert(chunkId: far,  modelId: "m", textHash: "h2", embedding: [0, 1, 0])

        let hits = try store.nearest(to: [0.9, 0.1, 0], modelId: "m", limit: 10)
        XCTAssertEqual(hits.map(\.chunkId), [near, far])
        XCTAssertGreaterThan(hits[0].score, hits[1].score)
    }

    func testModelScopingAndEmptyIndex() throws {
        let db = try makeDB()
        let store = BruteForceVectorStore(db: db)
        let c = try seedChunk(db, text: "a")
        try store.upsert(chunkId: c, modelId: "m1", textHash: "h", embedding: [1, 0, 0])
        XCTAssertEqual(try store.nearest(to: [1, 0, 0], modelId: "m2", limit: 5), [])
        XCTAssertEqual(try db.embeddingCount(modelId: "m1"), 1)
    }

    func testCascadeDeleteRemovesVectors() throws {
        let db = try makeDB()
        let store = BruteForceVectorStore(db: db)
        let c = try seedChunk(db, text: "a")
        try store.upsert(chunkId: c, modelId: "m", textHash: "h", embedding: [1, 0, 0])
        try db.removeSource(id: "s1")
        XCTAssertEqual(try db.embeddingCount(), 0)
    }

    func testChunksNeedingEmbeddingIncremental() throws {
        let db = try makeDB()
        let store = BruteForceVectorStore(db: db)
        let c = try seedChunk(db, text: "Risiko im Zahlungsverkehr")
        XCTAssertEqual(try db.chunksNeedingEmbedding(modelId: "m").map(\.id), [c])
        try store.upsert(chunkId: c, modelId: "m",
                         textHash: StableHash.hex("Risiko im Zahlungsverkehr"), embedding: [1, 0, 0])
        XCTAssertTrue(try db.chunksNeedingEmbedding(modelId: "m").isEmpty)
        XCTAssertEqual(try db.chunksNeedingEmbedding(modelId: "other").map(\.id), [c])
    }
}
```

- [x] **Step 1.8: Build + Tests ausführen**

Run:
```bash
cd "35_IndexSearch/LocalSeek" && xcodegen generate && xcodebuild test -scheme LocalSeek -destination 'platform=macOS' 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED, alle bisherigen 49 + neue Tests grün.

- [ ] **Step 1.9: Commit**

```bash
git add Shared Tests project.yml
git commit -m "[Add] Phase 4 Schritt 1: Schema v4-vectors + VectorStore (BruteForce/vDSP)"
```

---

## Task 2: `LlamaBridge`-Native-Target + `EmbeddingProvider` + `LlamaEmbeddingProvider` (SPIKE)

**Dies ist ein Verifikations-Spike, kein geratener Build.** Die llama.cpp-Embedding-API
ist versionssensibel. Zuerst wird gegen die **reale, gepinnte Quelle** verifiziert, dann
der dünne Shim geschrieben. Erst wenn der Referenz-Embedding-Test grün ist, gilt Task 2 als fertig.

**Files:**
- Create: `Shared/Core/Embedding/EmbeddingProvider.swift`
- Create: `LlamaBridge/include/localseek_llama.h`, `LlamaBridge/src/localseek_llama.cpp`
- Create: `Apps/LocalSeek/LlamaEmbeddingProvider.swift`
- Create: `Apps/LocalSeek/ModelLocator.swift`
- Modify: `project.yml` (Native-Target + Link)
- Test: `Tests/UnitTests/LlamaEmbeddingProviderTests.swift` (Integrationstest, `skip` wenn Modell fehlt)

- [x] **Step 2.0: `EmbeddingProvider`-Protokoll schreiben (llama-unabhängig)**

`Shared/Core/Embedding/EmbeddingProvider.swift`:
```swift
import Foundation

/// e5 verlangt Präfixe: Anfragen "query: …", Dokumente "passage: …".
public enum EmbeddingKind: Sendable { case query, passage }

public protocol EmbeddingProvider: Sendable {
    var dimensions: Int { get }
    /// Liefert je Eingabetext einen L2-normierten Vektor der Länge `dimensions`.
    func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]]
}

public enum EmbeddingError: Error, Equatable {
    case modelMissing
    case dimensionMismatch(expected: Int, got: Int)
    case inferenceFailed
}
```

- [x] **Step 2.1: Verifikations-Spike — llama.cpp-Baumechanik (KEIN Code, nur Nachweis)**

Konkrete Entscheidungen, die der Spike **nachweislich** klären und im Plan-PR dokumentieren muss (jeweils mit Beleg aus der realen Quelle, nicht aus Vermutung):

1. **Release pinnen:** Einen konkreten llama.cpp-Release-Tag wählen (z. B. aktuellen `bXXXX`-Build-Tag) und notieren. Alle API-Namen gegen `include/llama.h` **dieses** Tags prüfen.
2. **Bezugsform:** Entscheiden zwischen (a) vorgebautem `llama.xcframework` aus den Release-Assets vs. (b) Quell-Build via `cmake` zu statischen `.a` (libllama, libggml, libggml-base, libggml-metal). Nachweis: welche Artefakte der gewählte Tag liefert.
3. **Metal-Shader:** Klären, wie `default.metallib`/`ggml-metal` eingebunden wird (im xcframework enthalten vs. zur Laufzeit zu bündeln). Nachweis durch Inspektion des Artefakts.
4. **Embedding-API** gegen `llama.h` des Tags verifizieren. Erwartet (gegen `examples/embedding` bestätigt, Namen tag-abhängig): `llama_model_load_from_file`, `llama_init_from_model` mit `ctx_params.embeddings = true` + `pooling_type = LLAMA_POOLING_TYPE_MEAN`, `llama_tokenize`, Batch füllen, `llama_decode`/`llama_encode`, `llama_get_embeddings_seq(ctx, seq_id)`, Dimension via `llama_model_n_embd`/`llama_model_n_embd_out`. L2-Normierung selbst (oder `common_embd_normalize`). **Exakte Namen aus dem gepinnten Header übernehmen.**
5. **project.yml-Verdrahtung** als Native-Target bestimmen: `type: library.static`, `sources: [LlamaBridge]`, Header-Search-Paths zum llama-Include, `OTHER_LDFLAGS`/`dependencies` für die statischen libs + Frameworks (`Metal`, `Accelerate`, `Foundation`). SharedCore (oder die App) linkt `LlamaBridge`.

Verify (Spike-Abnahme): Ein `localseek_llama.cpp`-Stub, der Modell lädt und für Testtext einen 384-Vektor zurückgibt, kompiliert und linkt im App-Target. `xcodebuild build -scheme LocalSeek` → BUILD SUCCEEDED **mit** gelinktem llama.

- [x] **Step 2.2: C-Shim-Header schreiben (schmale, stabile Oberfläche)**

`LlamaBridge/include/localseek_llama.h`:
```c
#ifndef LOCALSEEK_LLAMA_H
#define LOCALSEEK_LLAMA_H
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ls_llama_ctx ls_llama_ctx;

// Lädt das GGUF-Embedding-Modell. NULL bei Fehler.
ls_llama_ctx *ls_llama_load(const char *model_path);
void ls_llama_free(ls_llama_ctx *ctx);
// Ausgabedimension des geladenen Modells (z. B. 384). 0 wenn ungeladen.
int32_t ls_llama_n_embd(ls_llama_ctx *ctx);
// Bettet EINEN bereits präfigierten Text ein. Schreibt n_embd Floats (L2-normiert)
// nach out_embd (Kapazität out_capacity). Rückgabe: Anzahl geschriebener Floats, <0 bei Fehler.
int32_t ls_llama_embed(ls_llama_ctx *ctx, const char *text,
                       float *out_embd, int32_t out_capacity);

#ifdef __cplusplus
}
#endif
#endif
```

> Die `.cpp`-Umsetzung ruft die in Step 2.1 verifizierten llama-Funktionen auf. **Keine
> API-Namen raten** — die im gepinnten Header bestätigten verwenden. L2-Normierung im Shim.

- [x] **Step 2.3: `ModelLocator` schreiben (Auffinden + Prüfsumme, kein Auto-Download)**

`Apps/LocalSeek/ModelLocator.swift`:
```swift
import Foundation
import CryptoKit

/// Findet das GGUF-Embedding-Modell lokal (SPEC §9: kein Auto-Download).
/// Standardort: ~/Library/Application Support/LocalSeek/models/.
enum ModelLocator {
    static func modelsDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("LocalSeek/models", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Erstes `.gguf` im Modellordner, falls vorhanden.
    static func installedModel() throws -> URL? {
        let dir = try modelsDirectory()
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .first { $0.pathExtension.lowercased() == "gguf" }
    }

    /// Kopiert eine vom Nutzer gewählte GGUF-Datei in den Modellordner.
    static func install(from source: URL) throws -> URL {
        let dest = try modelsDirectory().appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }

    static func checksum(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
```

- [x] **Step 2.4: `LlamaEmbeddingProvider`-Actor schreiben**

`Apps/LocalSeek/LlamaEmbeddingProvider.swift`:
```swift
import Foundation
import SharedCore
import LlamaBridge

/// Serialisiert den nicht thread-sicheren llama-Kontext (Swift 6 strict concurrency).
/// Lädt das Modell on demand, präfigiert e5 (query:/passage:), normiert im Shim.
actor LlamaEmbeddingProvider: EmbeddingProvider {
    nonisolated let dimensions: Int = 384
    private let modelURL: URL
    private var ctx: OpaquePointer?

    init(modelURL: URL) { self.modelURL = modelURL }

    private func ensureLoaded() throws {
        if ctx != nil { return }
        guard let c = ls_llama_load(modelURL.path) else { throw EmbeddingError.modelMissing }
        let n = Int(ls_llama_n_embd(c))
        guard n == dimensions else { ls_llama_free(c); throw EmbeddingError.dimensionMismatch(expected: dimensions, got: n) }
        ctx = c
    }

    func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]] {
        try ensureLoaded()
        guard let ctx else { throw EmbeddingError.modelMissing }
        let prefix = kind == .query ? "query: " : "passage: "
        return try texts.map { text in
            var out = [Float](repeating: 0, count: dimensions)
            let written = out.withUnsafeMutableBufferPointer {
                ls_llama_embed(ctx, prefix + text, $0.baseAddress, Int32(dimensions))
            }
            guard written == Int32(dimensions) else { throw EmbeddingError.inferenceFailed }
            return out
        }
    }

    func unload() { if let ctx { ls_llama_free(ctx); self.ctx = nil } }
}
```

- [x] **Step 2.5: Modell beschaffen (manuell, einmalig)**

Ein `multilingual-e5-small`-GGUF (384-dim) nach `~/Library/Application Support/LocalSeek/models/` legen (vom Nutzer bereitgestellt — kein Auto-Download). SHA-256 notieren für `models.checksum`.

- [ ] **Step 2.6: Integrationstest (skippt ohne Modell)**

`Tests/UnitTests/LlamaEmbeddingProviderTests.swift` — hängt am App-Target, nicht an SharedCore. Falls Testbarkeit am App-Target nicht gegeben: als manuelles Abnahmeskript im App-Kontext ausführen. Prüft: (a) `query: "Katze"` und `passage: "cat"` haben Cosinus > `query: "Katze"` vs. `passage: "Auto"` (cross-lingual Signal); (b) Vektorlänge 384; (c) deterministisch (zweimal gleich).

Verify: Build mit gelinktem llama grün; Integrationstest grün (lokal, mit Modell).

- [ ] **Step 2.7: Commit**

```bash
git add LlamaBridge Shared Apps project.yml Tests
git commit -m "[Add] Phase 4 Schritt 2: LlamaBridge + LlamaEmbeddingProvider (e5-small)"
```

---

## Task 3: `EmbeddingIndexer` + Verdrahtung in `IndexService`

**Files:**
- Create: `Shared/Core/Embedding/EmbeddingIndexer.swift`
- Create: `Tests/UnitTests/FakeEmbeddingProvider.swift`, `Tests/UnitTests/EmbeddingIndexerTests.swift`
- Modify: `Apps/LocalSeek/IndexService.swift`

- [x] **Step 3.1: `EmbeddingIndexer` schreiben**

`Shared/Core/Embedding/EmbeddingIndexer.swift`:
```swift
import Foundation

/// Bettet fällige Chunks (ohne/veralteten Vektor) ein und schreibt sie in den
/// `VectorStore`. Inkrementell über `IndexDatabase.chunksNeedingEmbedding` (Hash-Vergleich).
/// Fehler eines Chunks brechen den Lauf nicht ab (SPEC §8-analog: überspringen, loggen ohne Inhalt).
public struct EmbeddingIndexer: Sendable {
    private let provider: EmbeddingProvider
    private let store: VectorStore
    private let batchSize: Int

    public init(provider: EmbeddingProvider, store: VectorStore, batchSize: Int = 16) {
        self.provider = provider
        self.store = store
        self.batchSize = max(1, batchSize)
    }

    /// Bettet alle fälligen Chunks für `modelId` ein. Gibt die Anzahl eingebetteter Chunks zurück.
    @discardableResult
    public func indexEmbeddings(modelId: String, into db: IndexDatabase) async throws -> Int {
        let pending = try db.chunksNeedingEmbedding(modelId: modelId)
        var done = 0
        var index = 0
        while index < pending.count {
            let batch = Array(pending[index..<min(index + batchSize, pending.count)])
            index += batchSize
            let vectors = try await provider.embed(batch.map(\.text), kind: .passage)
            for (chunk, vec) in zip(batch, vectors) {
                guard let chunkId = chunk.id else { continue }
                guard vec.count == provider.dimensions else {
                    throw EmbeddingError.dimensionMismatch(expected: provider.dimensions, got: vec.count)
                }
                try store.upsert(chunkId: chunkId, modelId: modelId,
                                 textHash: StableHash.hex(chunk.text), embedding: vec)
                done += 1
            }
        }
        return done
    }
}
```

- [x] **Step 3.2: `FakeEmbeddingProvider` (Test-Helfer) schreiben**

`Tests/UnitTests/FakeEmbeddingProvider.swift`:
```swift
import Foundation
@testable import SharedCore

/// Deterministischer Provider für Unit-Tests — kein llama. Bildet Text stabil auf
/// einen normierten 3-dim-Vektor ab (für Tests ist die Dimension frei wählbar).
struct FakeEmbeddingProvider: EmbeddingProvider {
    let dimensions: Int
    init(dimensions: Int = 3) { self.dimensions = dimensions }

    func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]] {
        texts.map { text in
            var v = [Float](repeating: 0, count: dimensions)
            for (i, scalar) in text.unicodeScalars.enumerated() {
                v[i % dimensions] += Float(scalar.value % 97)
            }
            let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
            return norm == 0 ? v : v.map { $0 / norm }
        }
    }
}
```

- [x] **Step 3.3: `EmbeddingIndexerTests` schreiben**

`Tests/UnitTests/EmbeddingIndexerTests.swift`:
```swift
import XCTest
import GRDB
@testable import SharedCore

final class EmbeddingIndexerTests: XCTestCase {
    private func makeDB() throws -> IndexDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("localseek-emb-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("index.sqlite")
        return try IndexDatabase(url: url)
    }

    private func seed(_ db: IndexDatabase, _ texts: [String]) throws -> [Int64] {
        try db.upsertSource(SourceRecord(id: "s1", path: "/tmp/s1"))
        try db.upsertFile(FileRecord(sourceId: "s1", relativePath: "a.txt", filename: "a.txt",
                                     fileExtension: "txt", size: 1, mtime: nil))
        let fileId = try db.dbPool.read { try Int64.fetchOne($0, sql: "SELECT id FROM files")! }
        try db.replaceChunks(fileId: fileId, chunks: texts.enumerated().map {
            ChunkRecord(fileId: fileId, ordinal: $0.offset, text: $0.element)
        })
        return try db.dbPool.read { try Int64.fetchAll($0, sql: "SELECT id FROM chunks ORDER BY id") }
    }

    func testEmbedsAllPendingChunks() async throws {
        let db = try makeDB()
        _ = try seed(db, ["Risiko", "Zahlung"])
        let indexer = EmbeddingIndexer(provider: FakeEmbeddingProvider(), store: BruteForceVectorStore(db: db))
        let n = try await indexer.indexEmbeddings(modelId: "fake-3", into: db)
        XCTAssertEqual(n, 2)
        XCTAssertEqual(try db.embeddingCount(modelId: "fake-3"), 2)
    }

    func testNoReembedWhenUnchanged() async throws {
        let db = try makeDB()
        _ = try seed(db, ["Risiko"])
        let indexer = EmbeddingIndexer(provider: FakeEmbeddingProvider(), store: BruteForceVectorStore(db: db))
        _ = try await indexer.indexEmbeddings(modelId: "fake-3", into: db)
        let second = try await indexer.indexEmbeddings(modelId: "fake-3", into: db)
        XCTAssertEqual(second, 0, "Unveränderte Chunks nicht erneut einbetten")
    }

    func testModelSwitchReembedsAll() async throws {
        let db = try makeDB()
        _ = try seed(db, ["Risiko", "Zahlung"])
        let indexer = EmbeddingIndexer(provider: FakeEmbeddingProvider(), store: BruteForceVectorStore(db: db))
        _ = try await indexer.indexEmbeddings(modelId: "m1", into: db)
        let afterSwitch = try await indexer.indexEmbeddings(modelId: "m2", into: db)
        XCTAssertEqual(afterSwitch, 2, "Modellwechsel macht alte Vektoren veraltet")
    }
}
```

- [x] **Step 3.4: Verdrahtung in `IndexService`**

In `Apps/LocalSeek/IndexService.swift`:

(a) Felder nach `contentIndexer` (Zeile 17) ergänzen — Provider/Indexer werden nur erzeugt, wenn ein Modell installiert ist (bis Task 2 geliefert: bleibt `nil`, Hybrid fällt lexikalisch zurück):
```swift
    private var embeddingProvider: (any EmbeddingProvider)?
    private var activeModelId: String?
```

(b) In `init()` nach `reload()` die Modellerkennung ergänzen:
```swift
        loadActiveModelIfAvailable()
```
und Methode hinzufügen:
```swift
    /// Erkennt ein installiertes GGUF-Modell und aktiviert den Provider (sonst nur lexikalisch).
    private func loadActiveModelIfAvailable() {
        guard let db, let url = try? ModelLocator.installedModel(), let url else { return }
        let id = url.lastPathComponent
        activeModelId = id
        embeddingProvider = LlamaEmbeddingProvider(modelURL: url)
        try? db.upsertModel(ModelRecord(modelId: id, name: id, dimensions: 384,
                                        checksum: (try? ModelLocator.checksum(of: url)) ?? "", active: true))
        try? db.setActiveModel(modelId: id)
    }
```

(c) In `addSource` (im `Task.detached`-Block, nach `contentIndexer.indexContent`, Zeile 47) Embedding anstoßen:
```swift
                try await self.runEmbeddingIfAvailable(source: source, db: db)
```
und in `flushRescans` (nach `contentIndexer.indexContent`, Zeile 136) analog. Helfer:
```swift
    /// Bettet nach der Inhaltsextraktion fällige Chunks ein (nur wenn Modell aktiv).
    private func runEmbeddingIfAvailable(source: SourceRecord, db: IndexDatabase) async throws {
        guard let provider = embeddingProvider, let modelId = activeModelId else { return }
        let indexer = EmbeddingIndexer(provider: provider, store: BruteForceVectorStore(db: db))
        _ = try await indexer.indexEmbeddings(modelId: modelId, into: db)
    }
```
> `runEmbeddingIfAvailable` ist `@MainActor`-isoliert, läuft aber `await`-basiert; die eigentliche
> Inferenz serialisiert der Provider-Actor. Für den Hintergrundlauf aus `Task.detached` ggf. den
> Provider + modelId als lokale Konstanten vor dem `detached`-Block binden (wie `db`/`scanner`).
> **Beim Umsetzen gegen Swift-6-Concurrency prüfen** und wie bestehende Felder (`[db, scanner, …]`) capturen.

(d) `reload()` (Zeile 157): `embeddingCount: 0` ersetzen durch echten Wert:
```swift
                embeddingCount: (try? db.embeddingCount()) ?? 0,
```

- [x] **Step 3.5: Build + Tests**

Run:
```bash
cd "35_IndexSearch/LocalSeek" && xcodegen generate && xcodebuild test -scheme LocalSeek -destination 'platform=macOS' 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED, EmbeddingIndexer-Tests grün. (Wenn Task 2 noch nicht geliefert: `embeddingProvider` bleibt `nil`, IndexService baut trotzdem.)

- [ ] **Step 3.6: Commit**

```bash
git add Shared Apps Tests
git commit -m "[Add] Phase 4 Schritt 3: EmbeddingIndexer + Verdrahtung (inkrementell)"
```

---

## Task 4: `HybridSearchEngine` (RRF-Fusion + Dokumentgruppierung)

**Files:**
- Create: `Shared/Core/Search/HybridSearchEngine.swift`
- Modify: `Shared/Persistence/IndexDatabase.swift` (Helfer `fetchChunkHits`)
- Test: `Tests/UnitTests/HybridSearchEngineTests.swift`

- [x] **Step 4.1: DB-Helfer `fetchChunkHits` anhängen**

In `IndexDatabase`, nach `activeModel()` (für Vektor-Treffer, die keinen FTS-Snippet haben):
```swift
/// Baut `ContentSearchHit` für gegebene chunkIds (Reihenfolge der Eingabe erhalten).
/// Snippet = Textpräfix (kein FTS-Match), `bm25 = 0`. Für Vektor-/Hybrid-Treffer.
public func fetchChunkHits(chunkIds: [Int64]) throws -> [ContentSearchHit] {
    guard !chunkIds.isEmpty else { return [] }
    let placeholders = chunkIds.map { _ in "?" }.joined(separator: ", ")
    let byId: [Int64: ContentSearchHit] = try dbPool.read { db in
        let rows = try Row.fetchAll(db, sql: """
            SELECT chunks.id AS chunkId, files.id AS fileId, files.sourceId AS sourceId,
                   files.relativePath AS relativePath, files.filename AS filename,
                   chunks.ordinal AS ordinal, chunks.locationType AS locationType,
                   chunks.locationValue AS locationValue, chunks.text AS text
            FROM chunks JOIN files ON files.id = chunks.fileId
            WHERE chunks.id IN (\(placeholders)) AND files.state != 'deleted'
            """, arguments: StatementArguments(chunkIds))
        var map: [Int64: ContentSearchHit] = [:]
        for row in rows {
            let text: String = row["text"]
            let snippet = String(text.prefix(160))
            let id: Int64 = row["chunkId"]
            map[id] = ContentSearchHit(
                chunkId: id, fileId: row["fileId"], sourceId: row["sourceId"],
                relativePath: row["relativePath"], filename: row["filename"],
                ordinal: row["ordinal"], locationType: row["locationType"],
                locationValue: row["locationValue"], snippet: snippet, bm25: 0)
        }
        return map
    }
    return chunkIds.compactMap { byId[$0] }
}
```

- [x] **Step 4.2: `HybridSearchEngine` schreiben**

`Shared/Core/Search/HybridSearchEngine.swift`:
```swift
import Foundation

public enum SearchStrategy: Sendable { case exact, semantic, hybrid }

/// Fusioniert lexikalische (BM25) und semantische (Vektor) Suche per Reciprocal Rank Fusion,
/// gruppiert nach Dokument (bester Chunk je Datei zuerst). Fällt bei fehlendem Modell/leerem
/// Vektorindex still auf rein lexikalische Suche zurück (SPEC §6: exakte Suche immer verfügbar).
public struct HybridSearchEngine: Sendable {
    private let db: IndexDatabase
    private let provider: (any EmbeddingProvider)?
    private let store: (any VectorStore)?
    private let modelId: String?
    private let ftsWeight: Double
    private let vecWeight: Double
    private let rrfK: Double

    public init(db: IndexDatabase, provider: (any EmbeddingProvider)?, store: (any VectorStore)?,
                modelId: String?, ftsWeight: Double = 0.55, vecWeight: Double = 0.45, rrfK: Double = 60) {
        self.db = db; self.provider = provider; self.store = store; self.modelId = modelId
        self.ftsWeight = ftsWeight; self.vecWeight = vecWeight; self.rrfK = rrfK
    }

    public func search(_ query: String, strategy: SearchStrategy, limit: Int = 50) async throws -> [ContentSearchHit] {
        switch strategy {
        case .exact:    return groupByDocument(try db.searchChunks(query, limit: limit * 3), limit: limit)
        case .semantic: return try await semanticHits(query, limit: limit)
        case .hybrid:   return try await hybridHits(query, limit: limit)
        }
    }

    private func semanticHits(_ query: String, limit: Int) async throws -> [ContentSearchHit] {
        guard let ids = try await vectorChunkIds(query, limit: limit * 3) else { return [] }
        return groupByDocument(try db.fetchChunkHits(chunkIds: ids), limit: limit)
    }

    private func hybridHits(_ query: String, limit: Int) async throws -> [ContentSearchHit] {
        let ftsHits = try db.searchChunks(query, limit: limit * 3)
        let ftsIds = ftsHits.map(\.chunkId)
        guard let vecIds = try await vectorChunkIds(query, limit: limit * 3), !vecIds.isEmpty else {
            return groupByDocument(ftsHits, limit: limit)   // stiller Fallback
        }
        let fusedIds = Self.rrf(fts: ftsIds, vec: vecIds, ftsWeight: ftsWeight, vecWeight: vecWeight, k: rrfK)
        return groupByDocument(try db.fetchChunkHits(chunkIds: fusedIds), limit: limit)
    }

    /// Query einbetten + Vektor-Nearest. `nil`, wenn kein Modell/Store aktiv.
    private func vectorChunkIds(_ query: String, limit: Int) async throws -> [Int64]? {
        guard let provider, let store, let modelId else { return nil }
        let vectors = try await provider.embed([query], kind: .query)
        guard let qv = vectors.first else { return nil }
        return try store.nearest(to: qv, modelId: modelId, limit: limit).map(\.chunkId)
    }

    /// Reine, DB-freie RRF-Fusion zweier Rang-Listen (Rang = Position). Höher = besser.
    public static func rrf(fts: [Int64], vec: [Int64], ftsWeight: Double, vecWeight: Double, k: Double) -> [Int64] {
        var score: [Int64: Double] = [:]
        for (rank, id) in fts.enumerated() { score[id, default: 0] += ftsWeight / (k + Double(rank + 1)) }
        for (rank, id) in vec.enumerated() { score[id, default: 0] += vecWeight / (k + Double(rank + 1)) }
        return score.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// Behält je Datei den bestplatzierten Chunk, Reihenfolge der Eingabe erhalten.
    private func groupByDocument(_ hits: [ContentSearchHit], limit: Int) -> [ContentSearchHit] {
        var seen: Set<Int64> = []
        var out: [ContentSearchHit] = []
        for hit in hits where !seen.contains(hit.fileId) {
            seen.insert(hit.fileId); out.append(hit)
            if out.count == limit { break }
        }
        return out
    }
}
```

- [x] **Step 4.3: `HybridSearchEngineTests` schreiben**

`Tests/UnitTests/HybridSearchEngineTests.swift`:
```swift
import XCTest
import GRDB
@testable import SharedCore

final class HybridSearchEngineTests: XCTestCase {
    private func makeDB() throws -> IndexDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("localseek-hyb-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("index.sqlite")
        return try IndexDatabase(url: url)
    }

    func testRRFPrefersConsensus() {
        // id 2 steht in beiden Listen vorn → sollte oben landen.
        let fused = HybridSearchEngine.rrf(fts: [1, 2, 3], vec: [2, 4, 1],
                                           ftsWeight: 0.55, vecWeight: 0.45, k: 60)
        XCTAssertEqual(fused.first, 2)
        XCTAssertEqual(Set(fused), Set([1, 2, 3, 4]))
    }

    func testExactFallbackWhenNoProvider() async throws {
        let db = try makeDB()
        try db.upsertSource(SourceRecord(id: "s1", path: "/tmp/s1"))
        try db.upsertFile(FileRecord(sourceId: "s1", relativePath: "a.txt", filename: "a.txt",
                                     fileExtension: "txt", size: 1, mtime: nil))
        let fileId = try db.dbPool.read { try Int64.fetchOne($0, sql: "SELECT id FROM files")! }
        try db.replaceChunks(fileId: fileId, chunks: [
            ChunkRecord(fileId: fileId, ordinal: 0, text: "Risiko im Zahlungsverkehr")])

        let engine = HybridSearchEngine(db: db, provider: nil, store: nil, modelId: nil)
        let hybrid = try await engine.search("Zahlungsverkehr", strategy: .hybrid)
        XCTAssertEqual(hybrid.count, 1, "Ohne Modell fällt Hybrid auf lexikalisch zurück")
        XCTAssertEqual(hybrid.first?.fileId, fileId)
    }

    func testSemanticAndDocumentGrouping() async throws {
        let db = try makeDB()
        let store = BruteForceVectorStore(db: db)
        try db.upsertSource(SourceRecord(id: "s1", path: "/tmp/s1"))
        try db.upsertFile(FileRecord(sourceId: "s1", relativePath: "a.txt", filename: "a.txt",
                                     fileExtension: "txt", size: 1, mtime: nil))
        let fileId = try db.dbPool.read { try Int64.fetchOne($0, sql: "SELECT id FROM files")! }
        try db.replaceChunks(fileId: fileId, chunks: [
            ChunkRecord(fileId: fileId, ordinal: 0, text: "nah"),
            ChunkRecord(fileId: fileId, ordinal: 1, text: "fern")])
        let ids = try db.dbPool.read { try Int64.fetchAll($0, sql: "SELECT id FROM chunks ORDER BY id") }
        try store.upsert(chunkId: ids[0], modelId: "m", textHash: "h0", embedding: [1, 0, 0])
        try store.upsert(chunkId: ids[1], modelId: "m", textHash: "h1", embedding: [0, 1, 0])

        // Fake-Provider, der die Query auf [1,0,0] abbildet → Chunk 0 am nächsten.
        struct QV: EmbeddingProvider {
            let dimensions = 3
            func embed(_ t: [String], kind: EmbeddingKind) async throws -> [[Float]] { t.map { _ in [1, 0, 0] } }
        }
        let engine = HybridSearchEngine(db: db, provider: QV(), store: store, modelId: "m")
        let hits = try await engine.search("egal", strategy: .semantic)
        XCTAssertEqual(hits.count, 1, "Beide Chunks gehören zu einer Datei → ein Dokument-Treffer")
        XCTAssertEqual(hits.first?.ordinal, 0, "Bester (nächster) Chunk zuerst")
    }
}
```

- [x] **Step 4.4: Build + Tests**

Run:
```bash
cd "35_IndexSearch/LocalSeek" && xcodegen generate && xcodebuild test -scheme LocalSeek -destination 'platform=macOS' 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED, Hybrid-Tests grün.

- [ ] **Step 4.5: Commit**

```bash
git add Shared Tests
git commit -m "[Add] Phase 4 Schritt 4: HybridSearchEngine (RRF + Dokumentgruppierung)"
```

---

## Task 5: Such-UI (Hybrid/Exakt/Semantisch) + Modell-Status

Keine neuen Unit-Tests (UI); **manuelle Abnahme** gegen echten Index + echtes Modell.

**Files:**
- Modify: `Apps/LocalSeek/IndexService.swift` (öffentliche Hybrid-Suche)
- Modify: `Apps/LocalSeek/Views/SearchView.swift` (Submodus-Picker)
- Modify: `Apps/LocalSeek/Views/StatusView.swift` (embeddingCount + „Modell wählen…")

- [x] **Step 5.1: Hybrid-Suche in `IndexService` exponieren**

Nach `searchContentAsync` (Zeile 87):
```swift
    /// Hybride/semantische/exakte Inhaltssuche abseits des Main-Threads.
    func searchContentAsync(_ query: String, strategy: SearchStrategy) async -> [ContentSearchHit] {
        guard let db else { return [] }
        let engine = HybridSearchEngine(db: db, provider: embeddingProvider,
                                        store: embeddingProvider == nil ? nil : BruteForceVectorStore(db: db),
                                        modelId: activeModelId)
        return (try? await engine.search(query, strategy: strategy)) ?? []
    }

    /// Ob ein Embedding-Modell aktiv ist (für UI-Degradationshinweis).
    var hasEmbeddingModel: Bool { embeddingProvider != nil }

    /// Installiert ein vom Nutzer gewähltes GGUF-Modell und aktiviert es.
    func installModel(from url: URL) {
        guard let dest = try? ModelLocator.install(from: url) else { lastError = "Modell konnte nicht installiert werden"; return }
        _ = dest
        loadActiveModelIfAvailable()
        reload()
    }
```
> `loadActiveModelIfAvailable` und `installModel` müssen Access-Level teilen; `loadActiveModelIfAvailable`
> ggf. von `private` auf intern anheben, falls aus `installModel` genutzt (gleiche Klasse → `private` reicht).

- [x] **Step 5.2: Submodus-Picker in `SearchView`**

In `SearchView` ein `SearchStrategy`-State ergänzen und bei `mode == .content` einen zweiten
segmentierten Picker zeigen. `scheduleSearch` ruft im Content-Fall `searchContentAsync(trimmed, strategy:)`.

State (nach Zeile 16 `@State private var mode`):
```swift
    @State private var strategy: SearchStrategy = .hybrid
```
Mapping für die Picker-Labels (lokaler Enum in der View, da `SearchStrategy` kein `CaseIterable`):
```swift
    private var strategyLabels: [(SearchStrategy, String)] {
        [(.hybrid, "Hybrid"), (.exact, "Exakt"), (.semantic, "Semantisch")]
    }
```
Im `header` unter dem bestehenden Modus-Picker, nur bei Inhalt:
```swift
            if mode == .content {
                Picker("", selection: $strategy) {
                    ForEach(strategyLabels, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .onChange(of: strategy) { _, _ in scheduleSearch(query) }
                if !index.hasEmbeddingModel && strategy != .exact {
                    Text("Modell nicht geladen – nur exakte Suche aktiv")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
```
> `SearchStrategy` muss `Hashable` sein für `ForEach(id:)`/`tag` — in Task 4 ggf. `: Sendable, Hashable`
> ergänzen (reiner Enum ohne Assoziierte → automatisch `Hashable`-fähig; `Hashable` deklarieren).

In `scheduleSearch`, Content-Zweig (Zeile 157):
```swift
                let hits = await index.searchContentAsync(trimmed, strategy: strategy)
```

- [x] **Step 5.3: `StatusView` — embeddingCount + „Modell wählen…"**

`StatusView` zeigt `index.status.embeddingCount` neben `chunkCount`. Wenn `!index.hasEmbeddingModel`,
eine Aktion „Modell wählen…" via `NSOpenPanel` (Dateityp `gguf`) → `index.installModel(from:)`.
Muster für den Panel-Aufruf (an bestehende Settings-Ordnerauswahl angelehnt):
```swift
    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "gguf")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { index.installModel(from: url) }
    }
```

- [ ] **Step 5.4: Build + manuelle Abnahme**

Run (Build + Installation nach `~/Applications`):
```bash
cd "35_IndexSearch/LocalSeek" && xcodegen generate && xcodebuild -scheme LocalSeek -configuration Debug build 2>&1 | tail -5
pkill -x LocalSeek; sleep 1
BUILT="$HOME/Library/Developer/Xcode/DerivedData/LocalSeek-gokdodeivaohebeizzrxekjxnybh/Build/Products/Debug/LocalSeek.app"
rm -rf ~/Applications/LocalSeek.app && cp -R "$BUILT" ~/Applications/LocalSeek.app && open ~/Applications/LocalSeek.app
```
Manuelle Abnahme (SPEC §9 / Task 2 Modell installiert): deutsche Anfrage findet thematisch
passendes **englisches** Dokument; Umschalten Exakt/Semantisch/Hybrid ändert Trefferreihenfolge
plausibel; ohne Modell bleibt Exakt nutzbar + Hinweis sichtbar.

- [ ] **Step 5.5: Commit**

```bash
git add Apps
git commit -m "[Add] Phase 4 Schritt 5: Such-UI Hybrid/Exakt/Semantisch + Modell-Status"
```

---

## Task 6: Modell-Lebenszyklus-Feinschliff

**Files:**
- Modify: `Apps/LocalSeek/LlamaEmbeddingProvider.swift` (Freigabe-Timer)
- Modify: `Apps/LocalSeek/IndexService.swift` (Prüfsummen-/Versionslogik)

- [x] **Step 6.1: On-demand-Laden + Freigabe nach Inaktivität**

Im `LlamaEmbeddingProvider`-Actor einen Inaktivitäts-Timer (~2 min) ergänzen: nach letzter
`embed`-Nutzung `unload()` aufrufen, um RAM freizugeben. Nächster `embed`-Aufruf lädt via
`ensureLoaded()` neu. Konkret: `lastUse: ContinuousClock.Instant` setzen; ein `Task`
prüft periodisch und ruft `unload()`, wenn `now - lastUse > .seconds(120)`.

- [x] **Step 6.2: Prüfsumme/Versionierung → Re-Embedding**

Beim Aktivieren (`loadActiveModelIfAvailable`): SHA-256 der GGUF gegen `models.checksum`
vergleichen. Abweichung ⇒ als **andere** `modelId` behandeln (z. B. `name + "-" + checksumPrefix`),
sodass `chunksNeedingEmbedding` für die neue `modelId` alle Chunks als fällig meldet (schrittweises
Re-Embedding). Alte Vektoren bleiben bis zum Überschreiben liegen; optional via `removeEmbeddings`
alter modelId aufräumen (YAGNI: erst wenn Speicher stört).

- [x] **Step 6.3: Dimension-Guard als harter Fehler**

`ensureLoaded()` wirft bereits `dimensionMismatch`, wenn `ls_llama_n_embd != 384`. Sicherstellen,
dass `IndexService` diesen Fehler fängt, `embeddingProvider` auf `nil` setzt und `lastError`
„Modell ungültig (falsche Dimension)" meldet — Hybrid fällt dann lexikalisch zurück.

- [ ] **Step 6.4: Build + manuelle Abnahme**

Run:
```bash
cd "35_IndexSearch/LocalSeek" && xcodegen generate && xcodebuild test -scheme LocalSeek -destination 'platform=macOS' 2>&1 | tail -10
```
Manuelle Abnahme: RAM sinkt nach ~2 min Inaktivität (Activity Monitor); Austausch der GGUF
(anderer Checksum) löst beim nächsten Scan Re-Embedding aus.

- [ ] **Step 6.5: Commit + CLAUDE.md aktualisieren**

```bash
git add Apps CLAUDE.md
git commit -m "[Add] Phase 4 Schritt 6: Modell-Lebenszyklus (Freigabe-Timer, Prüfsumme/Versionierung)"
```

---

## Abnahmekriterium Phase 4 (SPEC §6/§9)

- [ ] Deutschsprachige Anfrage findet thematisch passende **englische** Dokumente (Task 5 manuell).
- [x] Datei umbenannt → keine unnötigen Re-Embeddings (Hash-Stabilität, Task 3-Test).
- [x] Datei/Quelle gelöscht → Metadaten + Volltext + Vektoren entfernt (Cascade, Task 1-Test).
- [ ] Hybride Suche p95 < 1 s bei geladenem Modell (Entwicklungsziel, Task 5 manuell).
- [ ] Kein Auto-Download, kein Netz, keine Inhalte/Pfade/Queries in Logs (SPEC §9, durchgängig).

## Self-Review (durchgeführt)

- **Spec-Abdeckung:** §1 Scope → Tasks 1–5; §2 Grundsatzentscheidungen → Tasks 1/2/4; §3 Komponenten
  (`LlamaBridge`/`EmbeddingProvider`/`VectorStore`/`EmbeddingIndexer`/`HybridSearchEngine`/UI) → Tasks 2/1/3/4/5;
  §4 Migration `v4-vectors` → Task 1; §5 Datenfluss → Tasks 3 (Index) + 4 (Suche); §6 Fehler/Lebenszyklus → Task 6;
  §7 Teststrategie → Fake-Provider (Task 3) + Vector/Indexer/Hybrid-Tests + llama-Integrationstest (Task 2);
  §8 Teilschritt-Schnitt → Tasks 1–6 (1:1); §9 Abnahme → Kriterienliste oben.
- **Abweichungen vom Design (bewusst, oben begründet):** stabiler SHA-256-Hash statt `chunks.textHash`;
  `VectorStore`-Signatur trägt `modelId`/`textHash`; `nearest(to:modelId:limit:)`.
- **Typkonsistenz:** `EmbeddingProvider.dimensions`/`embed(_:kind:)`, `VectorStore.upsert(chunkId:modelId:textHash:embedding:)`/
  `nearest(to:modelId:limit:)`, `VectorMatch.chunkId/score`, `SearchStrategy.{exact,semantic,hybrid}`,
  `StableHash.hex`, `ModelRecord.{modelId,name,dimensions,checksum,active}` durchgängig identisch verwendet.
- **Offener Risikopunkt:** Task 2 ist ein Spike — die exakten llama-API-Namen/Build-Flags stehen erst nach
  Verifikation gegen den gepinnten Release fest. Tasks 1/3/4 sind davon unabhängig (Fake-Provider) und sofort umsetzbar.
