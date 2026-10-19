import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SharedCore

struct SettingsView: View {
    @EnvironmentObject var index: IndexService
    @EnvironmentObject var loginItem: LoginItemManager
    @EnvironmentObject var shortcut: GlobalShortcut
    @State private var confirmRebuild = false
    var body: some View {
        TabView {
            Form {
                Section("Start und Suche") {
                    Text("Beim Login: \(loginItem.statusText)")
                    if let error = loginItem.lastError { Text(error).font(.caption).foregroundStyle(.red) }
                    HStack { Button("Beim Login starten") { loginItem.register() }; Button("Deaktivieren") { loginItem.unregister() } }
                    HStack { Text("Globale Suche"); ShortcutRecorder(shortcut: shortcut).frame(height: 28) }
                    if let error = shortcut.error { Text(error).foregroundStyle(.red) }
                }
                Section("Hintergrundarbeit") {
                    Toggle("OCR und Einbettungen im Akkubetrieb pausieren", isOn: Binding(get: { index.pauseHeavyOnBattery }, set: index.setPauseHeavyOnBattery))
                    Text("Maximal zwei Inferenz-Threads. Bei hoher Temperatur pausiert der Index; Suchanfragen haben Vorrang.").font(.caption).foregroundStyle(.secondary)
                    Button(index.isPaused ? "Fortsetzen" : "Pausieren") { index.setPaused(!index.isPaused) }
                    Text(index.pauseReason ?? index.activity).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("Allgemein", systemImage: "gearshape") }
            VStack(alignment: .leading, spacing: 12) {
                Button("Ordner hinzufügen…") { chooseSourceFolder(index) }
                List(index.sources) { source in
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(source.displayPath, isOn: Binding(get: { source.isEnabled }, set: { index.setSourceEnabled(id: source.id, enabled: $0) }))
                        Text("\(source.fileCount) Dateien · \(stateText(source.state))").font(.caption).foregroundStyle(.secondary)
                        if let scan = source.lastScan { Text("Letzter Abgleich: \(scan.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                        HStack {
                            Button("Abgleichen") { index.rescanSource(id: source.id) }.disabled(!source.isEnabled)
                            Button("Auftrag abbrechen") { index.cancelSource(id: source.id) }
                            Spacer()
                            Button("Entfernen") { index.removeSource(id: source.id) }
                        }.controlSize(.small)
                    }.padding(.vertical, 4)
                }
                Text("Entfernen löscht nur den lokalen Index dieser Quelle. Originaldateien bleiben erhalten.").font(.caption).foregroundStyle(.secondary)
            }.padding().tabItem { Label("Quellen", systemImage: "folder") }
            Form {
                Section("Suchmodell") {
                    Text(index.modelName)
                    Button("GGUF-Modell wählen…") {
                        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "gguf")].compactMap { $0 }
                        if panel.runModal() == .OK, let url = panel.url { index.installModel(from: url) }
                    }
                }
                Section("Index und Diagnose") {
                    Text("\(index.status.fileCount) Dateien · \(index.status.chunkCount) Textabschnitte · \(index.status.embeddingCount) Einbettungen")
                    Text("Fehlgeschlagene Aufträge: \(index.jobs.failed) · Dateien: \(index.jobs.extractionFailures) · Einbettungen: \(index.jobs.embeddingFailures)")
                    Button("Diagnose exportieren…") {
                        let panel = NSSavePanel(); panel.nameFieldStringValue = "LocalSeek-Diagnose.json"; panel.allowedContentTypes = [.json]
                        if panel.runModal() == .OK, let url = panel.url { index.exportDiagnostics(to: url) }
                    }
                    Text("Diagnosen enthalten Zähler und Systemdaten; keine Dateipfade, Suchbegriffe oder Dokumentinhalte.").font(.caption).foregroundStyle(.secondary)
                    Button("Index neu aufbauen…") { confirmRebuild = true }
                }
            }.formStyle(.grouped).tabItem { Label("Modell und Diagnose", systemImage: "wrench.and.screwdriver") }
        }.frame(width: 670, height: 470)
        .alert("Index neu aufbauen?", isPresented: $confirmRebuild) {
            Button("Abbrechen", role: .cancel) { }
            Button("Neu aufbauen") { index.rebuildIndex() }
        } message: { Text("Gespeicherte Inhalte werden aus den eingerichteten Quellen erneut gelesen. Originaldateien und Favoriten bleiben erhalten. Offline-Inhalte sind bis zum erneuten Einlesen nicht verfügbar.") }
        .overlay(alignment: .bottom) { if let error = index.lastError { Text(error).font(.caption).foregroundStyle(.red).padding(8) } }
        .onAppear { index.refresh() }
    }
    private func stateText(_ state: SourceState) -> String {
        switch state { case .idle: "Bereit"; case .scanning: "Wird abgeglichen"; case .unavailable: "Quelle offline – gespeicherte Treffer bleiben erhalten"; case .error: "Fehler" }
    }
}
