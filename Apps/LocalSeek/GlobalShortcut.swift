import AppKit
import Carbon
import SwiftUI

@MainActor
final class GlobalShortcut: ObservableObject {
    @Published private(set) var label = "⌘⇧Space"
    @Published var error: String?
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var currentCode: UInt32?
    private var currentModifiers: UInt32?
    var action: (() -> Void)?
    init() { label = UserDefaults.standard.string(forKey: "shortcutLabel") ?? "⌘⇧Space" }
    func start() {
        guard handler == nil else { return }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue().action?() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installStatus == noErr else { error = "Das globale Tastenkürzel konnte nicht eingerichtet werden."; return }
        let defaults = UserDefaults.standard
        let code = defaults.object(forKey: "shortcutCode") as? Int ?? kVK_Space
        let modifiers = defaults.object(forKey: "shortcutModifiers") as? Int ?? (cmdKey | shiftKey)
        let savedLabel = defaults.string(forKey: "shortcutLabel") ?? "⌘⇧Space"
        register(code: UInt32(exactly: code) ?? UInt32(kVK_Space), modifiers: UInt32(exactly: modifiers) ?? UInt32(cmdKey | shiftKey), label: savedLabel, persist: false)
    }
    func register(code: UInt32, modifiers: UInt32, label newLabel: String, persist: Bool = true) {
        if code == currentCode && modifiers == currentModifiers { error = nil; return }
        var replacement: EventHotKeyRef?
        let status = RegisterEventHotKey(code, modifiers, EventHotKeyID(signature: 0x4C53454B, id: 1), GetApplicationEventTarget(), 0, &replacement)
        guard status == noErr else { error = "Dieses Tastenkürzel ist bereits belegt. Bitte ein anderes wählen."; return }
        if let reference { UnregisterEventHotKey(reference) }
        reference = replacement; currentCode = code; currentModifiers = modifiers; label = newLabel; error = nil
        if persist {
            UserDefaults.standard.set(Int(code), forKey: "shortcutCode")
            UserDefaults.standard.set(Int(modifiers), forKey: "shortcutModifiers")
            UserDefaults.standard.set(newLabel, forKey: "shortcutLabel")
        }
    }
    func record(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control) else { error = "Bitte ⌘ oder Control mit einer weiteren Taste verwenden."; return }
        var modifiers: UInt32 = 0; var title = ""
        for (flag, carbon, text) in [(NSEvent.ModifierFlags.control, controlKey, "⌃"), (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")] where flags.contains(flag) { modifiers |= UInt32(carbon); title += text }
        title += event.keyCode == kVK_Space ? "Space" : (event.charactersIgnoringModifiers?.uppercased() ?? "Taste")
        register(code: UInt32(event.keyCode), modifiers: modifiers, label: title)
    }
    func stop() {
        if let reference { UnregisterEventHotKey(reference); self.reference = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        currentCode = nil; currentModifiers = nil
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @ObservedObject var shortcut: GlobalShortcut
    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton(); button.shortcut = shortcut; button.bezelStyle = .rounded
        button.target = button; button.action = #selector(RecorderButton.beginRecording)
        return button
    }
    func updateNSView(_ button: RecorderButton, context: Context) { if !button.recording { button.title = shortcut.label + " ändern…" } }
    final class RecorderButton: NSButton {
        weak var shortcut: GlobalShortcut?
        var recording = false
        override var acceptsFirstResponder: Bool { true }
        @objc func beginRecording() { recording = true; title = "Tastenkürzel drücken (Esc: abbrechen)"; window?.makeFirstResponder(self) }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording else { return super.performKeyEquivalent(with: event) }; keyDown(with: event); return true
        }
        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            if event.keyCode != kVK_Escape { shortcut?.record(event) }
            recording = false; title = (shortcut?.label ?? "") + " ändern…"
        }
        override func resignFirstResponder() -> Bool { recording = false; title = (shortcut?.label ?? "") + " ändern…"; return super.resignFirstResponder() }
    }
}
