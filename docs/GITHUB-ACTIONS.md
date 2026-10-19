# Automatischer Build von LocalSeek

## Branches und Ergebnis

- `dev`: laufende Entwicklung und Testpakete.
- `main`: stabiler Stand; Änderungen werden aus `dev` per Pull Request übernommen.
- Pushes auf beide Branches starten `.github/workflows/build.yml`. Ein lokaler
  Commit ohne Push löst keinen GitHub-Lauf aus. Unter Actions ist auch ein manueller
  Start für einen ausgewählten Branch möglich.
- Ein GitHub-Standard-Runner `macos-26` (Apple Silicon) baut und testet die App.
  Ein neuer Push bricht den älteren Lauf desselben Branches ab.
- Der Workflow installiert fehlende Build-Werkzeuge, lädt das gepinnte Modell,
  prüft dessen SHA-256 und cached Modell sowie Quellabhängigkeiten. Kompilierte
  CMake-/Xcode-Caches mit absoluten Pfaden werden nicht zwischen Maschinen geteilt.
- Erst nach Unit-/Integrationstests, Release-Build, DMG-Prüfung und Offline-Selbsttest
  wird das vollständige Paket unter Actions → Lauf → Artifacts hochgeladen.
  Das heruntergeladene Artefakt enthält `LocalSeek.dmg` und eine SHA-256-Datei.
- Je Branch bleibt der neueste erfolgreiche DMG-Download erhalten, maximal drei
  Tage. Fehlerdiagnosen bleiben höchstens einen Tag, maximal fünf Pakete. Frühere
  erfolgreiche Downloads werden nach einem fehlerhaften Build weiter aufbewahrt.
- GitHub Releases werden dadurch nicht automatisch veröffentlicht.

Die gespeicherte SHA-256-Datei lässt sich nach dem Entpacken mit
`shasum -a 256 LocalSeek.dmg` vergleichen. Der Eintrag in der Datei nennt den
ursprünglichen Build-Pfad; für die Benutzung der App sind keine Befehle nötig.

## Kostenloses Kontingent

Es wird kein größerer kostenpflichtiger Runner gewählt. Der Standard-Mac nutzt in
privaten Repositories die enthaltenen Actions-Minuten des Repository-Inhabers.
Bei GitHub Free sind dies nach aktueller Dokumentation 2.000 Minuten pro Monat,
500 MB gemeinsamer Artefakt-/Packages-Speicher sowie 10 GB Cache je Repository.
Der Workflow hält normalerweise nur zwei DMGs (zusammen ungefähr 250 MiB).
Andere Repositories und GitHub Packages teilen das Kontingent des Kontos.

Damit keine kostenpflichtige Mehrnutzung erfolgt, muss im GitHub-Konto unter
Settings → Billing & licensing → Budgets and alerts ein Actions-Budget von 0 mit
Nutzungsstopp gelten, beziehungsweise keine kostenpflichtige Mehrnutzung zugelassen
sein. Diese Kontoeinstellung kann die Workflow-Datei nicht selbst erzwingen. Es
werden keine Zahlungsdaten oder Budgets durch diesen Workflow geändert.

## Apple Developer ID und Notarisierung

Nur Builds von `main` verwenden Apple-Secrets. `dev`-Pakete werden privat ad-hoc
signiert. Sind noch keine Apple-Secrets gesetzt, baut auch `main` ein privates
Paket; dies ist in der Lauf-Zusammenfassung ausgewiesen. Eine teilweise ausgefüllte
Apple-Konfiguration beendet den Build mit einem Fehler, statt still zurückzufallen.

Im Repository unter Settings → Secrets and variables → Actions → New repository
secret diese fünf Einträge hinterlegen:

| Secret | Inhalt |
|---|---|
| `APPLE_CERTIFICATE_P12_BASE64` | Base64 des exportierten **Developer ID Application**-Zertifikats einschließlich privatem Schlüssel (`.p12`) |
| `APPLE_CERTIFICATE_PASSWORD` | Nicht leeres Passwort des `.p12`-Exports |
| `APPLE_ID` | Apple-Account für den Developer-Zugang |
| `APPLE_TEAM_ID` | Zehnstellige Team-ID aus dem Developer-Account |
| `APPLE_APP_SPECIFIC_PASSWORD` | Anwendungsspezifisches Passwort für `notarytool`, erzeugt im Apple-Account |

Die Apple-Developer-Mitgliedschaft muss freigeschaltet sein. Ein Zertifikat ohne
zugehörigen privaten Schlüssel reicht zum Signieren nicht. Ein gewöhnliches
Apple-Development-Zertifikat ist ebenfalls nicht der benötigte Zertifikatstyp.
Es ist kein Installer-Zertifikat für die DMG nötig. Die aktuelle App verwendet
keine besonderen Developer-ID-Capabilities, die ein Provisioning Profile erfordern.

Die Geheimwerte gehören in GitHub Secrets, nicht in Issues, Chatnachrichten,
Workflow-Dateien oder Commits. Zum Erstellen des Base64-Werts auf dem Mac kann
`base64 -i /Pfad/LocalSeek-Developer-ID.p12 | pbcopy` verwendet werden; die Ausgabe
landet in der Zwischenablage und wird beim Secret eingefügt.

Der Runner importiert das Zertifikat in eine temporäre Keychain, prüft Zertifikatstyp
und Team-ID und hinterlegt einen temporären Notarisierungszugang. App und DMG werden
signiert, bei Apple eingereicht und mit validierten Tickets versehen. Zugangsdaten
werden nach dem Lauf entfernt; der GitHub-Runner wird anschließend verworfen.
Eine neue Ausführung auf `main` übernimmt neu hinterlegte Secrets.

Die echte Signierung/Notarisierung lässt sich erst mit diesen Secrets prüfen.
Ein erster erfolgreicher GitHub-Lauf ist außerdem die Abnahme der Runner-Umgebung;
die zuvor lokal blockierte XCTest-Ausführung wird dadurch nicht vorab als bestanden
gewertet. Es gibt keine UI-Automation im Workflow.

Quellen: [GitHub-Runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners),
[GitHub-Abrechnung](https://docs.github.com/en/billing/concepts/product-billing/github-actions),
[Zertifikate auf Runnern](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications),
[Developer-ID-Zertifikate](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/).
