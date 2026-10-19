# Große Bestände: Umsetzung ab 2026-10-18

Nutzerauftrag: die sechs vorgeschlagenen Optimierungen umsetzen bzw. den geeigneten
Vektorindex prüfen und integrieren, wenn er auf dem Zielsystem sinnvoll ist.
Keine UI-Automation. Bestehende Änderungen und Nutzerdaten erhalten.

- [x] Gezielte, dauerhaft vorgemerkte Datei-/Unterordnerabgleiche. Vollscan bei
      Start, manueller Anforderung, verlorenen Events und regelmäßiger Wartung.
      Rename-Erkennung, Cloud-Platzhalter und sichere Löschabgleiche erhalten.
- [x] Unveränderte Metadaten nicht erneut schreiben; FTS-Trigger nur bei Änderungen
      an Dateiname/Pfad. Inhaltsgröße zusätzlich zum Änderungszeitpunkt merken.
- [x] Begrenzte Inhaltsjobs, faire Reihenfolge und frühere Embeddings.
- [x] Embeddings in kleinen Paketen berechnen und atomar gesammelt speichern;
      Abbruch, Fehlerisolation, Text-/Modellversion und Speichergrenzen erhalten.
- [x] Persistenter OCR-Seitencache mit begrenzter Größe, Cache-Schlüssel aus
      Raster/Erkennungsparametern, keine Cache-Treffer nach Parser-/OCR-Wechsel.
- [x] Vektorindex für große Mengen evaluieren; Filter, aktuelle Daten und Löschungen
      korrekt halten, exakte Suche als Rückfall und kleine-Bestände-Variante behalten.
- [ ] Regressionen, Build und gezielte Vergleiche messen. Bisheriger macOS-Block
      beim Laden von xctest/CLI ist offen; keine bestandenen Tests behaupten,
      falls die Testausführung erneut vor dem Start blockiert wird.
- [x] Vollständiges Paket mit Modell/Helper, Dokumentation und nachvollziehbaren
      Grenzen erstellen. Vorherige Versionen als Rückfall erhalten.

Abschluss: 1.1.0 Build 3, 128 Tests erfolgreich kompiliert, Release/Paket geprüft.
Native Batch-Inferenz, HNSW mit 100k Vektoren und rohe Migrations-SQL erfolgreich.
Vollständiger XCTest-/Paket-Selbsttest bleibt offen (kein Teststart bzw. SIGKILL).
Paket `build/packages/LocalSeek-20261018-192457/LocalSeek.zip`.
Details: `HANDOFF/INDEX-OPTIMIZATIONS-2026-10-18.md`.

Repository: <REPOSITORY_ROOT>
Ausgangsstand: 1.0.1 Build 2 mit OCR-Prozessisolation, 106 Tests gebaut, Ausführung
durch macOS-Startblockade noch unbestätigt. Installiert ist weiterhin 1.0.0.
