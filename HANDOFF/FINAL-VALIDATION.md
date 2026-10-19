# Abschlussprüfung LocalSeek — 2026-10-17

Umfang der abschließenden Prüfung auf Nutzeranweisung: **nur Code, Build und
automatisierte Tests**. Keine weitere UI-Prüfung. Auf die anschließende Nutzeranweisung
wurde der unten genannte abschließende Build am 2026-10-17 in `~/Applications` installiert.

## Ergebnis

- **100 Tests, 0 Fehler, 0 übersprungene Tests**; echte lokale llama.cpp-Inferenz eingeschlossen.
- Debug-Tests und Release-Build erfolgreich, Swift 6 mit vollständiger Concurrency-Prüfung.
- Kein `GGML_ASSERT` und keine SQLite-Meldung über unzulässige Testbereinigung.
- `git diff --check` und Shell-Syntaxprüfung aller Skripte ohne Fehler.
- Paket-Signatur, arm64-Architektur und dynamische Abhängigkeiten geprüft.
  Kein Homebrew-Laufzeitpfad; App und SharedCore melden macOS 14.0 als Deployment-Ziel.
- CLI-Selbsttest/Lasttest mit gesperrtem Netzwerk: Exitcode 0, `passed: true`.
- Paketierung lehnt einen veralteten Quellstand ab. Der Negativtest meldete korrekt:
  „Quellstand geändert. Bitte Scripts/build.sh erneut ausführen.“

Buildumgebung: macOS 27.0.1, Apple M3, Xcode 27.1 / Swift 6.4.
App-Metadaten: Version 1.0.0, Build 1.

## Behobene Randfälle aus der Codeprüfung

1. Ein Abbruch während des suspendierenden Statuscallbacks konnte vor dem
   Workerstart übergangen werden. Der Scheduler prüft nun die dauerhafte Jobzeile
   erneut und startet keine Arbeit vor `start()`.
2. Bei Quellen-IDs, die keine Pfade sind, konnten Hardlinks als Umbenennung
   zusammenfallen. Die Prüfung nutzt jetzt `sources.path` und bestätigt ENOENT.
3. Ein fehlgeschlagener DB-Batch durfte nicht im Metadaten-Catch verschwinden und
   anschließend über die gesamte Quelle weiter wachsen. Schreibfehler brechen sofort ab.
4. JavaScript mit `<` konnte HTML-Text nach dem Script abschneiden. Rohe Script-
   und Style-Inhalte werden bis zum tatsächlichen schließenden Tag übersprungen;
   Entity-Dekodierung verarbeitet den Text linear.
5. MIME-Grenzen mit abschließenden Bindestrichen oder Leerraum werden korrekt
   unterschieden. Ein kumulatives Budget begrenzt rekursive Verarbeitung.
6. Start/Stop des FSEvents-Wächters verursachen auch im eigenen Callback keinen
   Queue-Selbstaufruf. Ein Test erzeugt dafür ein echtes temporäres Dateiereignis.
7. Ungültige gespeicherte Hotkey-Zahlen können keine UInt32-Konvertierung abbrechen;
   Stop/Neustart setzen die Registrierungsdaten zurück. Nur im Code geprüft.
8. Parser-Version `extract-4:chunk-2` plant bestehende Inhalte nach Parseränderungen neu ein.

Die Suite prüft außerdem PDF-Seite 8, PPTX-Folie 17/Notizen/Reihenfolge, XLSX
`Risks!B42:B42` und vorhandene Formelwerte, Unicode-Chunkgrenzen mit echtem Tokenizer,
fehlende/teilweise verfügbare Quellen, Platzhalter ohne Inhaltszugriff, stabile
Chunk-/Vektor-IDs, persistente Queue-Wiederaufnahme, gemeinsame Filter/Favoriten,
Integritäts-/FTS-Reparatur, private DB-Rechte und mehr als 10.000 wartende Chunks.

## CLI-Lastmessung

Isolierter synthetischer Bestand: **10,000 echte Testdateien**, **100,000
Vektoren mit 384 Dimensionen und **100.000 Volltext-Einträge**.
Keine eingerichteten Nutzerquellen verwendet. Zwei Aufwärmrunden und 20 gemessene
Runden pro Suchtyp. Netzwerk ausschließlich für den Testprozess gesperrt.

| Messung | Ergebnis |
|---|---:|
| Metadatenabgleich 10.000 Dateien | 5.12 s |
| Dateinamensuche p95 | 1.19 ms |
| Volltext/BM25 p95, Begriff in allen 100.000 Chunks | 86.33 ms |
| Vektorsuche Median / p95 | 81.49 / 83.27 ms |
| Hybride Suche mit echtem E5-Query-Encoding p95 | 100.37 ms |
| Max. zusätzliche Verzögerung des 25-ms-MainActor-Heartbeats | 5.13 ms |
| SQLite-Größe | 218.47 MiB |

`time -l`: Gesamtlauf 28,32 s, maximaler RSS 485,34 MiB, Peak Memory Footprint
309,59 MiB, keine Swaps. Der Heartbeat prüft den MainActor während der CLI-Arbeit;
es ist keine Messung von UI-Frames. Ergebnisse gelten für diesen Mac und diesen
synthetischen Lastfall, nicht als Garantie für beliebige Bestände.
Die Hybridmessung alterniert deutsche Rechnungs-/Backup-Fragen; die synthetischen
Lasttexte enthalten dazu keine Volltexttreffer. Die separate BM25-Messung fragt
`performance` ab und trifft alle 100.000 Chunks.

Mehrsprachiger Qualitätstest separat: zehn englische Passagen und deutsche Fragen,
**9/10 Top-1**, **10/10 Top-3**.
Die Rechnungsfrage stand einmal nicht an erster Stelle. Das ist ein kleiner
Regressionstest und keine repräsentative allgemeine Suchqualitäts-Abnahme.
Die synthetischen Vektoren des Lasttests dienen ausschließlich der Zeit-/Speichermessung.

Rohdaten: [benchmark-2026-10-17.json](benchmark-2026-10-17.json).
Wiederholen: `Scripts/test.sh`, `Scripts/build.sh`, `Scripts/package.sh --skip-build`,
`Scripts/benchmark.sh` (CLI, keine App-Oberfläche).

## Artefakt und Grenzen

Aktueller geprüfter Build:
`<REPOSITORY_ROOT>/build/packages/LocalSeek-20261017-075042/LocalSeek.app`

Der enthaltene Quellen-Nachweis und `Package.resolved` dokumentieren die Eingaben.
Modell-SHA-256: `e011debc1208e31bf7b6aebee2d9fc8bd2ca11694a77ed66ac9d0c9d0a877c93`.
Native Bibliotheken sind statisch gepinnt; Metal und Modell sind eingebettet.

Installiert: `~/Applications/LocalSeek.app`. Die installierte App wurde
Datei für Datei mit dem geprüften Paket verglichen (33 reguläre Dateien, identische
Inhalte); Signatur und Modell-Prüfsumme sind gültig. Die alte App liegt unter
`build/backups/pre-final-install-20261017-080851/LocalSeek.app`.

Zusätzlicher CLI-Selbsttest: Netzwerk sowie der externe Benutzer-Modellordner,
`/opt/homebrew`, `/usr/local` und `build/Native` für den Testprozess gesperrt.
Ergebnis: Exitcode 0, `passed: true`, `offlineModel: true`; das gebündelte Modell
führte echte semantische Suchen aus. Nachweis: [portable-install-2026-10-17.json](portable-install-2026-10-17.json).
Auch das übertragbare `LocalSeek.zip` enthält das Modell mit der erwarteten SHA-256.
Anleitung: [Installation](INSTALLATION.md).

Keine weitere UI-Abnahme vorgenommen. Physische globale Tastendrücke sind daher
nicht als geprüft markiert.

Nicht ausführbar auf der vorhandenen Umgebung: macOS-14-/M1-Laufzeit,
echte OneDrive-Eviction/Synchronisationsunterbrechung in einem verbundenen Konto,
Developer-ID/Notarisierung ohne gültige Identität. Die simulierten Cloud-Zustände
und die tatsächliche macOS-Materialisierungsrichtlinie sind getestet; sie ersetzen
keine Abnahme einer konkreten OneDrive-Installation.

Es wurden keine Commits, PRs, Veröffentlichungen oder Änderungen an Originaldokumenten vorgenommen.
