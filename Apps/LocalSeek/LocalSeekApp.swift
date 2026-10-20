import SwiftUI
import ServiceManagement
import OSLog

struct LocalSeekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        MenuBarExtra("LocalSeek", systemImage: "magnifyingglass") {
            StatusView(showSearch: delegate.showSearch, showSettings: delegate.showSettings)
                .environmentObject(delegate.index)
                .environmentObject(delegate.loginItem)
        }.menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Einstellungen…", action: delegate.showSettings)
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

/// Steuert „Beim Login starten" über SMAppService.mainApp und spiegelt dessen Status.
@MainActor
final class LoginItemManager: ObservableObject {
    @Published var statusText: String = "unbekannt"
    @Published var isEnabled = false
    @Published var lastError: String?

    private let log = Logger(subsystem: "com.localseek.app", category: "loginitem")
    private let service = SMAppService.mainApp

    init() { refresh() }

    func refresh() {
        switch service.status {
        case .enabled:
            statusText = "aktiv"; isEnabled = true
        case .requiresApproval:
            statusText = "Genehmigung erforderlich"; isEnabled = false
        case .notRegistered:
            statusText = "nicht registriert"; isEnabled = false
        case .notFound:
            statusText = "App nicht verfügbar"; isEnabled = false
        @unknown default:
            statusText = "unbekannt"; isEnabled = false
        }
    }

    func register() {
        lastError = nil
        do {
            try service.register()
            log.info("Als Login-Item registriert")
        } catch {
            lastError = "macOS hat den Autostart nicht eingerichtet. Bitte LocalSeek aus dem Programme-Ordner starten und erneut versuchen."
            log.error("Registrierung fehlgeschlagen")
        }
        refresh()
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func unregister() {
        do { try service.unregister(); lastError = nil }
        catch { lastError = "Der Autostart konnte nicht deaktiviert werden." }
        refresh()
    }
}
