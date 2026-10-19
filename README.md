# LocalSeek

Lokale macOS-Menüleisten-App für Dateinamen, Volltext und semantische Suche. Swift 6,
SQLite/FTS5, multilingual-e5-small mit llama.cpp/Metal. Keine Cloud-API, kein Server,
keine Python-/Ollama-/Homebrew-Laufzeitabhängigkeit des fertigen Pakets.

Ziel: macOS 14+, Apple Silicon. Gebaut und ausgeführt auf macOS 27.0.1 / Apple M3.
Die Laufzeit auf macOS 14 und M1 ist auf diesem Rechner nicht separat geprüft.

Version 1.1.0 ergänzt gezielte Änderungsabgleiche, begrenzte Verarbeitungsetappen,
Batch-Embeddings, OCR-Cache und einen HNSW-Vektorindex für große Bestände. Der
isolierte OCR-Helper aus 1.0.1 ist enthalten. Der vollständige Lauf der neuen
Swift-Tests ist durch eine macOS-Startblockade noch offen; native Komponenten und
Migrations-SQL werden zusätzlich separat geprüft. Details und Messgrenzen:
[Optimierungen und Prüfstatus](HANDOFF/INDEX-OPTIMIZATIONS-2026-10-18.md).

## Benutzung

1. Die fertige `LocalSeek.dmg` doppelklicken, `LocalSeek.app` auf „Programme“ ziehen,
   das Laufwerk auswerfen und die App aus „Programme“ starten.
   Suchmodell, native Bibliotheken und Metal sind enthalten; zusätzliche Downloads oder
   Entwicklungswerkzeuge werden zur Benutzung nicht benötigt. Siehe [Installation](HANDOFF/INSTALLATION.md).
2. Im Einrichtungsfenster oder unter **Einstellungen → Quellen** die gewünschten Ordner wählen.
3. **⌘⇧Space** öffnet die Suche. Das Kürzel lässt sich in den Einstellungen ändern.
4. Dateien oder Inhalte suchen; für Inhalte Hybrid, Exakt oder Semantisch wählen.
5. Filter öffnen oder direkt schreiben: `ext:pdf path:Projekte after:2026-01-01 minsize:1MB`.
   Weitere Filter: `type:`, `before:`, `maxsize:`, `source:` und `favorite:true`.
   Sterne merken Favoriten. Filter funktionieren auch ohne Suchtext.
6. Enter öffnet das Original, Leertaste außerhalb des Textfelds zeigt eine Vorschau,
   Esc schließt das Suchfenster. Das Kontextmenü bietet Finder und Pfad kopieren.

Online-/Offline-Dateien bleiben über gespeicherte Inhalte auffindbar. Die Indizierung
lädt keine Platzhalter herunter. Die Vorschau verwendet bei lokalen Dateien eine kurzlebige,
koordinierte Kopie; bei nicht lokalen Dateien den gespeicherten Suchausschnitt.
**Original öffnen** ist eine ausdrückliche Nutzeraktion und kann beim File Provider einen
Download auslösen. HTML wird als gespeicherter Text angezeigt.

Im Menü lassen sich Indizierung pausieren und Quellen abgleichen. Die Einstellungen
bieten Quellen aktivieren/entfernen, Aufträge abbrechen, Akkupause, Modellwechsel,
Diagnoseexport und Index-Neuaufbau. Fehlerhafte Dateien werden höchstens fünfmal
mit Backoff versucht; **Abgleichen** setzt diese Sperre zurück.

## Unterstützte Inhalte

PDF mit Text und Scan-OCR; DOCX mit Absätzen, Überschriften, Tabellen, Kopf-/Fußzeilen,
Kommentaren und Fußnoten; PPTX mit Reihenfolge und Notizen; XLSX mit Zellwerten,
Formeln und vorhandenen Rechenergebnissen; TXT/CSV/TSV/Markdown/JSON/XML/YAML;
HTML, RTF, EML und übliche Rasterbilder. Legacy-Office, Apple-iWork und allgemeine
ZIP-Inhalte sind spätere Erweiterungen, keine v1-Parser.

Grenzen: 50 MiB je Eingabe/expandiertem Office-Archiv, 16 MiB je ZIP-Part,
20.000 ZIP-Einträge, 500.000 XML-Elemente, XML-Tiefe 128, maximal 1.000 PDF-Seiten
und OCR-Raster mit maximal 4.096 Pixeln je Kante. EML ist auf MIME-Tiefe 12,
200 Teile und 200 MiB kumulativ verarbeitete Rohteile begrenzt. DTDs und externe XML-Entitäten
werden abgelehnt. Office-Sonderfälle wie SmartArt oder verknüpfte Objekte sind
nicht vollständig abgedeckt. EML unterstützt übliche MIME-Strukturen, keine
entschlüsselten S/MIME-/PGP-Inhalte und keine Anhang-Indizierung.

## Selbst bauen

Entwicklung erfolgt auf `dev`, der stabile Stand liegt auf `main`. GitHub Actions
baut nach einem Push auf einen dieser Branches automatisch eine vollständige DMG
und stellt sie nach erfolgreichen Prüfungen als Download beim Workflow-Lauf bereit.
Verwendet wird ein GitHub-Standard-Mac-Runner im enthaltenen Kontingent. Details zu
Downloads, Kostenlimit und den fünf Apple-Secrets:
[GitHub Actions einrichten](docs/GITHUB-ACTIONS.md).

Benötigt: vollständiges Xcode mit akzeptierter Lizenz/Command Line Tools,
Git, CMake und XcodeGen. Zum Beispiel `brew install cmake xcodegen`.
Homebrew-llama.cpp wird für diesen Build nicht benötigt.

```bash
Scripts/build.sh
Scripts/test.sh
Scripts/verify-offline.sh
Scripts/benchmark.sh
python3 Scripts/check-migration-sql.py
bash Scripts/test-native-ann.sh 100000
bash Scripts/test-native-embeddings.sh
```

Beim ersten Build ist Internet für die gepinnten Quellabhängigkeiten nötig.
`Scripts/build-native.sh` prüft die llama.cpp-Revision, baut statische arm64-Libs
für macOS 14 und bettet die Metal-Library ein. SPM-Versionen und Revisionen stehen
in `Package.resolved`. CMake verwendet vier Build-Threads.

Für das Paket muss das Modell bereits lokal vorliegen. Standard:
`~/Library/Application Support/LocalSeek/models/multilingual-e5-small-q8_0.gguf`.
Alternativ vor dem Paketbau `LOCALSEEK_MODEL` auf die Datei setzen.
Herkunft und SHA-256 stehen in [Models/manifest.json](Models/manifest.json).
Die App lädt kein Modell selbst herunter. Ein vorhandenes ausgewähltes Modell hat
Vorrang vor dem gebündelten Modell; inkompatible Modelle werden sichtbar gemeldet.

Jeder erfolgreiche Release-Aufruf von `Scripts/build.sh` erzeugt automatisch
**`build/LocalSeek.dmg`**. Diese eine Datei kann auf einen neuen Mac übertragen
werden. `CONFIGURATION=Debug` kompiliert ausschließlich für die Entwicklung.
`Scripts/package.sh` ist ein gleichwertiger Einstieg für Build plus Paket;
`Scripts/package.sh --skip-build` verpackt einen unveränderten vorhandenen Release.
Die Versionsarchive liegen unter `build/packages/`; `build/latest-artifact.txt`
enthält den archivierten DMG-Pfad und `build/latest-package.txt` den App-Pfad.
Eine SHA-256-Datei liegt neben `build/LocalSeek.dmg`. Die DMG wird erst nach Prüfung
veröffentlicht: Datenträger-Prüfsumme, Einhängen ohne Finder-Fenster, Signatur,
Architektur, gebündelte Bibliotheken, Modell-SHA-256 und Programme-Verknüpfung.
Sie enthält keine Nutzerquellen, Nutzerdatenbank oder Einstellungen des Build-Macs.
Der Offline-Test sperrt Netzwerkzugriffe nur für seinen eigenen Kindprozess.
Der zusätzliche Lasttest läuft mit dem App-Executable:

```bash
"/Pfad/LocalSeek.app/Contents/MacOS/LocalSeek" --benchmark --report /tmp/LocalSeek-Benchmark.json
```

Er verwendet temporäre synthetische Dokumente, 10.000 echte Testdateien und
100.000 Vektoren. Er greift nicht auf die eingerichteten Nutzerquellen zu.
Der normale Start und der CLI-Test teilen denselben nativen Code.

## Daten, Wiederaufnahme und Ressourcen

Datenbank: `~/Library/Application Support/LocalSeek/index.sqlite`; Modelle daneben
in `models/`. Verzeichnisrechte 0700, DB/WAL/SHM 0600. Keine Dokumentinhalte,
Dateipfade oder Suchanfragen in den exportierten Diagnosen. Der Index enthält
extrahierte Inhalte und gehört deshalb in ein geschütztes Benutzerkonto.

Metadaten, Extraktion, Einbettungen und Wartung werden dauerhaft als Jobs gespeichert.
Nach einem Absturz werden unterbrochene Jobs fortgesetzt. Neue Metadaten verdrängen
niedriger priorisierte Arbeit an Checkpoints. Vollständiger Abgleich/Integritätsprüfung
alle zwölf Stunden; der Programmstart gleicht die Metadaten vollständig ab und prüft
die Integrität nur, wenn die letzte Prüfung über zwölf Stunden zurückliegt.
Normale FSEvents betreffen gezielt einzelne Dateien bzw. Unterordner; verlorene Events
und große Ereignismengen lösen einen Vollscan aus. Entprellung zwei Sekunden,
höchstens fünf Sekunden bei laufenden Änderungen. Teilweise oder fehlgeschlagene
Scans löschen keine zwischengespeicherten Treffer. Umbenennungen behalten IDs/Vektoren,
sofern Geräte-/Inode-Identität und das tatsächliche Fehlen des alten Pfads sie bestätigen.
Unveränderte Metadaten werden übersprungen; der Vollscan schreibt weiterhin eine
Abgleichgeneration je Datei. Inhaltsänderungen werden an Zeitstempel, Größe und
Dateiidentität erkannt. Ein Überschreiben unter Beibehaltung aller drei Werte lässt
sich damit nicht erkennen; es gibt keinen pauschalen Inhalts-Hash aller Originaldateien.

Inhaltsjobs verarbeiten bis zu acht Dateien bzw. zwei Sekunden zwischen Dateien.
Embedding-Jobs verarbeiten bis zu 64 Chunks bzw. zwei Sekunden zwischen Paketen;
jeweils bis zu vier Texte werden gemeinsam berechnet und atomar gespeichert.
Embeddings werden bereits zwischen Inhaltsjobs erzeugt. Die Zeitbudgets unterbrechen
keinen gerade laufenden Parser oder eine einzelne Inferenz. Eine große Datei kann
deshalb länger dauern. Unveränderte Textabschnitte behalten vorhandene Vektoren.

Erfolgreiche OCR-Ergebnisse werden je Datei zwischengespeichert: höchstens 64 MiB
JSON-Nutzdaten und 32.768 Einträge, zuzüglich SQLite-Verwaltungsdaten; Inaktivität
über 30 Tage macht einen Eintrag ungültig. Rasterbytes, Sprache, OCR-Version und
macOS-Version bestimmen den Schlüssel. PDF-Seiten müssen dafür weiterhin gerendert
werden. Fehler/Timeouts werden nicht als Ergebnisse gespeichert. Quellenentfernung
löscht zugehörige Cache-Einträge; erfolgreiche Neuindizierung verwirft alte Seitenkeys.

Ab 50.000 Vektoren kann der Hintergrundworker einen HNSW-Graphen im RAM aufbauen.
Das geschätzte Speicherbudget beträgt ein Achtel des physischen RAM, höchstens 2 GiB.
Bei Speicherdruck wird der Graph freigegeben. Er wird nach einem Neustart neu aufgebaut;
SQLite bleibt die maßgebliche Datenquelle. Bis zur Fertigstellung, bei nicht passenden
Revisionen, Speichergrenzen und bei gesetzten Suchfiltern läuft die exakte Vektorsuche.
Änderungen/Löschungen werden über ein begrenztes Journal nachgeführt. HNSW liefert
Näherungskandidaten, die gegen aktuelle SQLite-Zeilen geprüft und exakt nachbewertet
werden; es gibt keine Garantie, jeden theoretisch besten Treffer zu finden.

Ein Hintergrundjob läuft jeweils aktiv. Inferenz nutzt bis zu zwei CPU-Threads plus
Metal; OCR läuft allein und mit niedriger Priorität.
OCR wird in einem mitgelieferten Hilfsprozess ausgeführt. Nach 30 Sekunden je Bild
oder gescannter PDF-Seite wird ein hängender Prozess beendet. Abbruch und Pause
beenden ihn ebenfalls. Die Datei erhält einen Fehler mit begrenzten Wiederholungen;
vorhandene Inhalte bleiben erhalten und die Queue arbeitet mit der nächsten Datei weiter.
Der Hilfsprozess benötigt keine separate Installation.

Hohe Temperatur pausiert Arbeit,
Stromsparmodus reduziert sie, Akkupause für OCR/KI ist optional. Dies sind kooperative
Grenzen; sie garantieren keine feste CPU-Prozentzahl für Apple-Systemparser.
Modelle werden nach 120 Sekunden Inaktivität freigegeben. Beim Beenden werden Jobs
angehalten, native Kontexte freigegeben und der WAL kontrolliert abgeschlossen.

## Signieren und Grenzen der Abnahme

Der private lokale Build verwendet eine ad-hoc-Signatur ohne Hardened Runtime:
Ohne Team-ID würde deren Library Validation das eigene Framework blockieren.
Das verändert keine macOS-Sicherheitseinstellung. Für eine Weitergabe mit Developer ID:
`LOCALSEEK_SIGN_IDENTITY` setzen; dann aktiviert das Skript Hardened Runtime und
Timestamp. Optional mit einem bereits eingerichteten `LOCALSEEK_NOTARY_PROFILE`
notarisieren und stapeln. Zertifikate/Zugangsdaten werden nicht automatisch angelegt.
Bei konfiguriertem Profil werden sowohl App als auch fertige DMG notariert und ihre
Tickets angeheftet/geprüft. Ein Fehler beendet den Release-Build vor Veröffentlichung
der neuen `build/LocalSeek.dmg`. Ohne Zertifikat/Profil entsteht ein privates Paket;
die enthaltenen Komponenten benötigen keine Nachinstallation, macOS kann seinen
Start aber weiter blockieren. Eine DMG allein löst diese Startblockade nicht.

Auf dem aktuellen Mac wurde keine gültige Signieridentität gefunden. Reale
OneDrive-Eviction/Synchronisationsunterbrechungen und macOS 14 benötigen noch eine
Abnahme auf der entsprechenden Installation. Simulierte Zustände und die tatsächliche
macOS-Materialisierungsrichtlinie sind automatisiert geprüft; das ersetzt keinen
Test eines konkreten OneDrive-Kontos.

Aktueller Stand 1.1.0: [Optimierungen](HANDOFF/INDEX-OPTIMIZATIONS-2026-10-18.md).
Historische Prüfergebnisse 1.0.0: [HANDOFF/FINAL-VALIDATION.md](HANDOFF/FINAL-VALIDATION.md).
Drittanbieter: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Stand der abschließenden Codeprüfung: 2026-10-17. Auf anschließende Nutzeranweisung
wurde der geprüfte Release inklusive Modell in `~/Applications/LocalSeek.app`
installiert; die vorherige App liegt als Sicherung unter `build/backups/`.
Eine weitere UI-Abnahme wurde nicht ausgeführt. Paketierung prüft vor dem Kopieren, dass
Quellstand, Abhängigkeitspins und Release-Build zusammenpassen.
