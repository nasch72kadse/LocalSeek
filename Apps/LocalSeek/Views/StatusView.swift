import SwiftUI
import UniformTypeIdentifiers

/// MenuBar-Popover: Index-Zähler, Quellenliste, Aktionen.
struct StatusView: View {
    @EnvironmentObject var index: IndexService
    @EnvironmentObject var loginItem: LoginItemManager
    let showSearch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LocalSeek").font(.headline)

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow { Text("Beim Login starten:"); Text(loginItem.statusText).foregroundStyle(.secondary) }
                GridRow { Text("Quellen:"); Text("\(index.status.sourceCount)").foregroundStyle(.secondary) }
                GridRow { Text("Dateien:"); Text("\(index.status.fileCount)").foregroundStyle(.secondary) }
                GridRow { Text("Textabschnitte:"); Text("\(index.status.chunkCount)").foregroundStyle(.secondary) }
                GridRow { Text("Aufträge:"); Text("\(index.jobs.pending) wartend / \(index.jobs.failed) Fehler").foregroundStyle(.secondary) }
                GridRow { Text("Einbettungen:"); Text("\(index.status.embeddingCount)").foregroundStyle(.secondary) }
            }
            .font(.callout)

            Text(index.pauseReason ?? index.activity).font(.caption).foregroundStyle(.secondary)
            Button(index.isPaused ? "Indizierung fortsetzen" : "Indizierung pausieren") { index.setPaused(!index.isPaused) }
            Button("Alle Quellen abgleichen") { for source in index.sources where source.isEnabled { index.rescanSource(id: source.id) } }
            Button {
                chooseModel()
            } label: {
                Label(index.hasEmbeddingModel ? "Modell wechseln…" : "Modell wählen…", systemImage: "cpu")
            }
            .font(.callout)

            if !index.sources.isEmpty {
                Divider()
                Text("Registrierte Quellen").font(.caption).foregroundStyle(.secondary)
                ForEach(index.sources) { src in
                    HStack {
                        Image(systemName: "folder")
                        Text(src.displayPath)
                        Spacer()
                        Text("\(src.fileCount)").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }

            if let err = index.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            Divider()

            Button {
                showSearch()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Suchen…", systemImage: "magnifyingglass")
            }

            HStack {
                Spacer()
                SettingsLink { Text("Einstellungen…") }
            }

            Button("Beenden") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            loginItem.refresh()
            index.refresh()
        }
    }

    /// Öffnet einen Dateidialog für eine GGUF-Modelldatei und installiert sie (SPEC §9: kein Auto-Download).
    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { index.installModel(from: url) }
    }
}
