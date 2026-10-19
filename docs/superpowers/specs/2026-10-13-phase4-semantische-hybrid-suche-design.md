# Phase 4 — Semantische Hybrid-Suche (Design)

> Datum: 2026-10-13 · Projekt: LocalSeek · Status: freigegeben, bereit für Implementierungsplan
> Vorbedingung: Phase 1–3 abgenommen (`3ba5daa`), 49 Unit-Tests grün, Working Tree sauber.

## 1. Ziel & Scope

LocalSeek um **semantische Suche** erweitern und mit der bestehenden lexikalischen Suche
(FTS5/BM25 über Dateiname + Inhalt) zu einer **hybriden Suche** fusionieren. Deutschsprachige
Anfragen sollen thematisch passende englische Dokumente finden (cross-lingual Retrieval).
Vollständig lokal, in-process, keine Cloud, kein Python/Ollama/Docker, kein Auto-Download.

**Nicht in Scope** (bleibt Phase 5): sqlite-vec-ANN-Index, Akku-/Thermik-/CPU-Limits,
Crash-Recovery, OneDrive-Placeholder-Logik, globaler Hotkey.

## 2. Grundsatzentscheidungen (mit Begründung)

| Entscheidung | Gewählt | Begründung |
|---|---|---|
| Embedding-Modell | `multilingual-e5-small` (GGUF, 384-dim) | SPEC-treu, retrieval-optimiert, cross-lingual DE↔EN |
| Inferenz-Engine | **llama.cpp statisch gelinkt** (Native-Target, Metal) | In-process, volle Kontrolle, keine externe Runtime |
| Vektor-Speicher/Suche | **Swift Brute-Force (vDSP)** hinter `VectorStore`-Protokoll | Minimales Risiko bei persönlichem Korpus; sqlite-vec (Alpha) später am selben Protokoll nachrüstbar |
| Modelldatei | **außerhalb OneDrive**, App referenziert sie | Vermeidet OneDrive-Sync-Churn (130 MB); SPEC §9 verbietet Auto-Download |
| Ranking | RRF, FTS 0.55 / Vektor 0.45, k=60 | SPEC §6 Ausgangskonfiguration |

Begründung Brute-Force statt sqlite-vec zuerst: sqlite-vec ist v0.1.10-alpha ohne
`Package.swift` und wäre das zweite Build-/Stabilitätsrisiko neben llama.cpp. Bei einem
persönlichen Korpus (zehntausende Chunks) ist ein vDSP-Cosinus-Sweep im zweistelligen
Millisekundenbereich und erfüllt das p95<1s-Ziel. Der `VectorStore`-Adapter erlaubt den
späteren Tausch ohne UI-/Parser-/Ranking-Umbau (SPEC §5).

## 3. Komponenten (alle hinter schmalen Protokollen, isoliert testbar)

### `LlamaBridge` (neues Native-Target, C/C++)
- Eigenes Target in `project.yml`, statisch in `SharedCore` gelinkt.
- Enthält llama.cpp (gepinnter Release). **Exakte Baumechanik** (Quell-Amalgamation vs.
  vorgebautes xcframework) wird in der Planungsphase gegen die reale llama.cpp-Quelle
  verifiziert — keine Vermutung im Design.
- Dünner C-Header für Swift: Modell laden, Text → `[Float]`(384), Modell freigeben.

### `EmbeddingProvider` (Protokoll, SharedCore)
```
enum EmbeddingKind { case query, passage }   // setzt e5-Präfixe query:/passage:
protocol EmbeddingProvider {
    func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]]
}
```
- `LlamaEmbeddingProvider` (als **Actor**): kapselt `LlamaBridge`, serialisiert den nicht
  thread-sicheren llama-Kontext (Swift 6 strict concurrency), lädt Modell on demand, gibt es
  nach Inaktivität frei.

### `VectorStore` (Protokoll, SharedCore)
```
protocol VectorStore {
    func upsert(chunkId: Int64, embedding: [Float]) throws
    func remove(chunkIds: [Int64]) throws
    func nearest(to query: [Float], limit: Int) throws -> [(chunkId: Int64, score: Double)]
}
```
- `BruteForceVectorStore`: liest Vektoren aus `chunk_vectors_v1` (BLOB), Cosinus per
  Accelerate/vDSP. sqlite-vec-Implementierung später am selben Protokoll.

### `EmbeddingIndexer` (SharedCore)
- Analog zum bestehenden `ContentIndexer`. Nimmt Chunks ohne/mit veraltetem Vektor, batcht
  8–16, ruft `EmbeddingProvider.embed(passage:)`, schreibt via `VectorStore.upsert`, stempelt
  `models.active`. Inkrementell über `chunks.textHash` + aktive `modelId`.

### `HybridSearchEngine` (SharedCore)
- Führt lexikalische Suche (`IndexDatabase.searchChunks`) **und** Vektorsuche aus, fusioniert
  per RRF, gruppiert nach Dokument (bester Chunk zuerst).

### UI (`Apps/LocalSeek/Views/SearchView.swift`)
- Modus-Umschalter **Hybrid / Exakt / Semantisch** (SPEC §6). Exakt = heutiges Verhalten.
- Status-Popover zeigt echten `embeddingCount`; Hinweis „Modell nicht geladen" bei Degradation;
  „Modell wählen…"-Aktion (NSOpenPanel), wenn GGUF fehlt.

Bestehende Phase-1–3-Teile (Scanner, Extraktoren, `IndexDatabase`, lexikalische Suche,
Quick Look) bleiben unangetastet; Phase 4 hängt sich nur an `IndexService`, `SearchView` und
einer additiven DB-Migration ein.

## 4. Datenmodell — Migration `v4-vectors` (additiv)

- **`chunk_vectors_v1`**: `chunkId INTEGER PK → chunks.id ON DELETE CASCADE`,
  `embedding BLOB` (384 × Float32 = 1536 Byte, little-endian), `modelId TEXT`, `textHash TEXT`.
  `_v1` kodiert Dimension/Modellfamilie; neue Modellversion ⇒ neue Tabelle (SPEC §5 Regel 6).
- **`models`**: `modelId TEXT PK`, `name`, `dimensions INTEGER`, `checksum TEXT`, `active INTEGER`.
- `chunk_vectors_v1.textHash` spiegelt `chunks.textHash` beim Einbetten → entscheidet, ob ein
  Chunk neu eingebettet werden muss.
- Löschen folgt per FK-Cascade: Datei/Quelle gelöscht → `chunks` weg → `chunk_vectors_v1` weg.

## 5. Datenfluss

### Indizierung (hängt an bestehende Pipeline, niedrige Priorität)
```
Scan → ContentIndexer (Extraktion → chunks)        [Phase 3, unverändert]
         └─► EmbeddingIndexer (NEU):
               filesNeedingEmbedding → Chunks ohne/mit veraltetem Vektor
               → Batch 8–16 → EmbeddingProvider.embed(passage:)
               → VectorStore.upsert → models/active stempeln
```
Läuft als `Task.detached` **nach** der Inhaltsextraktion, verdrahtet in
`IndexService.addSource` und `flushRescans` — analog zur bestehenden `ContentIndexer`-Einbindung.

### Suche
```
Query → QueryParser (bestehend)
  ├─ lexikalisch: searchChunks → Rang-Liste A              [bestehend]
  └─ semantisch:  EmbeddingProvider.embed(query:)
                  → VectorStore.nearest(limit 100) → Rang-Liste B   [NEU]
  → RRF-Fusion (k=60, FTS 0.55 / Vektor 0.45)
  → nach Dokument gruppieren, bester Chunk zuerst
```
- Modus **Exakt** überspringt B; Modus **Semantisch** überspringt A.
- Fehlt Modell / leerer Vektorindex → Hybrid fällt still auf rein lexikalisch zurück
  (SPEC §6: exakte Suche immer verfügbar).

## 6. Fehlerbehandlung & Modell-Lebenszyklus

**Lebenszyklus (`LlamaEmbeddingProvider`-Actor):**
- Auffinden: GGUF unter `~/Library/Application Support/LocalSeek/models/`, Pfad in `settings`.
  Fehlt sie → Status `.modellFehlt`, UI „Modell wählen…" (NSOpenPanel kopiert dorthin).
- Laden on demand (erster Embedding-Bedarf). Freigabe nach Inaktivität (Timer ~2 min) → RAM frei.
- Prüfsumme SHA-256 gegen `models.checksum`; Abweichung ⇒ neue Version ⇒ Vektorindex veraltet ⇒
  Re-Embedding über textHash/modelId-Mismatch.

**Fehlerklassen:**
| Fehler | Verhalten |
|---|---|
| Modelldatei fehlt/korrupt | Embedding-Schritt pausiert; lexikalische Suche voll da; UI-Hinweis + „Modell wählen…" |
| Einzelner Chunk schlägt fehl | überspringen, loggen (ohne Inhalt/Pfad), Lauf läuft weiter |
| Dimension ≠ 384 | harter Fehler beim Laden, Modell verworfen, Status `.modellUngültig` |
| Vektorsuche ohne Modell | Hybrid → nur lexikalisch; Semantisch → leere Liste + Hinweis |
| Modellwechsel mittendrin | neuer `modelId`, alte Vektoren veraltet → schrittweise neu eingebettet |

**Nebenläufigkeit:** llama-Kontext nicht thread-sicher → gesamter Embedding-Zugriff über
Provider-Actor serialisiert. `BruteForceVectorStore`-Lesen über GRDB-Reader-Pool; Schreiben über
den bestehenden Writer — keine neuen Writer-Pfade außerhalb `IndexDatabase`.

**Leitplanken (SPEC §9, dauerhaft):** kein Auto-Download, kein Netz, keine Inhalte/Pfade/Queries
in Logs, nur Lesen von Nutzerdateien.

## 7. Teststrategie

Echte Unit-Tests gegen `SharedCore`, keine Stubs (wie Phase 1–3):
- `VectorStore`: Cosinus-Korrektheit (bekannte Vektoren → bekannter Rang), Upsert/Remove,
  Cascade-Löschung, leerer Index.
- `EmbeddingIndexer`: inkrementell (unverändert → kein Re-Embed; textHash-Änderung → neu;
  Modellwechsel → alles veraltet). **Fake-`EmbeddingProvider`** (deterministische Vektoren),
  kein llama im Unit-Test.
- `HybridSearchEngine`: RRF-Fusion mit konstruierten Rang-Listen, Modi Exakt/Semantisch/Hybrid,
  Fallback bei leerem Vektorindex.
- `LlamaEmbeddingProvider`: separater Integrationstest gegen **Referenz-Embeddings** (SPEC §6),
  `skip` wenn Modell lokal fehlt — nicht im Standard-CI-Lauf blockierend.

## 8. Teilschritt-Schnitt (je Schritt lauffähig + getestet + eigener `[Add]`-Commit)

1. **Schema `v4-vectors` + `VectorStore`-Protokoll + `BruteForceVectorStore` (vDSP)**
   → verify: Vector/Persistence-Tests grün, Cascade verifiziert.
2. **`LlamaBridge`-Native-Target + `EmbeddingProvider` + `LlamaEmbeddingProvider`**
   → verify: Build mit gelinktem llama; Referenz-Embedding-Integrationstest grün (lokal).
3. **`EmbeddingIndexer` + Verdrahtung in `IndexService`** (inkrementell, niedrige Prio)
   → verify: Indexer-Tests mit Fake-Provider grün; echter `embeddingCount` im Status.
4. **`HybridSearchEngine` (RRF)** → verify: Fusions-/Modus-Tests grün.
5. **Such-UI Modus Hybrid/Exakt/Semantisch + Modell-Status/„Modell wählen…" + Degradations-Hinweis**
   → verify: manuelle Abnahme (echte Suche über echten Index).
6. **Modell-Lebenszyklus-Feinschliff** (on-demand laden, Freigabe-Timer, Prüfsumme/Versionierung)
   → verify: RAM nach Inaktivität frei; Modellwechsel löst Re-Embedding aus.

## 9. Abnahmekriterium Phase 4 (SPEC)

- Deutschsprachige Anfrage findet thematisch passende **englische** Dokumente.
- Datei umbenannt → keine unnötigen Re-Embeddings.
- Datei gelöscht → Metadaten + Volltext + Vektoren entfernt.
- Hybride Suche p95 < 1 s bei geladenem Modell (Entwicklungsziel, keine Garantie).
