# CLAUDE.md — LocalSeek

> Lebendes Statusdokument. Wird nach jedem Arbeitsschritt aktualisiert, damit der
> Zwischenstand nach einer Kontext-Komprimierung vollständig rekonstruierbar ist.
> **Letzte Aktualisierung:** 2026-10-16 — **Phase 4 (semantische Hybrid-Suche) code-komplett,
> 72 Tests auf dem neuen Rechner grün, App gebaut & installiert.** Alle 6 Plan-Tasks umgesetzt: Task 1 (Schema
> `v4-vectors` + `StableHash` + `VectorStore`/`BruteForceVectorStore` via vDSP) ✅, Task 2
> (`LlamaBridge` C-Shim über llama.cpp/Metal + `LlamaEmbeddingProvider`-Actor + `ModelLocator`,
> e5-small GGUF 384-dim unter `~/Library/Application Support/LocalSeek/models/` installiert) ✅,
> Task 3 (`EmbeddingIndexer` inkrementell + Verdrahtung in `IndexService`) ✅, Task 4
> (`HybridSearchEngine`: RRF-Fusion + Dokumentgruppierung, lexikalischer Fallback) ✅, Task 5
> (Such-UI Hybrid/Exakt/Semantisch + Modell-Status + „Modell wählen…") ✅, Task 6
> (Modell-Lebenszyklus: Freigabe-Timer nach 120 s Inaktivität, Checksum-Versionierung,
> Dimension-Guard) ✅. Phase 3 funktional vollständig (davor abgenommen).
> **Noch offen:** Abnahme mit realistischem Dokumentbestand und p95 < 1 s;
> DE-Query→EN-Dokument, Startup-Nachlauf und Modellinstallation sind jetzt mit echtem llama.cpp getestet,
> dann Phase 5 (Produktionshärtung) + Carryover-Nacharbeit (Filter-UI, Hotkey ⌘⇧Space,
> `IndexScheduler`/Job-Queue, 12-h-Integritätsabgleich, OneDrive-`unavailable`/Placeholder).

**Rechnerwechsel abgeschlossen (2026-10-16):** Xcode 27.1, Swift 6.4, XcodeGen 2.46.0,
llama.cpp 0.6.0_1, ggml 0.27.0, GRDB 7.11.1 und ZIPFoundation 0.9.20 vorhanden.
72 Tests ohne Fehler oder übersprungene Tests; sauberer Testprozess-Austritt.
Die cstr-F32-Konvertierung (`22b4685acd49…`) ist mit diesem llama.cpp nicht ladbar
(`bert model needs to define token type count`). Stattdessen wurde nach Nutzerfreigabe
die getestete TwinSunsLLC-Q8-Konvertierung installiert (ca. 132 MB, 384 Dimensionen).
Startup-Nachlauf und Modellwechsel erzeugen im Integrationstest je zwei Embeddings;
eine deutsche Rechnungsfrage findet das englische Zahlungsdokument vor dem Gartendokument.
Modellaktivierung prüft Ladefähigkeit/Dimension, verwendet die konkret gewählte Datei,
merkt das aktive Modell in der DB und stößt direkt den Quellenabgleich an. Kopieren und
Checksumme laufen abseits des Main-Actors. Gleiche Quelldatei/Zieldatei wird nicht mehr
gelöscht. Fehler werden in der UI angezeigt; Hybrid behält bei Embedding-Fehlern seine
lexikalischen Treffer. Native Kontexte werden über einen Swift-Eigentümer freigegeben;
Backend-Initialisierung ist über `std::call_once` abgesichert. DIAG-Logging entfernt.
Ein zusätzlicher nativer Abort bei langen Texten wurde isoliert reproduziert und
behoben: Das Q8-GGUF hat `n_ctx_train = 511`, der Shim ließ zuvor 512 Tokens zu.
Kontext, Batch und Tokenlimit verwenden jetzt `min(512, n_ctx_train)`; EOS bleibt
bei Kürzung erhalten, Token-IDs und endliche, nichtleere Vektoren werden geprüft.
Regressionstest umfasst lange Passage, lange Query und anschließende kurze Query.
Die installierte App läuft unter `~/Applications/LocalSeek.app`; das aktive Q8-Modell
ist in ihrer tatsächlichen DB bestätigt. Der vom Nutzer gewählte Ordner enthält aktuell
**5 Dateien, 16 Chunks und 16 Embeddings**, Quellenstatus `idle` — auch der Live-Nachlauf
funktioniert mit dem korrigierten Modelllimit. Der historische 152-Chunk-Index wurde nicht übertragen,
die ursprüngliche Fehlerursache auf dem alten Rechner ist daher nicht abschließend bewiesen.
Aktuelle Setup-Prüfung:
[`HANDOFF/SETUP-2026-10-16.md`](HANDOFF/SETUP-2026-10-16.md).

## Was ist LocalSeek?

Vollständig lokale, native **macOS-Hybrid-Suchmaschine** (Dateiname + Volltext + semantisch).
Indiziert OneDrive-/lokale Ordner im Hintergrund, durchsuchbar offline. Kein Server,
kein Docker, keine Cloud-API, kein Python. **Ein-Prozess-Architektur:** `LocalSeek.app`
(SwiftUI MenuBar-UI) führt die Indizierung **in-process** aus (`IndexService`). Kein
separater LaunchAgent, kein XPC, keine App Sandbox.

Die verbindliche Produktspezifikation liegt in `SPEC.md`. Umgesetzt wird in **5 Phasen**,
jede als lauffähige, getestete Version — keine Stubs.

## Architektur-Pivot (2026-10-11) — WICHTIG

Ursprünglich geplant: Zwei Prozesse (App + `LocalSeekAgent`-LaunchAgent) über XPC, mit
App Sandbox + Security-Scoped Bookmarks. **Blocker:** Ein ad-hoc-signierter
`SMAppService.agent`-LaunchAgent scheitert an macOS Launch Constraints
(OS_REASON_CODESIGNING / Launch Constraint Violation) — unlösbar ohne Developer-ID-Signatur.

**Entscheidung (vom Nutzer bestätigt): „Sandbox raus, 1 Prozess".** App Sandbox ist nur
für den App-Store-Vertrieb nötig; für ein selbstgebautes persönliches Werkzeug erzeugt
sie nur Komplexität. Daher:
- Separater `LocalSeekAgent`, XPC-Protokoll, `NSXPCListener/Connection` → **entfernt**.
- App Sandbox + Security-Scoped Bookmarks → **entfernt**.
- Indizierung läuft in-process in `IndexService` (`@MainActor` ObservableObject + `Task.detached`).
- Autostart via `SMAppService.mainApp` (statt `.agent`).
- DTOs sind jetzt schlanke `Sendable`/`Equatable`-Structs (kein NSSecureCoding mehr).

Alle Datenschutz-/Sicherheitsleitplanken (SPEC §9/§14) bleiben unverändert gültig.

## Ursprünglich verifizierte Umgebung (bisheriger Rechner; neuer Stand siehe oben)

| Komponente | Status |
|---|---|
| macOS 27.0.1, Apple M5 Pro, Metal 4, arm64 | ✅ |
| Xcode 27.0 (`xcodebuild` aktiv), Swift 6.4, macOS 27 SDK | ✅ |
| SQLite 3.54 **mit FTS5** (C-Probe `rc=0`) | ✅ |
| GRDB.swift 7.11.1 (SPM, MIT) — DatabasePool, FTS5, Trigram | ✅ (in Phase 2 integriert) |
| Homebrew 7.0.8, XcodeGen 2.46.0 | ✅ |
| llama.cpp (brew, `-lllama`, rpath `/opt/homebrew/lib`), e5-small GGUF (476 MB, installiert) | ✅ (Phase 4 integriert) |
| `sqlite-vec` **nicht verwendet** — stattdessen `BruteForceVectorStore` (vDSP-Cosinus über Float32-BLOBs) | ✅ (bewusste Abweichung, austauschbare `VectorStore`-Signatur) |

### Verifizierte APIs / Entscheidungen
- `SMAppService.mainApp`, `.register()`/`.unregister()` (throwing), `.status`
  → `.notRegistered|.enabled|.requiresApproval|.notFound`; `SMAppService.openSystemSettingsLoginItems()`.
- `NSOpenPanel` → direkter Ordnerzugriff über TCC (keine Sandbox, keine Bookmarks nötig).
- GRDB 7 hat **keinen** fertigen `.trigram()`-Deskriptor → `FTS5TokenizerDescriptor(components: ["trigram"])`
  (trigram ist ein in SQLite-FTS5 eingebauter Tokenizer, direkt konstruiert).
- FSEvents via `FSEventStreamCreate` mit `kFSEventStreamCreateFlagFileEvents|NoDefer|UseCFTypes`,
  Callback liefert CFArray der Pfade (`unsafeBitCast` → `NSArray` → `[String]`).

## Build & Verifikation

```bash
cd "<REPOSITORY_ROOT>"
xcodegen generate                                                # .xcodeproj aus project.yml
xcodebuild -scheme LocalSeek -configuration Debug build          # baut App + SharedCore
xcodebuild test -scheme LocalSeek -destination 'platform=macOS'  # 72 Tests, inkl. lokalem Echt-Modell
```

Installation (ohne Admin): alten Prozess beenden, Bundle nach `~/Applications/` kopieren, starten:
```bash
pkill -x LocalSeek; sleep 1
BUILT="$HOME/Library/Developer/Xcode/DerivedData/LocalSeek-gokdodeivaohebeizzrxekjxnybh/Build/Products/Debug/LocalSeek.app"
rm -rf ~/Applications/LocalSeek.app && cp -R "$BUILT" ~/Applications/LocalSeek.app && open ~/Applications/LocalSeek.app
```

## Phasenplan & Fortschritt

- **Phase 1 — Grundgerüst (App + In-Process-Index + Ordnerzugriff)** — ✅ **abgenommen.**
- **Phase 2 — Dateiname-/Metadatensuche** — ✅ **abgenommen** (siehe Detail unten), committet `ef62bcb`.
- **Phase 3 — Volltext + OCR** — ✅ **funktional abgeschlossen.** Schritt 1 (Schema v2 + Chunk-Persistenz + BM25-Suche) ✅,
  Schritt 2 (Extraktor-Architektur + PlainText/CSV/Markdown) ✅, Schritt 3a (PDF via PDFKit) ✅,
  Schritt 3b (OOXML DOCX/PPTX/XLSX via ZIPFoundation) ✅,
  Schritt 4 (Segment→Chunk-Verdrahtung im Scan via `ContentIndexer`, inkrementell) ✅,
  Schritt 5 (Such-UI: Modusumschalter Dateien/Inhalt, markierte Snippets + Fundstellen) ✅,
  Schritt 6 (Vision OCR: `ImageOCRExtractor` für Rasterbilder + OCR-Fallback für Scan-PDF-Seiten) ✅,
  Schritt 7 (Suchsyntax-Parser `QueryParser`: Phrasen `"…"`, Filter `ext:`/`type:`/`path:`/`after:`/`before:`, in `searchChunks` verdrahtet) ✅,
  Schritt 8 (Quick-Look-Vorschau: `QLPreviewView` im SwiftUI-Sheet, Auslösung per Leertaste + Kontextmenü „Vorschau") ✅.
- **Phase 4 — Semantische Hybrid-Suche** — ✅ **code-komplett, 72 Tests grün** (Bestands-/Performance-Abnahme offen).
  Alle 6 Plan-Tasks umgesetzt (Plan: `docs/superpowers/plans/2026-10-14-phase4-semantische-hybrid-suche.md`):
  Task 1 (Migration `v4-vectors` + `StableHash` + `VectorStore`/`BruteForceVectorStore` via vDSP) ✅,
  Task 2 (`LlamaBridge` C-Shim über llama.cpp/Metal + `LlamaEmbeddingProvider`-Actor + `ModelLocator`; e5-small GGUF installiert) ✅,
  Task 3 (`EmbeddingIndexer` inkrementell über `StableHash`, verdrahtet in `IndexService`) ✅,
  Task 4 (`HybridSearchEngine`: RRF-Fusion `fts 0.55`/`vec 0.45`/`k 60` + Dokumentgruppierung, lexikalischer Fallback) ✅,
  Task 5 (Such-UI Hybrid/Exakt/Semantisch + Modell-Status + „Modell wählen…") ✅,
  Task 6 (Freigabe-Timer 120 s, Checksum-Versionierung `name-checksumPrefix`, Dimension-Guard) ✅.
  **Verifiziert:** automatisierte Echt-llama-Tests für DE→EN, Startup-Nachlauf und Modellinstallation.
  **Offen:** Abnahme mit realistischem Dokumentbestand und p95 < 1 s.
- Phase 5 — Produktionshärtung (Energie/CPU/Thermal-Limits, Crash-Recovery/Indexintegrität, OneDrive-Placeholder+Offline, Benchmarks, Packaging/Signierung) — **noch nicht begonnen.**

**Carryover-Nacharbeit (noch offen, phasenübergreifend):** Filter-UI (Typ/Datum/Größe/Quelle),
globaler Hotkey `⌘⇧Space`, formale Job-Queue/`IndexScheduler`, 12-h-Integritätsabgleich,
OneDrive-`unavailable`/Placeholder-Logik (`NSFileCoordinator`).

### Phase-2-Fortschritt (detailliert, in Teilschritten geliefert)

| Schritt | Status |
|---|---|
| 1. GRDB + DB-Schema (`sources`, `files`, Trigram-`filename_fts`) + Migrationen | ✅ fertig |
| 2. Rekursiver `DirectoryScanner` → DB füllen (Batch-Upsert, Reconcile) | ✅ fertig |
| 3. Such-UI: Suchfenster, entprellte Live-FTS-Suche, Öffnen/Finder/Pfad kopieren | ✅ fertig — Dateinamensuche interaktiv verifiziert |
| 4. FSEvents-Live-Updates (entprellt, inkl. Lösch-Reconcile) | ✅ fertig |

**Noch offen (Nacharbeit / in Phase 3 mitnehmen):** Filter (Typ/Datum/Größe/Quelle),
globaler Hotkey `⌘⇧Space`, formale Job-Queue/`IndexScheduler`, Integritätsabgleich alle 12 h,
OneDrive-`unavailable`-Zustandslogik. **Volltext *innerhalb* von Dateien = bewusst Phase 3.**

### Verifizierter Build-/Teststand (2026-10-11)
- `xcodebuild build` (Scheme LocalSeek): **BUILD SUCCEEDED** (Swift 6 strict concurrency, complete).
- `xcodebuild test`: **12/12 grün** = 4 DTO + 5 Persistence + 3 Scanner.
- Installiert nach `~/Applications/LocalSeek.app`, läuft als MenuBar-Prozess.
- Nutzer-Rückmeldung: „filename suchen klappt, content darin noch nicht" → erwartungsgemäß (Content = Phase 3).

## Datenmodell (Ist-Zustand, Phase 2)

GRDB `DatabasePool` (WAL, Foreign Keys an) unter `~/Library/Application Support/LocalSeek/index.sqlite`.
Migration `v1-metadata`:
- `sources(id TEXT PK, path TEXT UNIQUE, enabled, scanStatus, lastScan)` — `id == path`.
- `files(id INTEGER PK, sourceId→sources ON DELETE CASCADE, relativePath, filename, fileExtension,
  size, mtime, state DEFAULT 'present')`, Unique `(sourceId, relativePath)`.
- `filename_fts` = FTS5 **Trigram**, `synchronize(withTable: "files")` (Auto-Trigger), Spalten `filename`, `relativePath`.

> **Spaltennamen bewusst camelCase** (GRDB-idiomatisch), abweichend vom snake_case im logischen
> Modell der SPEC §5 — rein kosmetisch, dokumentiert in SPEC-Umsetzungsnotiz.

### Phase-3-Erweiterung (Migration `v2-content`, Schritt 1)

- `chunks(id INTEGER PK, fileId→files ON DELETE CASCADE, ordinal, text, locationType, locationValue,
  textHash, tokenCount)`, Unique `(fileId, ordinal)` — maßgebliche Quelle des extrahierten Textes.
  `locationType`/`locationValue` lokalisieren die Fundstelle (page/„3", slide/„5", sheet/„Tabelle1!A1", section/…).
- `chunk_fts` = **eigenständige** FTS5-Tabelle (nicht `synchronize`), Spalten `text`, `filename`, `path`,
  Tokenizer `unicode61` **`remove_diacritics 2`** (umlauttolerant: „fur"≈„für"). `filename`/`path` werden
  aus `files` denormalisiert beim Chunk-Insert eingefüllt; `rowid == chunks.id`.
- Trigger `chunks_after_delete`: entfernt die FTS-Zeile beim Chunk-Delete — greift auch bei
  **FK-Cascade** (Datei/Quelle gelöscht) und bei `replaceChunks` (Delete-dann-Insert). Per Test verifiziert.
- Persistenz-API (`IndexDatabase`): `replaceChunks(fileId:chunks:)` (ersetzt alle Chunks einer Datei),
  `chunkCount()`, `searchChunks(_:limit:)` → `[ContentSearchHit]` (Datei + Fundstelle + markiertes
  `snippet()` + `bm25()`-Score, `ORDER BY bm25`). `searchChunks` parst die Eingabe über `QueryParser`
  zu einem typisierten `ParsedQuery` (Phrasen `"…"`, freie Tokens = AND, Filter `ext:`/`type:`→`fileExtension`,
  `path:`→`relativePath LIKE`, `after:`/`before:`→`mtime`). Der FTS5-Ausdruck wird aus sanitisierten
  `FTS5Pattern`-Teilen zusammengesetzt, Filter als gebundene Parameter — nie roher Nutzertext in SQL/FTS5
  (SPEC §7). FTS5 ist **tokenbasiert** (ganze Wörter, kein Substring —
  Substring bleibt Aufgabe des Trigram-`filename_fts`). `IndexService.reload()` meldet jetzt echten `chunkCount`.

### Phase-3-Erweiterung (Migration `v3-content-tracking` + `ContentIndexer`, Schritt 4)

- `files.contentMtime` (DATETIME, nullable): `mtime`-Stand der letzten Inhaltsextraktion. Vom Metadaten-Upsert
  **nicht** angetastet (nicht in INSERT-/ON-CONFLICT-Spalten), bleibt also über Rescans erhalten.
- `filesNeedingContentExtraction(sourceId:extensions:)`: liefert vorhandene, **extrahierbare** Dateien
  (`fileExtension IN …` = Registry-Endungen) mit `contentMtime IS NULL OR contentMtime <> mtime` → neu/geändert.
- `markContentIndexed(fileId:mtime:)`: stempelt nach erfolgreicher Extraktion (bei fehlendem `mtime`
  Epoch-Sentinel, um Dauer-Re-Extraktion zu vermeiden).
- `ContentIndexer` (SharedCore): orchestriert pro Quelle Extraktion→`replaceChunks`→Stempel. Übergroße
  Dateien (> `ExtractionContext.maxBytes`) werden mit leerem Inhalt übersprungen (SPEC §8). Fehler einer
  Datei brechen den Lauf nicht ab (leerer Inhalt + Stempel). Verdrahtet in `IndexService.addSource`
  **und** `flushRescans` (nach `scanner.scan`).

**Suche** (`searchFilenames`): ab 3 Zeichen Trigram-FTS5 (`MATCH`, Substring/Everything-Stil),
darunter `LIKE '%…%' ESCAPE '\'`-Fallback; immer `state != 'deleted'`, `LIMIT 200`.
**Reconcile** (`reconcileSource`): nach jedem Scan werden Dateien gelöscht, deren relativer Pfad
nicht mehr gesehen wurde (Temp-Tabelle `_seen` + `DELETE … NOT IN`), FTS folgt per Trigger.

## Live-Updates (FSEvents)

`FSEventsWatcher` (SharedCore, `@unchecked Sendable`) beobachtet alle Quell-Wurzelpfade auf
eigener DispatchQueue. `IndexService` ordnet geänderte Pfade ihren Quellen zu (Prefix-Match
`== root || hasPrefix(root + "/")`), sammelt betroffene Quellen und startet nach **0,8 s
Entprellung** (`debounceTask`) einen vollständigen Metadaten-Rescan je betroffener Quelle
(`Task.detached`), danach `reload()`. Watcher wird bei `init`, `addSource`, `removeSource` neu gestartet.

## Dateistruktur (Ist-Zustand)

```
LocalSeek/
├── .gitignore                     (.xcodeproj + DerivedData ignoriert)
├── CLAUDE.md                      (dieses Dokument — lebender Zwischenstand)
├── SPEC.md                        ✅ Produktspezifikation (15 §) + Architektur-/Phase-2-Abweichungen
├── project.yml                    ✅ XcodeGen (SharedCore-Framework + App + Tests, GRDB-Package)
├── Shared/                        → SharedCore-Framework
│   ├── Models/DTOs.swift          ✅ SourceState, SourceStatusDTO, IndexStatusDTO (Sendable)
│   ├── Core/
│   │   ├── DirectoryScanner.swift ✅ rekursiv, Batch-Upsert, seen-Set + reconcile
│   │   ├── FSEventsWatcher.swift  ✅ FSEvents-Stream → onChange([String])
│   │   ├── StableHash.swift       ✅ SHA-256-Hex (CryptoKit) — lauf-stabiler Textschlüssel (Phase 4)
│   │   ├── Embedding/             → Semantik (Phase 4)
│   │   │   ├── EmbeddingProvider.swift ✅ EmbeddingKind(query/passage) + Protokoll + EmbeddingError
│   │   │   └── EmbeddingIndexer.swift  ✅ fällige Chunks→Vektor, inkrementell über StableHash, Batch 16
│   │   ├── Search/
│   │   │   ├── QueryParser.swift  ✅ ParsedQuery + QueryParser.parse (Phrasen, ext/type/path/after/before)
│   │   │   ├── VectorStore.swift  ✅ Protokoll + VectorBlob(Float32-LE-Codec) + BruteForceVectorStore (vDSP-Cosinus)
│   │   │   └── HybridSearchEngine.swift ✅ RRF-Fusion + Dokumentgruppierung, lexikalischer Fallback (Phase 4)
│   │   └── Extraction/            → Dokumentenextraktion (Phase 3)
│   │       ├── DocumentExtractor.swift ✅ Protokoll + ExtractedDocument/Segment/Location/Kind/Context/Registry
│   │       ├── PlainTextExtractor.swift ✅ TXT/LOG/JSON/XML/YAML → 1 Body-Segment
│   │       ├── CSVExtractor.swift       ✅ CSV/TSV, RFC-4180-naher Parser → Table-Segment
│   │       ├── MarkdownExtractor.swift  ✅ MD, Split an ATX-Überschriften → Heading/Body-Segmente
│   │       ├── PDFExtractor.swift       ✅ PDFKit, seitenweise → Body-Segment je Seite (.page(n))
│   │       ├── OOXMLExtractors.swift    ✅ DOCX/PPTX/XLSX via ZIPFoundation + XMLParser (SAX)
│   │       ├── OCRService.swift         ✅ Vision-Wrapper (VNRecognizeTextRequest, de/en, synchron)
│   │       ├── ImageOCRExtractor.swift  ✅ Rasterbilder (png/jpg/tiff/heic/…) via ImageIO → OCR-Body
│   │       └── ContentIndexer.swift     ✅ Scan→Extraktion→Chunks, inkrementell über files.contentMtime
│   └── Persistence/
│       ├── Records.swift          ✅ SourceRecord, FileRecord, ChunkRecord, ModelRecord (GRDB)
│       └── IndexDatabase.swift    ✅ Pool, Migration v1–v4, upsert/search/reconcile/counts + Vektor-/Modell-APIs
├── LlamaBridge/                   → statisches C/C++-Target über llama.cpp (Phase 4)
│   ├── include/localseek_llama.h  ✅ schmaler C-Shim: ls_llama_load/free/n_embd/embed (L2-normiert)
│   ├── include/module.modulemap   ✅ Modul für Swift-Import
│   └── src/localseek_llama.cpp    ✅ llama.cpp/Metal-Aufruf (mean-pooling, embeddings=true)
├── Apps/LocalSeek/
│   ├── LocalSeekApp.swift         ✅ @main, MenuBarExtra + Window("search") + Settings, LoginItemManager
│   ├── IndexService.swift         ✅ In-Process-Index (@MainActor), Scan + Live-Updates + Suche + Embedding-Verdrahtung
│   ├── LlamaEmbeddingProvider.swift ✅ Actor um LlamaBridge, e5-Präfixe, On-demand-Laden + Freigabe-Timer (120 s)
│   ├── ModelLocator.swift         ✅ GGUF finden/installieren in App Support/models, SHA-256-Prüfsumme (kein Auto-Download)
│   └── Views/
│       ├── StatusView.swift       ✅ MenuBar-Popover: Status, Quellen, „Suchen…", Einstellungen, Beenden
│       ├── SearchView.swift       ✅ Modus Dateien/Inhalt + Submodus Hybrid/Exakt/Semantisch; Snippet+Fundstelle; Quick-Look-Vorschau
│       ├── QuickLookView.swift     ✅ NSViewRepresentable um QLPreviewView (native Vorschau im Sheet)
│       └── SettingsView.swift      ✅ Allgemein (Login) + Quellen (hinzufügen/entfernen)
└── Tests/UnitTests/               (72 Tests grün, inkl. App-/Echt-Modell-Integration)
    ├── DTOCodingTests.swift       ✅ 4 Tests
    ├── PersistenceTests.swift     ✅ 5 Tests (Migration, Upsert, Trigram, LIKE-Fallback, Leer)
    ├── ScannerTests.swift         ✅ 3 Tests (rekursiv, idempotent, Lösch-Reconcile)
    ├── ContentPersistenceTests.swift ✅ 5 Tests (Schema v2, Suche+Snippet, Diakritika, idempotent, Cascade)
    ├── ExtractionTests.swift      ✅ 8 Tests (PlainText, Encoding-Fallback, CSV/TSV-Quotes, Markdown, Registry, Location)
    ├── PDFExtractionTests.swift   ✅ 3 Tests (seitenweise, leere Seite übersprungen, unlesbar wirft)
    ├── OOXMLExtractionTests.swift ✅ 5 Tests (DOCX-Absätze, PPTX-Folienreihenfolge, XLSX SharedStrings+Range, fehlender Part)
    ├── OCRExtractionTests.swift   ✅ 3 Tests (Bild-OCR, Registry→png/jpeg, Scan-PDF-Seite OCR'd)
    ├── QueryParserTests.swift     ✅ 10 Tests (Phrasen, ext/type/path, Datum, gemischt, Filter in searchChunks)
    ├── ContentIndexerTests.swift  ✅ 4 Tests (Scan→Suche, kein Re-Index unverändert, Re-Index bei Änderung, Unsupported übersprungen)
    ├── StableHashTests.swift      ✅ 1 Test (deterministisch, groß-/kleinschreibungssensitiv, 64 Hex)
    ├── VectorStoreTests.swift     ✅ 5 Tests (BLOB-Roundtrip, Cosinus-Ranking, Modell-Scoping, Cascade, inkrementell)
    ├── EmbeddingIndexerTests.swift ✅ 3 Tests (alle fälligen eingebettet, kein Re-Embed unverändert, Modellwechsel re-embedded)
    ├── HybridSearchEngineTests.swift ✅ 3 Tests (RRF-Konsens, lexikalischer Fallback ohne Provider, Semantik+Dokumentgruppierung)
    └── FakeEmbeddingProvider.swift   (Test-Helfer: deterministischer Provider, kein llama)

> **Neue Tests:** `ModelLocatorTests.swift` (4: Auswahl, Selbstkopie, fehlgeschlagener
> Austausch, erfolgreicher Austausch), `RealEmbeddingTests.swift` (5: echte normierte,
> deterministische DE→EN-Vektoren, Startup-Nachlauf, sofortige Einbettung nach Installation,
> sichtbarer Ladefehler + weiterhin nutzbare exakte Suche, lange Texte + Kontextwiederverwendung). Ein weiterer Hybrid-Test prüft
> den lexikalischen Fallback bei Inferenz-/Modellfehler. Echt-Modell-Tests überspringen
> bei fehlendem lokalem Q8-Modell; optional `LOCALSEEK_TEST_MODEL` setzen. Auf diesem
> Rechner wurden alle fünf ausgeführt.
```

> **Vollständige Spezifikation:** siehe `SPEC.md`. Dieses CLAUDE.md ist der Zwischenstand.

## Sicherheitsleitplanken (Spec §9, gelten dauerhaft)

- Keine Cloud-API, keine Telemetrie, kein offener HTTP-Port, kein Auto-Download von Modellen.
- Keine Dokumentinhalte/Pfade/Suchanfragen in Logs.
- Nur Benutzerkontext, kein Root. Keine stille Ausweitung von Dateisystemrechten.
- Der Indexer verändert/verschiebt/löscht nie eine Datei (nur Lesen).
- Keine Scheinimplementierungen / hartcodierten Ergebnisse / funktionslosen Buttons.
