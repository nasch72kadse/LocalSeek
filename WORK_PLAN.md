# Abschluss der offenen v1-Arbeit

Nachtrag 2026-10-18: OCR-Stall in 1.0.1 durch isolierten Helper mit Deadline behoben.
Test-/Release-Build und Paketprüfung erfolgreich; Testausführung und Paket-Selbsttest
sind bis zur Klärung der macOS-Startblockade offen. Siehe
`HANDOFF/OCR-STALL-FIX-2026-10-18.md`. Noch keine Installation von 1.0.1.

Auftrag: alle noch offenen Punkte aus SPEC, CLAUDE und HANDOFF erledigen. Die in
SPEC §15 ausdrücklich später vorgesehenen Erweiterungen gehören nicht zum v1-Abschluss.
Bestehende Änderungen bleiben erhalten; keine Originaldateien werden verändert.

## Arbeitsfolge und Abnahme

- [x] Tokenbasierte, begrenzte Chunks mit Überlappung, Fundstelle und Parser-Version;
      bestehende Inhalte migrieren, unveränderte IDs/Vektoren erhalten.
- [x] Sichere Quellenabgleiche, lokale/online Dateien, koordinierte Inhaltszugriffe,
      keine Löschung bei Offline-/Berechtigungsfehlern, kein stilles Herunterladen.
- [x] Dauerhafte priorisierte Job-Queue: Metadaten/Inhalte/Embeddings/Wartung,
      Wiederaufnahme nach Crash, Retries, Pause/Fortsetzen, Abbruch, 12-h-Abgleich.
- [x] Energie-/Temperatur-/CPU-Grenzen und Vorrang für interaktive Suche.
- [x] Datenbankrechte, Integritätsprüfung, FTS-Reparatur, WAL-Wartung und Index-Neuaufbau.
- [x] Filter Typ/Datum/Größe/Ordner/Quelle für alle Suchmodi, Favoriten, Cache-Kennzeichnung.
- [x] Globales konfigurierbares Tastenkürzel, Status/Diagnose, Quellenaktionen,
      Einrichtungsansicht und sauberer App-Abschluss.
- [x] Noch fehlende P1-Extraktoren (HTML/RTF/EML) sowie Größen-/Archiv-/XML-Sicherungen.
- [x] Streaming-Vektorsuche, kein 10.000-Chunk-Abbruch, Benchmark mit 100.000 Vektoren
      und 10.000 Dateien, echte mehrsprachige Qualitätsabnahme.
- [x] Gepinnte native Bibliotheken für macOS 14/arm64, eingebettete Metal-Laufzeit,
      GGUF-Modell, Lizenzhinweise, reproduzierbare Build-/Test-/Paket-Skripte.
- [x] Eigenständige App ohne Homebrew-Laufzeitpfade testen, offline prüfen,
      optionaler Developer-ID-/Notarisierungsweg mit vorhandener Signieridentität.
- [x] Vollständige Regression, Release installieren, tatsächliche Index-/App-Abnahme,
      README und Übergabe auf den abschließenden Stand bringen.

## Abschluss 2026-10-17

Codeprüfung abgeschlossen; 100 automatisierte Tests einschließlich echter Modellinferenz.
Parser-Version `extract-4:chunk-2`, damit auch bereits indizierte HTML-Dateien die
korrigierte Extraktion erhalten. Queue-Abbruch vor Workerstart, Hardlinks mit
unabhängigen Quellen-IDs, Schreibfehler beim Scanner und reentrantes Stoppen des
Dateiwächters sind mit Regressionstests abgesichert.

Auf Nutzeranweisung ab 2026-10-17 **keine weitere UI-Prüfung**. Der Abschluss umfasst
Code, automatisierte Tests, Release-Build, Paketprüfung und die CLI-Lastprüfung.
Auf anschließende ausdrückliche Nutzeranweisung wurde der abschließende Release
mit Modell in `~/Applications/LocalSeek.app` installiert und die alte App gesichert.
App und ZIP enthalten das geprüfte Modell. Ein zusätzlicher CLI-Test ohne Netzwerk
und ohne Zugriff auf externe Modelle oder Homebrew war erfolgreich.

Nachweise: `HANDOFF/FINAL-VALIDATION.md`. Reale OneDrive- und ältere OS-/Hardwaretests
sowie Developer-ID-Notarisierung bleiben externe Abnahmegrenzen, keine erledigten Tests.

## Nachweise und Grenzen

Tests verwenden isolierte temporäre DBs/Quellen und synthetische Inhalte. Ein echter
File-Provider wird nur mit ausdrücklich ausgewählten lokalen Quellen benutzt.
Nicht vorliegende Hardware-/OS-Versionen und fehlende Apple-Signieridentitäten werden
benannt; vorbereitete Codepfade gelten nicht als dort ausgeführte Abnahmen.

Ausgangsstand: 72 Tests grün; Xcode 27.1, Swift 6.4, llama.cpp v0.6.0
(`d81235049384534c167caea52b85a694f6103d14`), Homebrew-ggml 0.27.0.
Installiertes Q8-Modell: `multilingual-e5-small-q8_0.gguf`, SHA-256
`e011debc1208e31bf7b6aebee2d9fc8bd2ca11694a77ed66ac9d0c9d0a877c93`.
