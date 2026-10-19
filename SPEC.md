# LocalSeek — Vollständige Architektur-Spezifikation (verbindlich)

> Dies ist die **verbindliche technische Produktspezifikation** für LocalSeek,
> wortgetreu aus dem ursprünglichen Auftrag übernommen. Bei Abweichungen gilt:
> nur mit dokumentierter technischer Begründung abweichen.
> Siehe `CLAUDE.md` für den aktuellen Umsetzungs-/Fortschrittsstand.

> **Architektur-Abweichung (2026-10-11, vom Nutzer bestätigt):** Weg von der ursprünglich
> geplanten **Zwei-Prozess-Architektur** (App + separater `LocalSeekAgent`-LaunchAgent,
> gekoppelt über XPC) hin zu **einem einzigen Prozess**: Die Indizierung läuft in-process
> in der MenuBar-App. Zusätzlich wird die **App Sandbox entfernt** und damit entfallen die
> Security-Scoped Bookmarks; Ordnerzugriff erfolgt direkt über TCC-Nutzerfreigaben.
> **Begründung:** Ein ad-hoc-signierter `SMAppService.agent`-LaunchAgent scheitert an macOS
> Launch Constraints (OS_REASON_CODESIGNING), und App Sandbox ist nur für den App-Store-Vertrieb
> nötig — für ein selbstgebautes, persönliches Werkzeug erzeugt sie nur Komplexität ohne Nutzen.
> Alle Datenschutz-/Sicherheitsleitplanken aus §9/§14 bleiben unverändert gültig (keine Cloud,
> keine Telemetrie, kein offener Port, nur freigegebene Ordner, kein Root).
> Die betroffenen Abschnitte unten (§1, §2, §9, §10, §11, §13, §14) sind entsprechend angepasst;
> alle funktionalen Anforderungen (Pipeline, Extraktion, Suche, Ranking) bleiben unberührt.

> **OCR-Ausnahme (2026-10-18, Fehlerbehebung im Nutzerauftrag):** Ein blockiertes
> `VNImageRequestHandler.perform` darf den einzigen Indexer-Worker nicht festhalten.
> Vision läuft deshalb in einem eingebetteten, kurzlebigen `LocalSeekOCR`-Hilfsprozess.
> Die App beendet diesen bei Timeout (30 s je Bild/Scan-Seite) oder Abbruch.
> Ein eigener Watchdog begrenzt auch verwaiste Helper. Kein LaunchAgent, XPC-Dienst,
> Netzwerk oder separater Installationsschritt; Queue und Datenbank bleiben in der App.

> **Umsetzungsnotiz Phase 2 (2026-10-11, dokumentierte Abweichungen):**
> - **DB-Spaltennamen** sind GRDB-idiomatisch camelCase (`sourceId`, `relativePath`, `fileExtension`,
>   `scanStatus`, `lastScan`) statt des snake_case im logischen Modell (§5) — rein kosmetisch.
> - Bisher existieren nur die für die Dateinamensuche nötigen Tabellen `sources`, `files` und
>   die Trigram-FTS5-Tabelle `filename_fts`; `chunks`/`chunk_fts`/`chunk_vectors_v1`/`jobs`/
>   `models` folgen in Phase 3/4.
> - **Keine formale Job-Queue/`IndexScheduler` in Phase 2** — der Metadaten-Scan läuft direkt in
>   `Task.detached`-Hintergrund-Tasks. Die Queue/Scheduler-Infrastruktur kommt mit Phase 3/4,
>   wenn Extraktion/OCR/Embeddings Priorisierung brauchen.
> - **Live-Updates:** FSEvents mit Kernel-Latency 0,5 s + zusätzlicher 0,8 s App-Entprellung
>   (statt der 2 s aus §3.2/§8). Eine Änderung in einer Quelle löst einen **vollständigen
>   Metadaten-Rescan dieser Quelle** aus (inkl. Reconcile: nicht mehr vorhandene Dateien werden
>   gelöscht) — konform zu §3.2 „vollständiger Abgleich der betroffenen Quelle". Inkrementelle
>   Teilschritte folgen, sobald Inhalts-/Embedding-Jobs existieren.

> **v1-Umsetzungsnotiz (2026-10-16):** Die Phase-2-Zwischenstände oben sind historisch.
> Schema/Queue/Integritätsprüfung/Filter/Hotkey sind inzwischen implementiert.
> Parser laufen synchron in Hintergrundtasks, damit koordinierte Reads innerhalb des
> gültigen Accessors bleiben. Ein aktiver Hintergrundjob und Einzel-Embeddings begrenzen
> Ressourcen und ermöglichen Checkpoints; native CPU-Inferenz hat zwei Threads.
> Vektoren werden per Accelerate/vDSP gestreamt statt mit sqlite-vec; der Store ist austauschbar.
> Das getestete GGUF hat 511 Positionen, die Chunkgrenze berücksichtigt diese Metadaten.
> Fertige Pakete enthalten statisches llama/ggml, Metal-Library und das geprüfte Modell.
> Begründungen/Nachweise und externe Abnahmegrenzen: README, CLAUDE und HANDOFF/FINAL-VALIDATION.

## Ziel

Eine eigenständige **macOS-App**, die OneDrive-Ordner und lokale Dateien automatisch
im Hintergrund indiziert und anschließend **Dateinamen-, Volltext- und semantische
KI-Suche** kombiniert. Verhalten wie Mischung aus Everything + Spotlight + lokaler
KI-Suchmaschine. **100 % kostenlos, offline-first.** Kein Server, kein Docker, kein
Ollama, keine Cloud-DB, keine kostenpflichtige API.

## 1. Technologische Grundentscheidung

| Bereich | Technologie | Entscheidung |
|---|---|---|
| Programmiersprache | Swift 6 | Native macOS-Entwicklung |
| Benutzeroberfläche | SwiftUI + AppKit | Menüleiste, Suchfenster, Einstellungen |
| Hintergrundbetrieb | MenuBar-App (LSUIElement), In-Process-Indizierung | Läuft fensterlos weiter; Autostart via `SMAppService.mainApp` |
| Dateisystemüberwachung | FSEvents | Änderungen effizient erkennen |
| Datenbank | SQLite | Lokal, ohne Server |
| Volltextsuche | SQLite FTS5 | BM25, Phrasen, Präfixe |
| Vektorsuche | sqlite-vec | Lokale semantische Suche |
| KI-Inferenz | llama.cpp mit Metal | Embeddings auf Apple Silicon |
| Embedding-Modell | multilingual-e5-small | DE+EN, 384 Dimensionen |
| Office-Dateien | ZIPFoundation + XMLParser | DOCX, PPTX, XLSX |
| PDF und OCR | PDFKit + Apple Vision | PDF-Textextraktion + lokale OCR |
| Dokumentvorschau | Quick Look + PDFKit | Originaldateien anzeigen |
| Abhängigkeiten | Swift Package Manager | Reproduzierbare Builds |

Begründung gegen Alternativen: Python → Packaging-/Größenproblem; Rust → zusätzliche
Sprachgrenze ohne Mehrwert für v1; Electron → unnötiger Chromium-Prozess im Dauerbetrieb.

## 2. Gesamtarchitektur — App mit begrenztem OCR-Hilfsprozess

> **Abweichung von der ursprünglichen Zwei-Prozess-Planung** (siehe Hinweis am Dokumentanfang).

**LocalSeek.app** ist der dauerhafte Prozess: eine MenuBar-App (`LSUIElement`) mit Suchfenster,
Einstellungen und Dokumentvorschau; die gesamte Indizierungslogik (Scannen, Textextraktion,
Embeddings, DB, Ranking) läuft **in-process** in Hintergrund-Tasks (`Task.detached`,
dedizierte Actors). Nur Vision-OCR läuft in einem zeitlich begrenzten Kindprozess
(siehe OCR-Ausnahme oben). Kein separater LaunchAgent, kein XPC, kein HTTP-Port.

Die App läuft fensterlos weiter, wenn das Suchfenster geschlossen ist (MenuBar-Prozess);
Autostart beim Login via `SMAppService.mainApp` (nach Nutzergenehmigung). Die DB wird
ausschließlich von einem internen Writer-Actor beschrieben; die UI liest über denselben
Prozess (kein IPC nötig).

Verantwortlichkeiten (logisch getrennt, aber im selben Prozess):
- **UI-Schicht**: Sucheingabe, Ergebnisanzeige, Vorschau, Quellenverwaltung.
- **Index-Schicht** (`IndexService` + spätere Scanner/Extractor/Scheduler): Scannen,
  Änderungen erfassen, Textextraktion, OCR, Embeddings, DB, Ranking.
- `SharedCore`: gemeinsame Datenmodelle, Suchprotokolle, Fehlercodes, Konfiguration.

Für v1 reicht der Benutzerkontext; kein privilegierter System-Daemon.

## 3. Dateierfassung und kontinuierliche Indizierung

### 3.1 Konfigurierbare Quellen
Beliebig viele Quellordner (OneDrive, Documents, Desktop, Downloads, manuelle, externe).
App darf NICHT eigenmächtig System-/Unternehmensverzeichnisse indizieren — Quellen
werden ausdrücklich über UI hinzugefügt.

Pro-Quelle-Einstellungen (Standardwerte):
| Einstellung | Standard |
|---|---|
| Unterordner einbeziehen | Ja |
| Dateinamen indizieren | Ja |
| Dokumentinhalt indizieren | Ja, soweit lokal verfügbar |
| Semantische Suche | Ja |
| OCR verwenden | Ja, bei geeigneten Dokumenten |
| Versteckte Dateien | Nein |
| Temp. Office-Dateien ignorieren | Ja |
| Maximale Dateigröße | 100 MB, konfigurierbar |
| Cloud-Dateien automatisch herunterladen | Nein |
| Ausschlussmuster | Konfigurierbar |
| Indizierung pausieren | Möglich |

Quellen jederzeit entfernbar inkl. Inhalte/Metadaten/Vektoren.

### 3.2 Indizierungspipeline
1. Discovery → 2. Metadata → 3. Extraction → 4. Chunking → 5. Embeddings → 6. Commit.

Vorgaben:
- Initialer Scan rekursiv → zuerst schneller Dateinamen-/Metadatenindex.
- Textextraktion/OCR/Embeddings nachgelagert.
- Dateiänderungen via FSEvents, entprellt (~2 s).
- Bei verlorenen Events: vollständiger Abgleich der betroffenen Quelle (Apple-Vorgabe).
- Regelmäßiger Integritätsabgleich, Standard alle 12 h.
- Der Indexer darf keine Datei verändern/verschieben/löschen.
- Inhaltsänderung löst nur nötige Schritte neu aus.
- Während Verarbeitung geänderte Dokumente werden neu eingeplant.
- Fehlgeschlagene Jobs: begrenzte Retries + exponentielles Backoff.
- **Nicht erreichbare Quelle** (externes Laufwerk, OneDrive offline): als `unavailable`
  markieren, NICHT löschen. Nur bestätigte Löschung in erfolgreich gescannter Quelle
  entfernt aus Index.

### 3.3 Besonderheit OneDrive (File-Provider)
Nicht jede sichtbare Datei ist lokal. Drei Zustände:
| Zustand | Indizierung |
|---|---|
| Vollständig lokal | Dateiname, Metadaten, Volltext, Embeddings |
| Nur in der Cloud | Nur Metadaten + Dateiname |
| Vorher indiziert, aktuell nicht lokal | Inhalt optional weiter durchsuchbar, als zwischengespeichert markieren |

Lesen über OneDrive: `NSFileCoordinator` einsetzen. Online-Platzhalter erkennen,
NICHT unbemerkt massenhaft materialisieren. OneDrive-Eviction ≠ Löschung.

## 4. Dokumentenextraktion

Modulare Parser mit gemeinsamem Protokoll:
```swift
protocol DocumentExtractor: Sendable {
    var supportedExtensions: Set<String> { get }
    func extract(fileURL: URL, context: ExtractionContext) async throws -> ExtractedDocument
}
struct ExtractedDocument: Sendable {
    let title: String?
    let metadata: [String: String]
    let segments: [DocumentSegment]
}
struct DocumentSegment: Sendable {
    let text: String
    let location: DocumentLocation
    let kind: SegmentKind
}
```
`DocumentLocation` unterscheidet PDF-Seiten, PPTX-Folien, XLSX-Tabellen/Zellbereiche, Word-Abschnitte.

### Unterstützte Formate & Priorität
| Format | Extraktion | Priorität |
|---|---|---|
| PDF | PDFKit, seitenweise | P0 |
| Scan-PDF | Vision OCR | P0 |
| DOCX | ZIPFoundation + OOXML | P0 |
| PPTX | ZIPFoundation + OOXML | P0 |
| XLSX | ZIPFoundation + OOXML | P0 |
| TXT, CSV, TSV | Foundation | P0 |
| MD, JSON, XML, YAML | Textparser | P0 |
| HTML | HTML-Textparser | P1 |
| Bilder (PNG, JPEG, TIFF) | Vision OCR | P1 |
| EML | MIME-Parser | P1 |
| RTF | NSAttributedString | P1 |
| DOC, PPT, XLS (Legacy) | Legacy-Adapter | P2 |
| Pages, Keynote, Numbers | Spezial-Adapter | P2 |
| ZIP-Archive | Optionaler Archivparser | P2 |

- **PDF**: PDFKit seitenweise; Seiten ohne Text → rendern + Vision OCR; Seitennummer + OCR-Kennzeichnung erhalten.
- **PPTX**: Folientexte, Tabellen, Folienreihenfolge, Notizen; Folie = ein lokalisierbarer Abschnitt.
- **XLSX**: Tabellenblätter, Zellwerte, Formeln, cached results (NICHT neu berechnen); Blatt+Zellbereich speichern; große Tabellen zeilenweise/blockweise.
- **DOCX**: Absätze, Überschriften, Tabellen in Reihenfolge; Kopf/Fuß/Kommentare/Fußnoten als eigene Segmenttypen.
- Grenze: eigener OOXML-Parser versteht nicht alle Sonderfälle (SmartArt, verknüpfte Objekte).
  Architektur muss alternative Extraktoren erlauben. Späterer optionaler **Docling**-Adapter,
  aber keine Laufzeitvoraussetzung der Basis-App.

## 5. Speicherung & Datenbankschema (SQLite)

Vier logische Bereiche: Metadaten, Inhalte, Volltext (FTS5/BM25), Vektoren (sqlite-vec).

### Logisches Datenmodell
| Tabelle | Wichtige Felder |
|---|---|
| `sources` | id, path, enabled, scan_status, last_scan |
| `files` | id, source_id, relative_path, filename, extension, size, mtime, content_hash, state |
| `chunks` | id, file_id, ordinal, text, location_type, location_value, text_hash, token_count |
| `chunk_fts` | rowid, filename, path, text |
| `filename_fts` | filename, relative_path (Trigram-Index) |
| `chunk_vectors_v1` | rowid = chunk_id, embedding float[384] |
| `jobs` | id, file_id, job_type, priority, state, attempts, next_retry |
| `models` | model_id, version, dimensions, checksum, active |
| `settings` | key, value |
| `schema_migrations` | version, applied_at |
Zusätzlich: UUIDs, Parser-Versionen, Fehlercodes, Scan-Generationen, Unique-Constraints.

### Datenbankregeln
1. `files` = Dateimetadaten unabhängig vom Extraktionserfolg.
2. `chunks` = maßgebliche Quelle für extrahierten Text.
3. FTS5 + Vektorindex = rekonstruierbare Suchindizes, nicht die fachliche Datenquelle.
4. Chunk behält stabile ID solange Inhalt + Dokumentbezug unverändert.
5. Dateinamensänderung aktualisiert Namensindex, nicht automatisch alle Embeddings.
6. Neue Modellversion → eigener Vektorindex (keine Dimensionsvermischung).
7. Ein einziger interner Writer-Actor; Lesetransaktionen über begrenzten Connection-Pool.
8. SQLite: WAL-Modus, Foreign Keys an, Integritätschecks, kontrollierte Checkpoints.

### Speicherbedarf (384-dim Float32)
| Chunks | Reine Vektordaten |
|---|---|
| 10.000 | ~15 MB |
| 100.000 | ~154 MB |
| 500.000 | ~768 MB |
| 1.000.000 | ~1,54 GB |

**sqlite-vec** ist vor 1.0, kein hochoptimierter ANN-Index für Millionen Embeddings.
→ Austauschbarer `VectorStore`-Adapter; später ggf. ANN-Index ohne Parser-/UI-Umbau.

## 6. Semantische KI-Suche

### Modell: multilingual-e5-small
- 384-dim, mehrsprachig (DE-Query findet EN-Dokumente), max. 512 Token Input.
- GGUF für llama.cpp, Q8 ~130 MB. App liefert Modell mit → kein Download beim ersten Start.
- Präfixe: `passage:` für Dokumentinhalt, `query:` für Suchanfragen.
- GGUF-Konvertierung vor Freigabe gegen Referenz-Embeddings testen.

### Chunking
- Pro Abschnitt/PDF-Seite/Folie/Tabellenbereich. Zielgröße ~300–350 Token, Überlappung ~40 Token bei Fließtext.
- Strukturgrenzen möglichst nicht überschreiten. Titel/Überschrift/Kontext einbeziehen.
- Identischer Text-Hash → nur neu einbetten bei Modell-/Kontextänderung. Tokenzahl via ausgeliefertem Tokenizer.

### Hybrider Suchalgorithmus (RRF)
Zwei Suchen: lexikalisch (FTS5, inkl. Dateinamen) + semantisch (Vektoren). Fusion via **Reciprocal Rank Fusion**.
Anfangskonfiguration (Ausgangswert, nicht Optimum):
- FTS5: 55 % Gewicht, Vektorsuche: 45 % Gewicht, RRF-Konstante: 60.
- 100 Kandidaten pro Methode, Ergebnisse nach Dokumenten gruppieren, pro Dokument bester Abschnitt zuerst.
- Exakte Dateinamen-Treffer + vollständige Phrasen/exakte Texttreffer besonders hoch gewichten.

### Suchmodi
| Modus | Verhalten |
|---|---|
| Hybrid (Standard) | Volltext + semantisch |
| Exakt | Dateiname, Volltext, Phrasen, Filter |
| Semantisch | Nur Vektorsuche |
Exakte Suche bleibt verfügbar, auch wenn Modell nicht geladen / Vektorindex unvollständig.

## 7. Benutzeroberfläche

MenuBar-App ohne dauerhaftes Fenster/Dock-Icon.
Pflichtfunktionen: Globale Suche (Shortcut, Standard `⌘⇧Space`), MenuBar-Icon, Live-Suche
(Debouncing), Dateivorschau (Quick Look/PDFKit), Datei öffnen, Im Finder anzeigen,
Speicherort kopieren, Filter (Typ/Datum/Größe/Ordner/Quelle), Treffer hervorheben,
Fundstelle (PDF-Seite/Folie/Zelle), Favoriten, Statusübersicht (Datei-/Chunk-/Embedding-Anzahl),
Einstellungen. Quick Look via `QLPreviewPanel`, PDF-Navigation via PDFKit.
Office-Deeplink (Folie/Zelle direkt öffnen) ist separate, nicht garantierte Integration →
präzise Vorschau zunächst in LocalSeek.

### Suchsyntax (eigener Parser → typisierter Ausdruck, KEINE ungeprüften SQL/FTS5-Ausdrücke)
- `"statement of applicability"` — exakte Phrase
- `ext:pptx after:2025-01-01 audit` — PowerPoints ab Datum
- `path:Audits owner` — auf Ordner einschränken
- `type:pdf "risk assessment"` — PDF mit Phrase

## 8. Hintergrundbetrieb & Ressourcen

Zentraler `IndexScheduler` priorisiert Jobs + überwacht Systemlast.
Prioritäten: 1. interaktive Suche; 2. neue Dateien (Metadaten+Volltext früh);
3. aktualisierte Dateien inkrementell; 4. OCR/Embeddings mit niedriger Priorität;
5. Wartung/Optimierung/Integrität nachrangig.

Standardeinstellungen:
| Parameter | Standard |
|---|---|
| Parallele Textextraktionen | 2 |
| Parallele OCR-Jobs | 1 |
| Embedding-Verarbeitung | Batch 8–16 Chunks |
| Debounce Dateiänderungen | 2 s |
| Vollständiger Quellenabgleich | alle 12 h |
| Hohe thermische Last | Pausieren |
| Stromsparmodus | Reduzieren |
| OCR/Embeddings auf Akku | Optional pausieren |
| Priorität neuer Dateien | Hoch |
| Leerlauf-CPU | nahe 0 % |

Embedding-Modell nicht permanent im RAM: laden für Hintergrund/Suche, nach Inaktivität freigeben.
Manuelle Option „Indexierung jetzt pausieren" jederzeit.

Entwicklungsziele (keine Garantien) auf Apple Silicon:
- Dateinamen-/Volltextsuche p95 < 300 ms.
- Hybride Suche p95 < 1 s bei geladenem Modell + 100.000 Chunks.
- Suchfenster öffnen < 200 ms. Metadatenindex sofort nutzbar.

## 9. Datenschutz, Sicherheit, Berechtigungen (verbindlich)

**Kein unbeabsichtigter Datentransfer:**
- Keine Cloud-API für Suche/OCR/Embeddings/Klassifizierung.
- Keine Telemetrie/Analytics/Fehlerberichte/Update-Prüfungen mit Dokumentinhalten.
- Kein offener HTTP-Server. Kein Auto-Download von KI-Modellen.
- Keine Inhalte/Dateipfade/Suchanfragen in Diagnose-Logs. Keine externen Netzzugriffe im Normalbetrieb.

**Dateisystemrechte:** **Keine App Sandbox** (Abweichung, siehe Dokumentanfang). Zugriff auf
Quellordner über die normale macOS-TCC-Autorisierung: der Nutzer wählt Ordner über `NSOpenPanel`,
macOS gewährt dem Prozess Lesezugriff. Da alles in einem Prozess läuft, entfällt die Weitergabe
von Security-Scoped Bookmarks zwischen Prozessen. Nur ausdrücklich gewählte Ordner, NIE stille
Rechteausweitung, kein Root.

**Speicherung:** DB + Modelle unter `~/Library/Application Support/LocalSeek/` (kein
Sandbox-Container mehr). Nur Benutzerkontext, nie Root. Keine Originaldokumente dauerhaft
duplizieren. DB nur für Benutzer lesbar.
Temp-Extraktionsdateien möglichst vermeiden. Gelöschte Inhalte kontrolliert aus FTS/Vektorindex entfernen.
SQLite `secure_delete` + FTS5 `secure-delete` soweit unterstützt; WAL + Wartung beachten.
Fehlerhafte ZIP/PDF/Office dürfen weder große Allokationen noch Archiv-Traversal auslösen.

Später optional SQLCipher. Für v1 bei aktivem FileVault auf OS-Schutz setzen.
Unternehmenskontext: vor Einsatz mit echten Arbeitsdateien klären, ob lokale Drittsoftware/
eigene KI-Modelle/sekundäre Volltextindizes erlaubt sind.

## 10. Verzeichnisstruktur (Soll)

```
LocalSeek/
├── LocalSeek.xcodeproj (via XcodeGen aus project.yml)
├── README.md / LICENSE / THIRD_PARTY_NOTICES.md / Package.resolved
├── Apps/LocalSeek/
│   ├── LocalSeekApp.swift (@main, MenuBar + Settings, LoginItemManager)
│   ├── IndexService.swift (In-Process-Indizierung; Einstieg für Scanner/Scheduler)
│   ├── AppCoordinator.swift, MenuBarController.swift, HotkeyManager.swift
│   ├── Views/ (SearchWindow, SearchResultRow, DocumentPreview, FilterPanel, StatusView, SettingsView)
│   └── Core/  (die früheren Agent-Subsysteme, jetzt in-process):
│       ├── Scanner/ (DirectoryScanner, FSEventsWatcher, CloudFileResolver, ChangeDetector)
│       ├── Scheduler/ (IndexScheduler, JobQueue)
│       ├── Extraction/ (DocumentExtractor, PDF/DOCX/PPTX/XLSX/PlainText/VisionOCR-Extractor)
│       ├── Indexing/ (Chunker, EmbeddingEngine, IndexCoordinator)
│       ├── Search/ (SearchEngine, QueryParser, LexicalSearch, VectorSearch, HybridRanker)
│       └── Persistence/ (DatabaseManager, FileRepository, ChunkRepository, VectorStore, Migrations/)
├── Shared/ (Models/, Errors/)   — SharedCore-Framework
├── Native/ (LlamaBridge/, SQLiteVecBridge/)
├── Models/ (manifest.json)
├── Tests/ (UnitTests, IntegrationTests, UITests, Fixtures, PerformanceTests)
└── Scripts/ (build.sh, test.sh, package.sh, verify-offline.sh)
```
Modellgewichte + kompilierte Drittlibs als überprüfte Abhängigkeiten beim Build, NICHT ungeprüft als Binärblobs im Quellcode.

### Zentrale Interfaces
| Interface | Aufgabe |
|---|---|
| `FileSourceProvider` | Dateien+Metadaten einer Quelle ermitteln |
| `DocumentExtractor` | Dateitypen → strukturierte Texte |
| `ChunkingStrategy` | Dokumente → Suchabschnitte |
| `EmbeddingProvider` | Lokale Vektoren erzeugen |
| `VectorStore` | Vektoren speichern/suchen/entfernen |
| `SearchProvider` | Kandidaten aus Suchindex |
| `RankingStrategy` | Ergebnisse zusammenführen/sortieren |
| `IndexScheduler` | Verarbeitung priorisieren/steuern |
| `IndexService` | In-Process-Fassade: Quellen-/Status-/Suchoperationen (ersetzt den früheren XPC-Vertrag) |

Da alles in einem Prozess läuft, entfällt der XPC-Vertrag. `IndexService` bietet dieselben
logischen Operationen als normale (async) Swift-API; übertragene Werte sind `Sendable`-Modelle.
Logische Operationen:
```
search(query, options) -> SearchResponse
addSource(url, options) -> SourceID
removeSource(id, purgeIndex) -> Result
listSources() -> [SourceStatus]
getIndexStatus() -> IndexStatus
pauseIndexing() / resumeIndexing() -> Result
rescanSource(id) -> JobID
cancelJob(id) -> Result
rebuildIndex(scope) -> JobID
getPreview(fileID, location) -> PreviewData
getDiagnostics() -> Diagnostics
```
`SearchResponse` paginiert, inkl. Fundstelle + Snippet.

## 11. Implementierungsphasen

- **Phase 1 — App-Grundgerüst + Hintergrundbetrieb.** ✅ **umgesetzt + abgenommen.** SwiftUI MenuBar + Suchfenster;
  Autostart via `SMAppService.mainApp`; In-Process-`IndexService` + Statusanzeige; Ordner
  hinzufügen (TCC, keine Sandbox), Quellen merken, Autostart. **Abnahme: App startet
  selbstständig, läuft fensterlos weiter.**
- **Phase 2 — Dateinamen-/Metadatensuche.** ✅ **umgesetzt + abgenommen** (Dateinamensuche
  verifiziert; Live-Updates implementiert). SQLite-Schema + Migrationen (GRDB); rekursiver
  Scanner, FSEvents-Live-Updates (entprellt, inkl. Lösch-Reconcile); Namen/Pfade/Metadaten
  indizieren; Suchfenster mit Trigram-FTS5-Live-Suche, öffnen, im Finder zeigen, Pfad kopieren.
  (Filter nach Typ/Datum/Größe + globaler Hotkey `⌘⇧Space` noch offen → Nacharbeit/Phase 3.)
  **Abnahme: Everything-ähnliche Suche.**
- **Phase 3 — Volltext + OCR.** PDF/DOCX/PPTX/XLSX-Extraktoren; FTS5 BM25, Snippets,
  Suchsyntax; Seiten/Folien/Zellen-Positionen; Vision OCR + Quick Look. **Abnahme: alle
  P0-Formate nach Inhalt durchsuchbar.**
- **Phase 4 — Semantische Hybrid-Suche.** llama.cpp + GGUF; Chunking + Embedding-Queue;
  sqlite-vec + Vektorpersistenz; Hybrid-Ranking, Reindex, Modellversionierung. **Abnahme:
  DE-Bedeutungsanfragen finden EN-Dokumente.**
- **Phase 5 — Produktionshärtung.** Akku-/Speicher-/CPU-Limits; Crash-Recovery,
  Indexintegrität; OneDrive-Placeholder + Offline; Datenschutzprüfung, Benchmarks, Packaging.
  **Abnahme: zuverlässig nach Neustarts, keine Dev-Umgebung zur Ausführung nötig.**

Nach jeder Phase: ausführbare, testbare Version. KEINE Scheinimplementierungen,
hartcodierten Ergebnisse, leeren TODO-Funktionen oder funktionslosen Buttons als „fertig".

## 12. Teststrategie & Abnahmekriterien

Realistische Dokument-Fixtures, nicht nur Mocks. Pflicht-Szenarien:
| Szenario | Erwartetes Ergebnis |
|---|---|
| 10.000 Testdateien erstmalig | Dateinamenindex vollständig, UI bedienbar |
| PowerPoint-Begriff auf Folie 17 | Treffer mit korrekter Foliennummer |
| PDF-Wort auf Seite 8 | Treffer mit korrekter Seitennummer |
| Excel-Wert in `Risks!B42` | Treffer zeigt Blatt + Zellbereich |
| DE-Suche nach EN-Inhalten | Semantisch relevante Ergebnisse |
| Datei umbenannt | Pfad aktualisiert, keine unnötigen Embeddings |
| Inhalt verändert | Veraltete Chunks ersetzt |
| Datei gelöscht | Metadaten+Volltext+Vektoren entfernt |
| OneDrive nicht verfügbar | Index konsistent, keine Massenlöschung |
| Nur online verfügbar | Kein unbeabsichtigter Download |
| App-Crash während Job | Konsistente Wiederaufnahme nach Neustart |
| Beschädigte/riesige Datei | Kontrollierter Fehler, kein Crash/Speicherexplosion |
| Start ohne Internet | Alle Kernfunktionen verfügbar |
| Quelle entfernt | Indexdaten vollständig+kontrolliert gelöscht |

Zusätzlich: Unicode, Umlaute, SQL-Injection, FTS-Sonderzeichen, fehlerhafte OOXML,
ZIP-Bombs, Symlinks, Duplikate, Zugriffsänderungen, unterbrochene OneDrive-Sync.

**Definition of Done:** Code kompiliert, Tests grün, App läuft real auf Ziel-Mac,
bekannte Einschränkungen dokumentiert. Keine Scheinimplementierungen.

## 13. Installation & Auslieferung

macOS 14+, Apple Silicon (M1+), ARM64, native `.app` unter `/Applications/` (oder
`~/Applications/` beim Selbst-Build ohne Admin), keine Admin-Rechte im Normalbetrieb,
**ein einziger Prozess** (keine separaten Dienste/Laufzeiten, keine App Sandbox). Modell + native Libs
selbst enthalten. Setup-Assistent beim ersten Start (Quellordner, Hintergrundgenehmigung, Index-Start).
Lokaler Selbst-Build: kein kostenpflichtiges Apple-Dev-Abo nötig; für signierte Distribution
Developer-ID/Notarisierung. Verwalteter Unternehmens-Mac kann selbstgebaute Apps blockieren.

## 14. Verbindliche Rahmenbedingungen (Codex-Auftrag, Kurzfassung)

- Swift 6 strict concurrency; SwiftUI + bei Bedarf AppKit; macOS 14+ Apple Silicon ARM64.
- **Ein Prozess** (MenuBar-App, In-Process-Indizierung); Autostart via `SMAppService.mainApp`;
  kein XPC, keine HTTP-Server, keine App Sandbox; SQLite + FTS5 + sqlite-vec.
- Embeddings lokal via llama.cpp + Metal; Standardmodell multilingual-e5-small GGUF 384-dim.
- Native Swift-Extraktoren (Foundation, ZIPFoundation, PDFKit, Vision).
- Eigenständige `.app`, kein Docker/Python/Java/Ollama. Alle Deps kostenlos + lizenzdokumentiert.
- Keine Telemetrie/Cloud-API/Dokument-Transfer. Nur ausdrücklich freigegebene Ordner.

**Technische Qualitätsanforderungen (Verbote):**
- Kein UI-Main-Thread-Blocking durch Index/Inferenz.
- Kein unbegrenztes Einlesen großer Dokumente in RAM.
- Keine unnötige Neuindizierung unveränderter Inhalte.
- Kein stilles Herunterladen von OneDrive-Online-Dateien.
- Keine Indexlöschung bei vorübergehend nicht erreichbaren Quellen.
- Keine Vermischung verschiedener Embedding-Modelle in einem Vektorindex.
- Kein dauerhaft hoher KI-Ressourcenverbrauch.
- Keine ungeprüften SQL-/FTS-Ausdrücke aus Benutzereingaben.
- Keine Dokumentinhalte/personenbezogene Suchanfragen in Logs.
- Kein Root-Daemon, keine stille Rechteausweitung.
- Keine hartcodierten Testresultate/funktionslosen Buttons/Platzhalter als „fertig".

## 15. Spätere Erweiterungen (nicht v1)

Duplikat-/Ähnlichkeitssuche (Hoch), native Finder-Integration (Hoch), gespeicherte
Suchprofile (Hoch), mehrere Embedding-Modelle (Mittel), lokale KI-Zusammenfassungen mit
Quellen (Mittel), Auto-Tags/Klassifikation (Mittel), lokale MCP-Schnittstelle (Mittel —
respektiert dieselben Quellen-/Zugriffsrechte), Docling-Parser (Mittel), ANN-Vektorindex
(bedarfsabhängig), lokale Sprachsuche (Niedrig).

### Finale Architekturentscheidung
SwiftUI-MenuBar-App (ein Prozess, In-Process-Indizierung) + SQLite/FTS5 + sqlite-vec +
llama.cpp + native Dokumentenparser.
Größter Aufwand: zuverlässige Textextraktion, OneDrive-Integration, Index-Synchronisierung —
daher modular, testbar, austauschbar angelegt.
