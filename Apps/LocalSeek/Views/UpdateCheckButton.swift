import SwiftUI

struct UpdateCheckButton: View {
    @ObservedObject var updates: UpdateController
    var body: some View {
        Button(updates.availableVersion.map { "Update \($0) anzeigen…" } ?? "Nach Updates suchen…") { updates.checkForUpdates() }
            .disabled(!updates.canCheck)
    }
}

struct UpdateMenuBarLabel: View {
    @ObservedObject var updates: UpdateController
    var body: some View {
        Label(updates.availableVersion == nil ? "LocalSeek" : "LocalSeek – Update verfügbar",
              systemImage: updates.availableVersion == nil ? "magnifyingglass" : "arrow.down.circle.fill")
    }
}
