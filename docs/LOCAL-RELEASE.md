# GitHub Releases vom eigenen Mac

Der Mac baut, signiert und notarisiert die DMG und lädt sie anschließend zu GitHub
Releases hoch. Dafür läuft kein GitHub Runner. Das vorhandene Actions-Workflow ist
unabhängig davon: Solange seine Push-Trigger aktiv sind, läuft es bei Quellcode-Pushes
weiter. Der lokale Release-Upload selbst erstellt nur einen Tag und ein Release;
die derzeitigen Branch-Push-Trigger werden dadurch nicht ausgelöst.

## Einmalig auf dem Build-Mac

1. `Developer ID Application`-Zertifikat **mit privatem Schlüssel** in den
   Anmelde-Schlüsselbund importieren. Ein Apple-Development-Zertifikat reicht für
   diesen Veröffentlichungsweg nicht. `security find-identity -v -p codesigning`
   zeigt die verfügbare Signieridentität. Ein `.p12`-Export für GitHub ist bei
   diesem lokalen Weg nicht nötig.
2. GitHub CLI installieren, falls noch nicht vorhanden: `brew install gh`.
   Einmal `gh auth login --hostname github.com --git-protocol https --web` ausführen
   und beim Repository-Inhaber anmelden. Die Anmeldung muss Releases und Tags im
   Ziel-Repository schreiben können.
3. Ein anwendungsspezifisches Passwort im Apple-Account erstellen und einmal
   im Schlüsselbund speichern:

   ```bash
   xcrun notarytool store-credentials LocalSeek
   ```

   Die interaktiven Fragen mit Apple-Account, Developer-Team-ID und
   anwendungsspezifischem Passwort beantworten. Bei der Frage nach einem
   App-Store-Connect-API-Schlüssel keine Key-ID eingeben, um den Apple-Account-Weg
   zu verwenden. Es wird kein normales Apple-Passwort benötigt. `notarytool`
   prüft die Zugangsdaten beim Speichern. Sie kommen weder in den Quellcode noch
   in die lokale Konfigurationsdatei oder GitHub Secrets.
4. `.env.local.example` nach `.env.local` kopieren und die Signieridentität
   anpassen, vorzugsweise den vollständigen SHA-1-Identifikator aus Schritt 1.
   Diese lokale Shell-Konfiguration ist von Git ausgeschlossen. Auf dem bereits
   eingerichteten Arbeits-Mac ist sie mit der gefundenen Signieridentität
   vorbereitet. `LOCALSEEK_TEST_SIGN_IDENTITY` kann zusätzlich ein
   Apple-Development-Zertifikat für die lokalen XCTest-Bundles angeben. Eine
   macOS-Sicherheitsfreigabe für Entwicklerwerkzeuge muss lokal erfolgen.

## Bauen und hochladen

Aus dem Repository-Ordner:

```bash
LOCALSEEK_PUBLISH_RELEASE=1 Scripts/build.sh
```

Für dauerhaftes Hochladen beim normalen `Scripts/build.sh` in `.env.local` den
Standardwert von `LOCALSEEK_PUBLISH_RELEASE` von `0` auf `1` setzen. Mit
`LOCALSEEK_PUBLISH_RELEASE=0 Scripts/build.sh` lässt sich der Upload für einen
Aufruf ausschalten. Debug-Builds veröffentlichen nie ein Release. GitHub Actions
liest `.env.local` nicht ein und veröffentlicht über diesen Weg nichts.

Voraussetzungen ohne Build und ohne Upload prüfen:

```bash
bash Scripts/publish-release.sh --check
```

Der Quellstand muss sauber und committet sein; der Commit muss bereits im
Ziel-Repository auf GitHub existieren. Das Skript pusht keine Quellcodeänderungen
und verändert keine Branches. Es prüft die lokale Signieridentität, den
Notarisierungszugang und die GitHub-Anmeldung vor dem eigentlichen Build erneut.
Ein fehlender Zugang beendet den Vorgang früh; es gibt keinen Rückfall auf eine
ad-hoc-Signatur beim Veröffentlichen.

Jeder lokale Release-Build führt zunächst die vollständigen Unit- und
Integrationstests aus: einschließlich echtem OCR-Helper bei gesperrtem IP-Verkehr,
Embedding-Tests mit dem gepinnten Modell, OCR-Timeout/Abbruch und Fortsetzung der
Indexer-Queue. Auch ein blockierter Beschleuniger, der CPU-Kompatibilitätspfad,
sein Abbruch und das gemeinsame Zeitbudget werden geprüft. Hinzu kommen
Datenbankmigrationen und die Build-/Netzwerktests.
Fehler, übersprungene oder fehlende Tests stoppen den Build vor jeder
Apple-Einreichung. Testprozesse und einzelne Tests haben feste Zeitlimits.

Die Freigabe unter `build/reports/release-tests.json` gilt höchstens 24 Stunden,
ist an Commit, Quellen einschließlich Tests, macOS und Xcode gebunden und wird
bei jedem erneuten Testlauf zunächst entfernt. Auch direkte Aufrufe von
`package.sh --skip-build` und `publish-release.sh --publish` verlangen diese
Freigabe. Ein gezielter Vorabtest ist mit `bash Scripts/test-release.sh` möglich,
nachdem die Debug-Build-Voraussetzungen gebaut wurden.

Nach dem Build prüft es Quellstand, App-Version, Developer-ID-Team, sichere
Zeitstempel, Hardened Runtime, App-/DMG-Signaturen und beide angehefteten
Notarisierungstickets. Es führt Gatekeeper-Prüfung, vollständige DMG-Prüfung und
den Offline-Selbsttest mit dem gebündelten Modell und OCR-Helper aus. Erst danach
wird auf GitHub ein Tag für genau den gebauten Commit angelegt und das Release
mit DMG und portabler SHA-256-Datei veröffentlicht. GitHub CLI lädt zunächst die
Assets hoch und veröffentlicht anschließend das Release.

Der Offline-Test sperrt IPv4/IPv6 für App und Kindprozesse, einschließlich
Loopback, TCP/UDP und IP-Socket-Bindung. Lokale Unix-Sockets bleiben verfügbar:
Apple Vision/Core ML benötigt diese Kommunikation für die Modellinitialisierung.
Eine pauschale Sperre aller Socket-Arten kann deshalb auf neueren macOS-Versionen
OCR-Zeitüberschreitungen verursachen. Der Regressionstest prüft die IP-Sperre
gegen echte lokale Listener und die weiterhin erlaubte Unix-Kommunikation.

## Versionen und Wiederholungen

- `main`: reguläres Release, beispielsweise `v1.1.0`, als neuestes Release.
- `dev`: Vorabversion, beispielsweise `v1.1.0-dev.0123456789ab`; kein Ersatz für
  das neueste reguläre Release.
- Vorhandene Tags und Releases werden nicht überschrieben. Für eine weitere
  reguläre Version `MARKETING_VERSION` und bei Bedarf `CURRENT_PROJECT_VERSION`
  in `project.yml` erhöhen und den Stand committen/pushen. Für ein neues
  Dev-Release genügt ein neuer Quellcommit.
- Optional kann `LOCALSEEK_RELEASE_TAG` einen eigenen Tag vorgeben. Er muss mit
  `v` und einer Ziffer anfangen und darf Buchstaben, Ziffern, Punkte, Unterstriche
  und Bindestriche enthalten.
- Bei einem Netzwerkfehler nach der Tag-Erstellung können ein Tag und ein
  unvollständiger Release-Entwurf bestehen bleiben. Diese werden nicht automatisch
  entfernt oder überschrieben. Den fehlgeschlagenen Vorgang zuerst auf GitHub
  prüfen, bevor ein neuer Tag verwendet wird.

GitHub Releases bleiben bei einem privaten Repository für berechtigte Konten
zugänglich. Das macht das Repository nicht öffentlich. Signierung und
Notarisierung ändern diese Zugriffsbeschränkung nicht.

Quellen: [GitHub CLI Release Create](https://cli.github.com/manual/gh_release_create),
[Apple Notarisierung](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).
