import AppKit

/// Own the settings window independently of the menu bar popover's scene.
@MainActor
final class SettingsWindowController {
    private let makeContent: @MainActor () -> NSView
    private let activate: @MainActor () -> Void
    private let makeWindow: @MainActor () -> NSWindow
    private(set) var window: NSWindow?

    init(makeContent: @escaping @MainActor () -> NSView,
         activate: @escaping @MainActor () -> Void = {
             NSApplication.shared.activate(ignoringOtherApps: true)
         },
         makeWindow: @escaping @MainActor () -> NSWindow = {
             NSWindow(contentRect: NSRect(x: 0, y: 0, width: 670, height: 470),
                      styleMask: [.titled, .closable, .miniaturizable],
                      backing: .buffered, defer: false)
         }) {
        self.makeContent = makeContent
        self.activate = activate
        self.makeWindow = makeWindow
    }

    func show() {
        if window == nil {
            _ = NSApplication.shared
            let created = makeWindow()
            created.title = "LocalSeek – Einstellungen"
            created.identifier = NSUserInterfaceItemIdentifier("LocalSeekSettings")
            created.isReleasedWhenClosed = false
            created.tabbingMode = .disallowed
            created.contentView = makeContent()
            created.center()
            window = created
        }
        activate()
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
