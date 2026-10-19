# LocalSeek 1.1.0 Build 3: Indexierung großer Bestände

Nutzerauftrag: die sechs vorgeschlagenen Optimierungen umsetzen. Ausschließlich
Codeprüfung, keine UI-Automation. Repository liegt aktuell unter
`<REPOSITORY_ROOT>`.

## Implementierung

1. FSEvents werden je Quelle als relative Pfade dauerhaft gespeichert. Ereignisse
   tragen eine Revision; ein neueres Ereignis desselben Pfads überlebt den Abschluss
   eines älteren Jobs. Dateiänderungen bleiben auf Dateien beschränkt; Unterordner
   werden innerhalb ihres gemeinsamen Teilbaums abgeglichen. Bei quellenweiten
   Ereignissen, verlorenen Events und Überlast wird vollständig abgeglichen.
   Vollscan zusätzlich bei Start, manuellem Abgleich und zwölfstündiger Wartung.
   Ein Umbenennen über verschiedene Teilbäume kann den Bereich bis zur Wurzel
   vergrößern. Hidden-/Package-Ausschlüsse, Symlink-/Cloud-Schutz und vorsichtige
   Löschabgleiche bleiben erhalten. Die UI-Entprellung beträgt zwei, maximal fünf
   Sekunden; das ist keine garantierte Fertigstellungszeit bei einer vollen Queue.
2. Identische Metadaten verursachen keinen Upsert. Die FTS-Update-Trigger reagieren
   nur auf Namens-/Pfadänderungen. Vollscans schreiben weiterhin Generationen je
   Datei für sichere Löschabgleiche. Inhaltsstände berücksichtigen nun Größe und
   Geräte-/Inode-Identität zusätzlich zum Zeitstempel. Ohne Änderung eines dieser
   Merkmale wird eine Änderung nicht erkannt; kein vollständiges Hashen der Dateien.
3. Fortsetzbare Inhaltsjobs bis acht Dateien/zwei Sekunden zwischen Dateien;
   Embedding-Jobs bis 64 Chunks/zwei Sekunden zwischen Paketen. Nach jedem Inhaltsjob
   wird ein Embedding-Pass höher priorisiert; danach dürfen weitere Inhalte folgen.
   Cursor bleiben in SQLite, neue Änderungen setzen den Cursor zurück. Die Arbeit
   innerhalb einer Datei bzw. eines nativen Inferenzaufrufs bleibt synchron.
4. Bis vier voneinander getrennte Sequenzen in einem llama_encode-Aufruf. Jeweils
   eigene Positionen, Sequenz-IDs und Mean-Pooling; das 511-Token-Limit bleibt je
   Sequenz bestehen. Ein DB-Commit je Paket; Text-Hashes verhindern das Speichern
   überholter Ergebnisse. Schlägt ein Paket fehl, werden seine Texte einzeln versucht.
5. OCR-Ergebnis-Cache in SQLite, an Datei-FKs gebunden. Schlüssel aus PNG-Raster,
   Sprache, Erkennungs-/macOS-Version. 64 MiB JSON, höchstens 32.768 Einträge,
   30 Tage Inaktivität, LRU-Verdrängung. SQLite-Verwaltungsdaten kommen hinzu.
   Fehlversuche werden nicht gecacht. Der Cache erspart Vision-Arbeit, nicht das
   Rendern einer PDF-Seite. Beim erfolgreichen Inhaltscommit werden nicht mehr
   verwendete Seitenkeys entfernt. Der bisherige OCR-Prozess-Timeout bleibt aktiv.
6. hnswlib v0.9.0, unveränderte Apache-2.0-Header fest eingebaut; keine zusätzliche
   Laufzeitinstallation. Ab 50.000 Vektoren Hintergrundaufbau im RAM. Geschätztes
   Budget ein Achtel des physischen RAM, höchstens 2 GiB; Freigabe bei Speicherdruck.
   SQLite ist maßgeblich. Bis zum fertigen Graphen, bei Revisionlücken oder Budget-
   überschreitung und für Suchfilter exakte Suche. Aktuelle SQL-Zeilen prüfen alle
   Kandidaten; exakte Nachbewertung. HNSW bleibt eine Näherung, ohne garantierten
   Top-k-Recall. Kein Graph auf Platte; nach Neustart neuer Aufbau. Begrenztes
   Änderungsjournal (100.000 Einträge) nur für einen aktiv aufgebauten Graphen.

Migrationen v6/v7 sind additiv. Kein Neuaufbau des gesamten Inhaltsindex allein
wegen des Updates. Alte Pakete sind erhalten. Die installierte 1.0.0 ist vom neuen
Quellstand getrennt; ein Paketbau ersetzt keine installierte App.

## Prüfung und Messgrenzen

Die aktualisierten Swift-/C++-Quellen und Regressionstests werden mit Swift 6 strict
concurrency als arm64 für macOS 14 gebaut. Aktueller Zielbestand: 128 XCTest-Methoden.
Die Suite enthält neue Fälle für schmale Änderungsbereiche, Rename-Erhalt, gleiche
Zeitstempel bei Größen-/Identitätswechsel, Ereignisrevisionen, Fortsetzung und frühe
Embeddings, Paketfehler, Text-Hash-Rennen, OCR-Cache und ANN-Änderungen/Filter/Budget.

**Der vollständige neue XCTest-Lauf ist noch nicht bestätigt.** Auch der letzte
direkte xctest-Aufruf lieferte vor dem Teststart keine Ausgabe und wurde beendet.
Die frühere Stichprobe zeigte Code-Signaturvalidierung beim Laden des Test-Bundles;
der Nutzer hatte einen macOS-Sicherheitsblock gemeldet. Die 100 bestandenen Tests
vom 17.10. betreffen 1.0.0. Keine Sicherheitseinstellungen wurden verändert.

Zusätzliche ausführbare Prüfungen, separat erfolgreich:

- `python3 Scripts/check-migration-sql.py`: SQL-Literale der v6/v7-Migrationen gegen
  eine minimale Vorversion-Fixture (SQLite 3.53.4): FTS nur bei Namen/Pfaden,
  OCR-Budget/Cascade, Vektorrevisionen, Modellwechsel und Journalgrenze. Das ersetzt
  nicht die tatsächliche Swift-/GRDB-Migration einer Benutzer-Datenbank.
- `bash Scripts/test-native-embeddings.sh` außerhalb der Codex-Sandbox für Metal:
  echtes lokales Q8-Modell, vier Sequenzen inklusive Unicode und Trunkierung.
  Minimum-Cosine zwischen Batch und Einzelberechnung gerundet 1, alle >0,9999;
  ungültige Paketgrößen/Kapazitäten abgewiesen. Der erste Sandbox-Lauf konnte den
  Modellkontext nicht laden; außerhalb war er erfolgreich.
- `bash Scripts/test-native-ann.sh 100000`: 100.000 unterschiedliche synthetische
  Clustervektoren mit 384 Dimensionen, Aufbau 44,03 s, Kandidatensuche P95 0,658 ms
  über 32 Abfragen. Alle exakten Top-10 waren in den jeweils 256 Kandidaten. Update,
  Löschen und Wiedereinfügen geprüft. Reine native Komponente, ohne SQLite-Filter,
  Swift-Scheduler, Modellinferenz oder Produktionsdaten. Deshalb weder eine
  Ende-zu-Ende-Latenz noch eine repräsentative Garantie für Suchqualität.

Der ältere 100k-SQLite-Benchmark bleibt in `benchmark-2026-10-17.json`. Seine
83-ms-P95 darf nicht als direkte Vergleichsgröße zur nativen 0,658-ms-Zeit benutzt
werden. Für das neue Gesamtsystem stehen Zeitvergleich und Alltagstest nach der
Startfreigabe noch aus. Der App-Benchmark misst nun zusätzlich unveränderten
Vollscan und gezieltes Dateiupdate; der Paket-Selbsttest enthält auch OCR und ANN.

Einordnung: Für konkrete Indexierungszeiten fehlen Menge/Größe/Format der Dateien,
OCR-Seitenzahl, Zahl der Textchunks, Datenträger, RAM/CPU und File-Provider-Zustand
auf dem anderen Mac. Viele Textdateien sind typischerweise günstiger als gleich
viele Scan-PDFs. Größere Bestände machen den Erstlauf länger; gezielte Änderungen
vermeiden unnötige Nachbar-Extraktion. Filter mit exakter Vektorsuche und regelmäßige
Vollabgleiche haben weiterhin Aufwand, der mit dem relevanten Bestand wächst.

## Erneut prüfen

Nach Klärung der macOS-Startblockade:

```sh
Scripts/test.sh
Scripts/verify-offline.sh
Scripts/benchmark.sh
```

Ohne UI-Prüfung. Das vollständige ZIP enthält Modell, OCR-Helper, Metal, native
Bibliotheken, Lizenztexte und Quellen-Prüfsummen. Paketpfad und abschließender
Build-/Signaturstatus werden im untenstehenden Abschluss ergänzt.

## Abschluss dieses Durchgangs

- Release-Build erfolgreich; abschließender Test-Build mit 128 Testmethoden
  erfolgreich (`/tmp/localseek-ocr-release.log`, `/tmp/localseek-ocr-buildtests.log`).
- Vollständiges Paket: `build/packages/LocalSeek-20261018-192457/LocalSeek.zip`.
  SHA-256: `457d866c80863dac19dacdfc60e4b7daa9c43f9168d6d910f32581c4050ab2d8`.
- Bundle meldet Version 1.1.0 / Build 3; arm64 und Mindestziel macOS 14. Signaturen,
  externe Laufzeitabhängigkeiten und ZIP-CRC erfolgreich geprüft. Modell-SHA-256
  `e011debc1208e31bf7b6aebee2d9fc8bd2ca11694a77ed66ac9d0c9d0a877c93` bestätigt.
- Letzter Paket-Offline-Test endete mit Signal 9 / Exit 137, ohne Selbsttestbericht.
  Der genaue Grund dieses SIGKILL ist damit nicht bestimmt. Frühere xctest-Start-
  blockade und Nutzermeldung zur macOS-Sicherheit bleiben relevant. Die noch unter
  `build/reports/offline.json` liegende Datei vom 16.10. ist kein neuer Nachweis.
- Die installierte Version 1.0.0 wurde erhalten. Kein Datenbank-Upgrade auf echten
  Nutzerquellen ausgeführt. Vor einer Abnahme muss das neue Bundle gestartet werden
  können; erfolgreiche Kompilierung ersetzt diesen Lauf nicht.
- Native Messergebnisse liegen daneben in `native-ann-2026-10-18.json`,
  `native-batch-2026-10-18.json`, `migration-sql-2026-10-18.json`.
- Keine UI-Prüfung, keine Änderung von macOS-Sicherheitseinstellungen.
