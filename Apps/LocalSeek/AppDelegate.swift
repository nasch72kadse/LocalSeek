import AppKit
import SwiftUI
import IOKit.ps

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let index = IndexService()
    let loginItem = LoginItemManager()
    let shortcut = GlobalShortcut()
    private var searchWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        shortcut.action = { [weak self] in self?.showSearch() }
        shortcut.start()
        trace("finished-launching; shortcut: " + (shortcut.error ?? "ready"))
        for name in [ProcessInfo.thermalStateDidChangeNotification, NSNotification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.index.systemResourcesChanged() } })
        }
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated { Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().index.systemResourcesChanged() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
        if CommandLine.arguments.contains("--show-search") { showSearch() }
        else if index.sources.isEmpty { showOnboarding() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSearch(); return true
    }
    private func trace(_ text: String) {
        if CommandLine.arguments.contains("--diagnostic-ui") { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
    }
    func showSearch() {
        if searchWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "LocalSeek – Suchen"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SearchView().environmentObject(index))
            window.center(); searchWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); searchWindow?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .init("LocalSeekFocusSearch"), object: nil)
        trace("search-window-visible: \(searchWindow?.isVisible == true)")
    }
    func showOnboarding() {
        if onboardingWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "LocalSeek einrichten"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: OnboardingView().environmentObject(index).environmentObject(loginItem))
            window.center(); onboardingWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); onboardingWindow?.makeKeyAndOrderFront(nil)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }; terminating = true
        trace("shutdown-start")
        shortcut.stop()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
        Task { await index.shutdown(); trace("shutdown-complete"); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

struct OnboardingView: View {
    @EnvironmentObject var index: IndexService
    @EnvironmentObject var loginItem: LoginItemManager
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Deine Dateien lokal durchsuchen").font(.title2)
            Text("Wähle die Ordner, die LocalSeek durchsuchen darf. Texte und Suchmodell bleiben auf diesem Mac. Online-Dateien werden beim Indizieren nicht heruntergeladen.")
            Text(index.hasEmbeddingModel ? "Das Suchmodell ist bereit." : "Die Dateinamen- und Volltextsuche funktioniert sofort. Das gebündelte Modell wird für die semantische Suche geladen.").foregroundStyle(.secondary)
            Button("Ordner auswählen…") { chooseSourceFolder(index) }.buttonStyle(.borderedProminent)
            if !index.sources.isEmpty { Text("\(index.sources.count) Quelle(n) eingerichtet.").foregroundStyle(.secondary) }
            Button("Beim Anmelden automatisch starten (optional)") { loginItem.register() }
            if let error = loginItem.lastError { Text(error).font(.caption).foregroundStyle(.red) }
            Spacer()
            Text("Suche öffnen: ⌘⇧Space · Weitere Optionen in den Einstellungen.").font(.caption)
        }.padding(28).frame(width: 560, height: 480)
    }
}

@MainActor
func chooseSourceFolder(_ index: IndexService) {
    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
    panel.allowsMultipleSelection = true; panel.prompt = "Hinzufügen"
    if panel.runModal() == .OK { for url in panel.urls { index.addSource(url: url) } }
}
