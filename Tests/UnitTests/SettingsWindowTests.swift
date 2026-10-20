import AppKit
import SwiftUI
import XCTest

final class SettingsWindowTests: XCTestCase {
    @MainActor
    func testClickActivatesAndPresentsARealHostedWindow() async {
        _ = NSApplication.shared
        var events: [String] = []
        let window = RecordingSettingsWindow()
        window.record = { events.append($0) }
        let content = NSHostingView(rootView: Text("Settings fixture"))
        let controller = SettingsWindowController(makeContent: { content },
            activate: { events.append("activate") }, makeWindow: { window })

        controller.show()

        XCTAssertTrue(controller.window === window)
        XCTAssertTrue(window.contentView === content)
        XCTAssertEqual(window.identifier?.rawValue, "LocalSeekSettings")
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertEqual(events, ["activate", "restore", "present"])
        // Window ordering is recorded, so this integration test never shows UI.
        XCTAssertFalse(window.isVisible)
        window.close()
    }

    @MainActor
    func testRepeatedClicksReuseTheWindowAndContentAndAlwaysPresentIt() async {
        _ = NSApplication.shared
        let window = RecordingSettingsWindow()
        var windows = 0, contents = 0, activations = 0
        let controller = SettingsWindowController(makeContent: {
            contents += 1
            return NSView()
        }, activate: { activations += 1 }, makeWindow: {
            windows += 1
            return window
        })

        controller.show()
        controller.show()

        XCTAssertEqual(windows, 1)
        XCTAssertEqual(contents, 1)
        XCTAssertEqual(activations, 2)
        XCTAssertEqual(window.presentations, 2)
        XCTAssertEqual(window.restorations, 2)
        window.close()
    }

    @MainActor
    func testCloseThenClickReopensTheRetainedWindow() async {
        _ = NSApplication.shared
        let window = RecordingSettingsWindow()
        var creations = 0
        let controller = SettingsWindowController(makeContent: { NSView() },
            activate: {}, makeWindow: { creations += 1; return window })
        controller.show()
        window.close()

        controller.show()

        XCTAssertTrue(controller.window === window)
        XCTAssertNotNil(window.contentView)
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(window.presentations, 2)
        XCTAssertEqual(window.restorations, 2)
        window.close()
    }
}

@MainActor
private final class RecordingSettingsWindow: NSWindow {
    var record: ((String) -> Void)?
    var presentations = 0
    var restorations = 0

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 670, height: 470),
                   styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    }

    override func deminiaturize(_ sender: Any?) {
        restorations += 1
        record?("restore")
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        presentations += 1
        record?("present")
    }
}
