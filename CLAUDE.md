# LocalSeek — aktueller Arbeitsstand

Stand 2026-10-17: v1-Nacharbeit und abschließende Codeprüfung umgesetzt.
100 Tests grün. UI-Prüfung und erneute Installation auf ausdrückliche Nutzeranweisung beendet. Die früheren Phase-4-Notizen sind in
`HANDOFF/PHASE4-HISTORY-2026-10-16.md` archiviert. Für Bedienung/Build gilt `README.md`,
für tatsächliche Nachweise und externe Abnahmegrenzen `HANDOFF/FINAL-VALIDATION.md`.

## Einstiegspunkte

- `Apps/LocalSeek/Launcher.swift`: normaler SwiftUI-Start oder isolierter CLI-Selbst-/Lasttest.
- `AppDelegate.swift`: Suchfenster, Einrichtung, Systemressourcen, geordneter Abschluss.
- `GlobalShortcut.swift`: Carbon-Hotkey, Standard ⌘⇧Space, keine Accessibility-Freigabe nötig.
- `IndexService.swift`: Quellen/Modell/Suche/Diagnose, MainActor-Fassade.
- `Shared/Core/IndexScheduler.swift`: dauerhafte priorisierte Queue, Checkpoints und Backoff.
- `IndexWorker.swift`: Metadaten → Inhalt → Einbettungen, Wartung alle zwölf Stunden.
- `LocalFileAccess.swift`: SF_DATALESS, keine Materialisierung, gepinnte koordinierte Reads.
- `DirectoryScanner.swift`: Generationenabgleich, keine Löschung bei unvollständigem Scan.
- `Extraction/`: synchrone Parser in Hintergrundtasks, tokenbegrenztes überlappendes Chunking.
- `Search/`: gemeinsame Filter, RRF, begrenzte Streaming-Vektorsuche, Benchmark.
- `Persistence/`: Schema v5-resilience, stabile Chunk-IDs, Fehler/Jobs/Favoriten/Quellenmanifest,
  Integrität/FTS-Reparatur, private Dateirechte, WAL-Wartung.

## Native Laufzeit

Kein `/opt/homebrew`-Link mehr. llama.cpp v0.6.0 mit vendored ggml 0.26.0 statisch,
Metal-Library eingebettet; exakte Revisionen in Scripts/Package.resolved.
Getestetes Modell: TwinSunsLLC multilingual-e5-small-q8_0.gguf, 384 Dimensionen,
SHA-256 `e011debc1208e31bf7b6aebee2d9fc8bd2ca11694a77ed66ac9d0c9d0a877c93`.
Die tatsächliche Positionstabelle erlaubt 511 Tokens, Standardchunks zielen auf 350
mit ungefähr 40 Tokens Überlappung. Präfix und Spezialtokens werden mitgezählt.
Fallback ohne Modell zählt konservativ UTF-8-Bytes; beim Laden wird neu gechunkt.
Die alte inkompatible F32-Datei bleibt im Modell-Unterordner `previous` erhalten.

## Bewusst dokumentierte Implementierungsentscheidungen

- Indizierung/DB in der App, keine Sandbox/XPC-Dienste. Ausnahme seit 2026-10-18:
  Vision läuft in einem eingebetteten, kurzlebigen `LocalSeekOCR`-Hilfsprozess.
  30 Sekunden je Bild/Scan-Seite; SIGKILL bei Timeout/Abbruch, begrenztes Aufräumen.
  Der Helper hat zusätzlich eine Deadline und beendet sich beim Verlust des Elternprozesses.
- `BruteForceVectorStore` mit Accelerate/vDSP statt sqlite-vec. Austauschbarer Store,
  Filter vor Kandidatenauswahl, Top-k-Heap und rowweise BLOB-Zugriffe.
- Ein aktiver Hintergrundjob statt paralleler Extraktoren; bei neuen Metadaten
  Checkpoint-Unterbrechung, bis zu zwei Inferenz-Threads, ein OCR-Lauf.
- Embeddings einzeln statt großer nativer Batches. Das begrenzt Kontext/Speicher und
  lässt zwischen Chunks Suche, Pause und Abbruch zu. Leerlauf ohne Polling-CPU.
- Parser sind synchron, weil NSFileCoordinator-Zugriff nur bis zum Ende des Accessors
  gültig ist. Der Scheduler führt sie außerhalb des MainActor aus; Chunking ist async.
- Ad-hoc-Pakete ohne Hardened Runtime, Developer-ID-Pakete mit Hardened Runtime.
- Keine neue Open-Source-Lizenz für eigenen Code gewählt; Drittanbieter-Lizenzen enthalten.

## Arbeitsregeln

Originaldateien nie verändern. Nur vom Nutzer gewählte Quellen scannen, keine stille
Rechteausweitung oder Downloads. Keine Inhalte/Pfade/Queries in Diagnose-Logs.
Keine automatischen Cloud- oder HTTP-Dienste. Bestehende uncommittete Arbeit erhalten.
Das tatsächliche Repository liegt im inneren `LocalSeek/`; äußerer Ordner ist nicht
zur Versionsverwaltung dieser Dateien geeignet. Aktuell kein Git-Remote vorhanden.

`Scripts/build.sh`, `Scripts/test.sh`, `Scripts/package.sh` und
`Scripts/verify-offline.sh` sind die reproduzierbaren Einstiegspunkte.
Die Prüfsuite verwendet isolierte Quellen und echte Modellinferenz, sofern das Modell
installiert ist. Kein Ergebnis als Abnahme auf nicht vorhandener Hardware ausgeben.

## Letzte Codekorrekturen

- 2026-10-18: Vision im eingebetteten Helper, Timeout/Abbruch erzwingen Prozessende;
  Dateifehler mit Backoff statt blockierter Queue. 106 Tests gebaut, neue Testausführung
  noch durch macOS-Startblockade offen. Aktueller Paketpfad und Wiederaufnahme:
  `HANDOFF/OCR-STALL-FIX-2026-10-18.md`. Release 1.0.1 noch nicht installiert.

- Scheduler prüft nach suspendierendem Statuscallback die Jobzeile erneut: ein
  zwischenzeitlicher Abbruch darf keinen Worker mehr starten. Kein Worker vor `start()`.
- Dateiumbenennung nutzt den tatsächlichen Quellenpfad; eine Quellen-ID muss kein Pfad sein.
  Zwei vorhandene Hardlinks behalten getrennte Dateieinträge.
- DB-Schreibfehler beim Scan brechen sofort ab; ein fehlschlagender Batch wächst nicht weiter.
- HTML überspringt rohe Script-Inhalte bis zum schließenden Tag und dekodiert Entities linear.
- MIME behandelt gültige Grenzen mit abschließenden Bindestrichen und Leerraum korrekt;
  kumulatives Rekursionsbudget begrenzt Speicherarbeit.
- FSEvents `start`/`stop` können auch aus dem eigenen Callback aufgerufen werden.
- Hotkey-Konfiguration fängt ungültige gespeicherte Zahlen ab; `stop` setzt Registrierungsdaten zurück.
- Parser-Version `extract-4:chunk-2` erzwingt die Nachverarbeitung bereits gespeicherter Inhalte.
- Paketierung verweigert einen veralteten Build anhand eines Quellen- und Konfigurationsnachweises.

Alle weiteren Prüfschritte laufen ausschließlich ohne App-Oberfläche: Tests, Compiler,
Signatur-/Abhängigkeitsprüfung und CLI-Selbsttest. Die Installation wurde anschließend
ausdrücklich beauftragt; keine Veröffentlichung.
