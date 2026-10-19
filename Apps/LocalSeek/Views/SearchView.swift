import SwiftUI
import SharedCore

struct SearchView: View {
    @EnvironmentObject var index: IndexService
    enum Mode: String, CaseIterable { case filename = "Dateien", content = "Inhalt" }
    @State private var mode: Mode = .content
    @State private var strategy: SearchStrategy = .hybrid
    @State private var query = ""
    @State private var filtersOpen = false
    @State private var fileType = ""
    @State private var sourceID = ""
    @State private var path = ""
    @State private var minimumMB = ""
    @State private var maximumMB = ""
    @State private var useAfter = false
    @State private var useBefore = false
    @State private var after = Date()
    @State private var before = Date()
    @State private var favoritesOnly = false
    @State private var fileResults: [FileRecord] = []
    @State private var contentResults: [ContentSearchHit] = []
    @State private var selection: Int64?
    @State private var searchTask: Task<Void, Never>?
    @State private var searching = false
    @State private var resultLimit = 50
    @State private var preview: PreviewItem?
    @FocusState private var queryFocused: Bool

    struct PreviewItem: Identifiable, Equatable {
        let url: URL
        let cached: String?
        var snapshot: URL? = nil
        var id: String { url.path }
    }
    private var filters: SearchFilters {
        SearchFilters(extensions: Set(fileType.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }),
            sourceId: sourceID.isEmpty ? nil : sourceID, pathContains: path,
            after: useAfter ? Calendar.current.startOfDay(for: after) : nil,
            before: useBefore ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: before)) : nil,
            minimumBytes: bytes(minimumMB), maximumBytes: bytes(maximumMB), favoritesOnly: favoritesOnly)
    }
    private func bytes(_ value: String) -> Int64? {
        guard let number = Double(value.replacingOccurrences(of: ",", with: ".")), number.isFinite, number >= 0, number < 8e12 else { return nil }
        return Int64(number * 1_000_000)
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass")
                    TextField("Dateien und Inhalte suchen…", text: $query)
                        .font(.title3).textFieldStyle(.plain).focused($queryFocused)
                        .onSubmit { openSelected() }
                    if searching { ProgressView().controlSize(.small) }
                    Button { favoritesOnly.toggle() } label: { Image(systemName: favoritesOnly ? "star.fill" : "star") }.help("Nur Favoriten")
                    Button { filtersOpen.toggle() } label: { Image(systemName: "line.3.horizontal.decrease.circle") }.help("Filter")
                }
                HStack {
                    Picker("Suche", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) } }.pickerStyle(.segmented)
                    if mode == .content {
                        Picker("Suchart", selection: $strategy) {
                            Text("Hybrid").tag(SearchStrategy.hybrid)
                            Text("Exakt").tag(SearchStrategy.exact)
                            Text("Semantisch").tag(SearchStrategy.semantic)
                        }.pickerStyle(.segmented)
                    }
                }
                if filtersOpen { filterPanel }
                if !index.hasEmbeddingModel && mode == .content && strategy != .exact {
                    Text(strategy == .hybrid ? "Modell wird benötigt – die exakte Suche ist verfügbar." : "Für die semantische Suche bitte ein Modell wählen.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = index.lastError { Text(error).font(.caption).foregroundStyle(.red) }
            }.padding(12)
            Divider()
            results
            if (mode == .filename ? fileResults.count : contentResults.count) >= resultLimit && resultLimit < 500 {
                Button("Weitere Treffer laden") { resultLimit += 50; scheduleSearch(resetLimit: false) }.padding(6)
            }
            Divider()
            HStack {
                Text("Enter: öffnen · Leertaste: Vorschau · Esc: schließen")
                Spacer()
                Text(index.isPaused ? "Indizierung pausiert" : index.activity)
            }.font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear { focusQuery() }
        .onReceive(NotificationCenter.default.publisher(for: .init("LocalSeekFocusSearch"))) { _ in focusQuery() }
        .onChange(of: preview) { old, new in
            if old?.snapshot != new?.snapshot, let snapshot = old?.snapshot { try? FileManager.default.removeItem(at: snapshot.deletingLastPathComponent()) }
        }
        .onDisappear { searchTask?.cancel() }
        .onChange(of: query) { _, _ in scheduleSearch() }
        .onChange(of: mode) { _, _ in scheduleSearch() }
        .onChange(of: strategy) { _, _ in scheduleSearch() }
        .onChange(of: filters) { _, _ in scheduleSearch() }
        .onChange(of: index.favorites) { _, _ in if favoritesOnly { scheduleSearch() } }
        .onKeyPress(.escape) { NSApp.keyWindow?.orderOut(nil); return .handled }
        .onKeyPress(.space) {
            guard !queryFocused else { return .ignored }
            previewSelected(); return .handled
        }
        .sheet(item: $preview) { item in
            VStack {
                if let text = item.cached {
                    Text("Gespeicherter Inhalt – Originaldatei derzeit nicht lokal verfügbar")
                        .font(.headline).padding()
                    ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
                } else { QuickLookView(url: item.snapshot ?? item.url) }
                HStack {
                    Text(item.url.lastPathComponent).lineLimit(1)
                    Spacer()
                    Button("Original öffnen") { NSWorkspace.shared.open(item.url) }
                    Button("Schließen") { preview = nil }.keyboardShortcut(.cancelAction)
                }.padding()
            }.frame(minWidth: 640, minHeight: 480)
        }
    }
    private var filterPanel: some View {
        Grid(alignment: .leading) {
            GridRow {
                TextField("Typ: pdf, docx…", text: $fileType)
                Picker("Quelle", selection: $sourceID) {
                    Text("Alle Quellen").tag("")
                    ForEach(index.sources) { Text($0.displayPath).tag($0.id) }
                }
                TextField("Ordner / Pfad enthält…", text: $path)
            }
            GridRow {
                HStack { TextField("Min. MB", text: $minimumMB); TextField("Max. MB", text: $maximumMB) }
                HStack { Toggle("Ab", isOn: $useAfter); DatePicker("", selection: $after, displayedComponents: .date).labelsHidden().disabled(!useAfter) }
                HStack { Toggle("Bis", isOn: $useBefore); DatePicker("", selection: $before, displayedComponents: .date).labelsHidden().disabled(!useBefore) }
            }
            GridRow {
                Toggle("Nur Favoriten", isOn: $favoritesOnly)
                Text("Auch direkt: ext:pdf path:Projekte after:2026-01-01 minsize:1MB").font(.caption).foregroundStyle(.secondary)
                Button("Filter zurücksetzen") { fileType = ""; sourceID = ""; path = ""; minimumMB = ""; maximumMB = ""; useAfter = false; useBefore = false; favoritesOnly = false }
            }
        }.textFieldStyle(.roundedBorder).font(.callout)
    }
    @ViewBuilder private var results: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && filters.isEmpty {
            Spacer(); Text("Suchbegriff eingeben oder Filter wählen").foregroundStyle(.secondary); Spacer()
        } else if (mode == .filename && fileResults.isEmpty) || (mode == .content && contentResults.isEmpty) {
            Spacer(); Text(searching ? "Suche läuft…" : "Keine Treffer").foregroundStyle(.secondary); Spacer()
        } else {
            List(selection: $selection) {
                if mode == .filename {
                    ForEach(fileResults) { file in
                        hitRow(id: file.id ?? 0, name: file.filename, path: file.relativePath, state: file.state, location: "", snippet: "")
                            .tag(file.id ?? 0)
                            .contextMenu { actions(id: file.id ?? 0, source: file.sourceId, path: file.relativePath, state: file.state, cached: "Kein gespeicherter Inhalt für diese Datei.") }
                            .onTapGesture(count: 2) { open(source: file.sourceId, path: file.relativePath) }
                    }
                } else {
                    ForEach(contentResults) { hit in
                        hitRow(id: hit.fileId, name: hit.filename, path: hit.relativePath, state: hit.fileState, location: locationLabel(hit), snippet: hit.snippet)
                            .tag(hit.chunkId)
                            .contextMenu { actions(id: hit.fileId, source: hit.sourceId, path: hit.relativePath, state: hit.fileState, cached: hit.snippet) }
                            .onTapGesture(count: 2) { open(source: hit.sourceId, path: hit.relativePath) }
                    }
                }
            }.listStyle(.inset)
        }
    }
    private func hitRow(id: Int64, name: String, path: String, state: String, location: String, snippet: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack { Text(name).fontWeight(.medium); Text(location).font(.caption).foregroundStyle(.secondary)
                    if state != "present" { Text("Gespeichert / offline").font(.caption2).foregroundStyle(.orange) }
                }
                if !snippet.isEmpty { Text(highlighted(snippet)).lineLimit(3).font(.callout) }
                Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button { index.toggleFavorite(id) } label: { Image(systemName: index.favorites.contains(id) ? "star.fill" : "star") }.buttonStyle(.borderless).help("Favorit umschalten")
        }.padding(.vertical, 4)
    }
    private func locationLabel(_ hit: ContentSearchHit) -> String {
        switch hit.locationType { case "page": "Seite \(hit.locationValue)"; case "pageOCR": "Seite \(hit.locationValue) · OCR"; case "slide": "Folie \(hit.locationValue)"; case "none", "filename": ""; default: hit.locationValue }
    }
    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(); var rest = Substring(text)
        while let start = rest.firstIndex(of: "["), let end = rest[rest.index(after: start)...].firstIndex(of: "]") {
            result += AttributedString(String(rest[..<start]))
            var match = AttributedString(String(rest[rest.index(after: start)..<end])); match.inlinePresentationIntent = .stronglyEmphasized
            result += match; rest = rest[rest.index(after: end)...]
        }
        result += AttributedString(String(rest)); return result
    }
    @ViewBuilder private func actions(id: Int64, source: String, path: String, state: String, cached: String) -> some View {
        Button("Vorschau") { showPreview(source: source, path: path, state: state, cached: cached) }
        Button("Original öffnen") { open(source: source, path: path) }
        Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([url(source, path)]) }
        Button("Pfad kopieren") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url(source, path).path, forType: .string) }
        Button(index.favorites.contains(id) ? "Favorit entfernen" : "Als Favorit merken") { index.toggleFavorite(id) }
    }
    private func url(_ source: String, _ path: String) -> URL { URL(fileURLWithPath: source).appendingPathComponent(path) }
    private func open(source: String, path: String) { NSWorkspace.shared.open(url(source, path)) }
    private func showPreview(source: String, path: String, state: String, cached: String) {
        let target = url(source, path)
        let metadata = try? LocalFileMetadataProvider().metadata(for: target)
        guard state == "present", metadata?.isDataless == false, target.pathExtension.lowercased() != "html", target.pathExtension.lowercased() != "htm" else {
            preview = PreviewItem(url: target, cached: cached); return
        }
        Task {
            let snapshot = await Task.detached(priority: .userInitiated) { () -> URL? in
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("localseek-preview-" + UUID().uuidString)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    let dest = directory.appendingPathComponent(target.lastPathComponent)
                    try CoordinatedFileAccess().read(at: target) { source in
                        guard try LocalFileMetadataProvider().metadata(for: source).size <= 50 * 1024 * 1024 else { throw ExtractionError.resourceLimit }
                        try FileManager.default.copyItem(at: source, to: dest)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
                    }
                    return dest
                } catch { try? FileManager.default.removeItem(at: directory); return nil }
            }.value
            preview = PreviewItem(url: target, cached: snapshot == nil ? cached : nil, snapshot: snapshot)
        }
    }
    private func openSelected() {
        if mode == .filename, let file = fileResults.first(where: { $0.id == selection }) ?? fileResults.first { open(source: file.sourceId, path: file.relativePath) }
        else if let hit = contentResults.first(where: { $0.chunkId == selection }) ?? contentResults.first { open(source: hit.sourceId, path: hit.relativePath) }
    }
    private func previewSelected() {
        if mode == .filename, let file = fileResults.first(where: { $0.id == selection }) ?? fileResults.first { showPreview(source: file.sourceId, path: file.relativePath, state: file.state, cached: "Kein gespeicherter Inhalt für diese Datei.") }
        else if let hit = contentResults.first(where: { $0.chunkId == selection }) ?? contentResults.first { showPreview(source: hit.sourceId, path: hit.relativePath, state: hit.fileState, cached: hit.snippet) }
    }
    private func focusQuery() {
        queryFocused = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            queryFocused = true
        }
    }
    private func scheduleSearch(resetLimit: Bool = true) {
        if resetLimit { resultLimit = 50 }
        searchTask?.cancel(); let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = resultLimit
        let selectedFilters = filters; let selectedMode = mode; let selectedStrategy = strategy
        guard !text.isEmpty || !selectedFilters.isEmpty else { fileResults = []; contentResults = []; searching = false; return }
        searching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(150)); guard !Task.isCancelled else { return }
            if selectedMode == .filename {
                let hits = await index.searchAsync(text, filters: selectedFilters, limit: limit)
                guard !Task.isCancelled else { return }; fileResults = hits
            } else {
                let hits = await index.searchContentAsync(text, strategy: selectedStrategy, filters: selectedFilters, limit: limit)
                guard !Task.isCancelled else { return }; contentResults = hits
            }
            searching = false
        }
    }
}
