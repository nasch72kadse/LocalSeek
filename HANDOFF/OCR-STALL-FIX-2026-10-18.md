# OCR-Stall: Fix in LocalSeek 1.0.1, Build 2

Nutzerdiagnose: Ein synchroner Vision-Aufruf blockierte den einzigen Indexer-Worker.
Ein Task-Timeout um denselben blockierenden Aufruf würde dessen native Arbeit nicht
zuverlässig beenden. Die Originaldatei und der betroffene andere Mac lagen für die
Prüfung nicht vor.

## Änderung

- Vision-Texterkennung ist ausschließlich in `Contents/Helpers/LocalSeekOCR`.
- Pro Bild bzw. gescannter PDF-Seite gilt eine monotone Deadline von standardmäßig
  30 Sekunden. Der Elternprozess prüft Abbruch auch bei einem eigenen Context-Checkpoint.
- Bei Timeout, Abbruch oder einem Checkpoint-Fehler wird der Kindprozess per SIGKILL
  beendet. Das Aufräumen wartet höchstens weitere 0,5 Sekunden; kein `waitUntilExit`.
- Der Helper hat zusätzlich einen Watchdog und beendet sich, wenn der Elternprozess
  verschwindet oder seine eigene Frist abläuft.
- Es werden nur private lokale PNG-Snapshots übergeben, keine Originalpfade oder
  Datenbankzugänge. Keine Pipes, Netzwerke oder separaten Installationsschritte.
- `ocrTimeout`, `ocrFailed` und `ocrUnavailable` werden als Dateifehler gespeichert.
  Die vorhandene Retry-Grenze und Backoff-Regeln bleiben aktiv. Der letzte erfolgreiche
  Inhalt bleibt erhalten; nach dem Fehler folgen die nächsten Dateien/Quellen.
- Der Paket-Selbsttest enthält jetzt echte Texterkennung über den eingebetteten Helper.

## Regression und aktueller Prüfstatus

Sechs zusätzliche Unit-Tests: unkooperativer Prozess mit ignoriertem SIGTERM,
Task-Abbruch, Prozessfehler/ungültiges JSON, fehlender Helper, PDF-OCR-Timeout,
Queue-Fortsetzung über Dateien und Quellen mit Erhalt vorheriger OCR-Inhalte.
Die Fixtures enthalten ein synthetisches Bild mit 519 × 196 Pixeln.

Erfolgreich: Test-Build, Release-Build, Paket-Signaturen, arm64/macOS-14-Build-Ziel,
keine Homebrew-Laufzeitabhängigkeiten, Quellen-Nachweis, Archiv-CRC und Modell-SHA-256.

**Noch kein erfolgreicher Lauf der neuen Tests bestätigt.** Sowohl Xcodes Teststart
als auch der direkte xctest-Aufruf kamen nicht bis zur Testausführung. Der Stack-Snapshot
zeigt das Laden des Test-Bundles in dyld/Code-Signaturvalidierung (`fcntl`), keinen
OCR-Aufruf. Der Nutzer meldete einen Sicherheitsblock; welches Programm/Gerät und
welcher genaue Meldungstext gemeint sind, ist noch offen. Auch der neue Paket-CLI-Test
lieferte vor seiner Beendigung keine Ausgabe. Diese blockierten Prozesse wurden
angehalten. Es wurden keine macOS-Sicherheitseinstellungen verändert.

Die 100 erfolgreichen Tests vom 2026-10-17 betreffen Version 1.0.0 und sind keine
Laufzeitabnahme dieser Änderung. Für 1.0.1 sind 106 Tests gebaut; ein erfolgreicher
Lauf muss nach der macOS-Freigabe nachgeholt werden.

## Paket und Wiederaufnahme

Neues vollständiges Paket mit Modell:
`build/packages/LocalSeek-20261018-161143/LocalSeek.zip`.
SHA-256: `2085ae1eb278f2d22dee4be047495fa5f450fc822af30d5da82101552df4a6dd`.
Die Modell-Prüfsumme ist unverändert
`e011debc1208e31bf7b6aebee2d9fc8bd2ca11694a77ed66ac9d0c9d0a877c93`.

Version 1.0.1 wurde noch nicht in `~/Applications` installiert. Dort liegt weiterhin
die am 2026-10-17 installierte 1.0.0. Auf dem betroffenen anderen Mac muss nach der
Freigabe die alte App beendet und das komplette App-Bundle ausgetauscht werden.
Ein laufender alter Prozess enthält den Fix nicht.

Nach behobener Startblockade: `Scripts/test.sh` oder den bereits gebauten Test-Bundle
mit `xcrun xctest build/DerivedData/Build/Products/Debug/LocalSeekTests.xctest`
ausführen; danach `Scripts/verify-offline.sh` für das neue Paket.

Der Projektordner wurde zwischen den Sitzungen um eine Ebene verschoben. Aktueller
Repository-Pfad: `<REPOSITORY_ROOT>`.
Der CMake-Cache mit alten absoluten Pfaden wurde gesichert und neu aufgebaut.
Frühere absolute Paketpfade in den historischen Berichten sind deshalb veraltet.
