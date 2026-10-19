# LocalSeek — Übergabe

Stand 2026-10-17. Der Rechnerwechsel und die v1-Nacharbeit sind umgesetzt.

Update 2026-10-18: [OCR-Stall-Fix 1.0.1](OCR-STALL-FIX-2026-10-18.md).
Code, Test-Build und Release-Paket sind erstellt. Die neuen Laufzeittests warten
noch auf die Klärung einer macOS-Startblockade; Version 1.0.1 ist noch nicht installiert.

- Bedienung, Build, Paketbau und Grenzen: [README](../README.md).
- Fertige App auf einen neuen Mac übertragen: [Installation](INSTALLATION.md).
- Aktuelle Code-Einstiegspunkte: [CLAUDE](../CLAUDE.md).
- Prüfnachweise/Messungen: [Abnahme](FINAL-VALIDATION.md).
- v1-Arbeitsliste: [WORK_PLAN](../WORK_PLAN.md).
- Früherer Phase-4-Stand: [historische Notizen](PHASE4-HISTORY-2026-10-16.md).
- Die [Setup-Prüfung](SETUP-2026-10-16.md) ist historische Dokumentation des
  Rechnerwechsels; ihr Homebrew-Buildweg wurde durch statische Paketierung ersetzt.

Für einen neuen Entwicklungs-Mac werden Xcode, Git, CMake und XcodeGen benötigt.
`Scripts/build.sh` beschafft und verifiziert die gepinnten Quellabhängigkeiten.
Die fertige App enthält die nativen Bibliotheken und das geprüfte GGUF-Modell und
benötigt diese Entwicklungswerkzeuge nicht.

Nicht auf diesem Mac nachweisbar: Laufzeit auf macOS 14/M1, echte OneDrive-Eviction
auf einer verbundenen Installation, Developer-ID/Notarisierung ohne Zertifikat.
Die dafür relevanten Codepfade und der Signierweg sind vorhanden; Prüfungen mit
simulierten Zuständen werden ausdrücklich als solche ausgewiesen.

Es wurden keine Commits, PRs, Veröffentlichungen oder Änderungen an Originaldokumenten vorgenommen.

Die automatisierte Suite umfasst 100 Tests; Messungen und Paketpfad stehen in der
Abnahme-Datei. Auf die anschließende Nutzeranweisung wurde der abschließende Release
am 2026-10-17 mit eingebettetem Modell in `~/Applications/LocalSeek.app` installiert.
Die alte App ist unter `build/backups/pre-final-install-20261017-080851/LocalSeek.app`
gesichert. Es gab keine weitere UI-Automation. Der zusätzliche CLI-Test war bei
gesperrtem Netzwerk und gesperrten externen Modell-/Homebrew-Ordnern erfolgreich.
