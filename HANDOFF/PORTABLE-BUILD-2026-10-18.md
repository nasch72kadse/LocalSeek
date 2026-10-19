# Ein übertragbares Artefakt je Release-Build

Nutzeranforderung: Am Ende jedes Builds eine fertige Datei, die auf einen neuen Mac
kopiert werden kann. Keine manuellen Terminal-Befehle oder nachzuinstallierenden
Modelle/Bibliotheken auf dem Ziel-Mac.

Umgesetzt für Release-Builds:

- `Scripts/build.sh` baut standardmäßig Release und ruft anschließend automatisch
  die Paketierung auf. `Scripts/package.sh` delegiert ohne Rekursion an diesen
  Gesamtablauf. `--skip-build` verpackt nur einen passenden vorhandenen Release.
- Ergebnis immer `build/LocalSeek.dmg`; Versionsarchive unter `build/packages/`.
  Letzter archivierter Pfad in `build/latest-artifact.txt`; vorhandener App-Pointer
  `build/latest-package.txt` bleibt für Selbsttest/Benchmark erhalten.
- DMG enthält `LocalSeek.app`, Verknüpfung „Programme“ nach `/Applications` und
  `Installieren.txt`. Doppelklicken, App auf Programme ziehen, Laufwerk auswerfen,
  App starten. Modell, OCR-Helper, statische llama/ggml/HNSW-Komponenten, Metal und
  SharedCore sind enthalten. Keine Nutzerdaten vom Build-Mac.
- Vor Veröffentlichung wird die fertige DMG geprüft und ohne Finder-Fenster
  schreibgeschützt eingehängt: App-Signatur, arm64, alle dynamischen Abhängigkeiten
  systemeigen/gebündelt, Modell-SHA-256, Helper und Programme-Link. Danach wird die
  stabile DMG ersetzt; ältere Versionsarchive bleiben erhalten.
- Gemeinsamer Quellen-Nachweis für Build/Paketierung umfasst auch die Paket-
  skripte, Manifestdateien, Lizenztexte und mitgelieferte Anleitungen.
- Ein konfiguriertes Developer-ID-Zertifikat plus Notarisierungsprofil signiert
  und notarisiert automatisch App und DMG und prüft angeheftete Tickets.
  Scheitert ein Schritt, gilt der Gesamtablauf als fehlgeschlagen.
- Debug-Builds bleiben reine Entwicklungsbuilds ohne DMG.

## Tatsächlicher Prüfstatus

Der vollständige neue Ablauf `Scripts/build.sh` lief erfolgreich bis zur geprüften,
eingehängten und wieder ausgeworfenen DMG. Shell-Syntax und Diff geprüft. Version
1.1.0 Build 3, etwa 125 MiB, Ziel Apple Silicon / macOS 14+. Keine UI-Automation.

Archiv:
`build/packages/LocalSeek-1.1.0-20261018-193248-kfqcKp/LocalSeek-1.1.0-arm64.dmg`.
Der Digest steht in `build/LocalSeek.dmg.sha256`.

`security find-identity -v -p codesigning` meldete null gültige Identitäten. Dieser
Build ist deshalb privat ad-hoc signiert und nicht notariert. Die Notarisierungs-
schritte konnten hier nicht real ausgeführt werden. Die Datei enthält sämtliche
Laufzeitkomponenten; das garantiert keine Startfreigabe durch Gatekeeper und keine
Laufzeit auf einem anderen Mac. Die zuvor offene macOS-Startblockade wurde durch
die Paketierung nicht behoben. Keine macOS-Sicherheitsregel wurde verändert.

Für reguläre Distribution fehlen auf dem Build-Mac ein Developer-ID-Application-
Zertifikat (mit privatem Schlüssel) und ein Notarisierungsprofil. Auf dem Ziel-Mac
wären diese Entwicklungswerkzeuge/Zugangsdaten nicht erforderlich.

Die installierte 1.0.0 bleibt erhalten. Die DMG wurde nicht als App installiert oder
gestartet. Den vorherigen Teststatus dokumentiert
`INDEX-OPTIMIZATIONS-2026-10-18.md`.
