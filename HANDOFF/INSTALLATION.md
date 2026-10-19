# LocalSeek installieren und übertragen

Das fertige Paket enthält LocalSeek 1.1.0, den OCR-Hilfsprozess, das Suchmodell
`multilingual-e5-small-q8_0.gguf`, die nativen Bibliotheken und die Metal-Laufzeit.
Zur Benutzung werden keine zusätzlichen Modelle, Python, Ollama, Homebrew,
Xcode oder sonstigen Entwicklungswerkzeuge benötigt. Die Suche arbeitet lokal.

## Neuer Mac

Voraussetzung: Mac mit Apple Silicon (M1 oder neuer), macOS 14 oder neuer.
Das Paket ist für arm64 gebaut; Windows und Intel-Macs werden nicht unterstützt.
Praktisch geprüft wurde es auf macOS 27.0.1 mit Apple M3. macOS 14/M1 sind das
Build-Ziel, aber auf dieser Hardware nicht separat als Laufzeit getestet.

1. `LocalSeek.dmg` auf den neuen Mac kopieren und doppelklicken.
2. `LocalSeek.app` auf die Verknüpfung „Programme“ ziehen. Danach das Laufwerk
   „LocalSeek“ im Finder auswerfen.
3. LocalSeek aus „Programme“ starten und die zu durchsuchenden Ordner auswählen. Die App verwendet
   das enthaltene Modell automatisch und erstellt den Index auf diesem Mac.

Die nötigen Ordnerfreigaben erteilt macOS beim Auswählen der Quellen. Der private
Build ist ad-hoc signiert und nicht notariert; macOS kann deshalb vor dem ersten
Start eine ausdrückliche Freigabe verlangen. Ein zusätzlicher Modell-Download ist
davon unabhängig nicht erforderlich.

## Ergebnis jedes Release-Builds

`Scripts/build.sh` erzeugt und prüft automatisch `build/LocalSeek.dmg`. Diese Datei
ist das vollständige Übertragungsartefakt; auf dem Ziel-Mac sind keine Terminal-
Befehle und keine Paketmanager nötig. Alte Versionspakete bleiben unter
`build/packages/` erhalten. Der letzte archivierte DMG-Pfad steht in
`build/latest-artifact.txt`, die Prüfsumme in `build/LocalSeek.dmg.sha256`.
Debug-Builds dienen der Entwicklung und erzeugen keine DMG.

Der Build-Mac braucht das bereits lokal vorhandene Modell und die Entwicklungs-
werkzeuge. Der Ziel-Mac bekommt ausschließlich die fertige App mit ihren
Laufzeitkomponenten. Ein neuer Index wird dort aus den gewählten Ordnern aufgebaut;
Nutzerdaten des Build-Macs werden nicht übertragen.

Für eine reguläre Weitergabe außerhalb des App Store müssen auf dem Build-Mac
ein Developer-ID-Application-Zertifikat und ein Notarisierungsprofil eingerichtet
sein. Danach verwendet der Build `LOCALSEEK_SIGN_IDENTITY` und
`LOCALSEEK_NOTARY_PROFILE` automatisch für App und DMG. Die Zugangsdaten bleiben
auf dem Build-Mac. Ohne diese Einrichtung entsteht ein privates, nicht notariertes
Paket; Startfreigabe und tatsächliche Laufzeit auf einem anderen Mac sind damit
nicht garantiert. Die frühere Sicherheitsblockade wird durch das neue Dateiformat
allein nicht behoben.

## Installation auf diesem Mac, 2026-10-17 (Version 1.0.0)

- App: `~/Applications/LocalSeek.app`
- Geprüftes Paket: `build/packages/LocalSeek-20261017-075042/LocalSeek.zip`
- Alte App: `build/backups/pre-final-install-20261017-080851/LocalSeek.app`
- Benutzerquellen, Suchindex und Einstellungen wurden durch die Installation nicht geändert.

Der CLI-Test mit gesperrtem Netzwerk, externem Modellordner und Homebrew war
erfolgreich. Die installierte App ist inhaltlich identisch mit dem geprüften Paket.
Eine zusätzliche UI-Prüfung wurde nicht ausgeführt.

## Update 1.0.1, 2026-10-18

Das Paket `build/packages/LocalSeek-20261018-161143/LocalSeek.zip` enthält den OCR-Fix.
Es ist noch nicht installiert; die neue Testausführung ist wegen einer macOS-Startblockade
offen. Der [Prüfstatus](OCR-STALL-FIX-2026-10-18.md) unterscheidet Build-Prüfung und
noch ausstehende Laufzeittests.

## Update 1.1.0, 2026-10-18

Die Optimierungen und der aktuelle Prüfstatus stehen in
[Index-Optimierungen](INDEX-OPTIMIZATIONS-2026-10-18.md). Der DMG-Build prüft die
Vollständigkeit des Pakets, ersetzt aber keine erfolgreiche Laufzeitabnahme.
Installiert ist weiterhin Version 1.0.0; die übertragbaren Pakete liegen separat.
