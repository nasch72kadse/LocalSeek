import SwiftUI
import Quartz

/// Bettet eine native Quick-Look-Vorschau (`QLPreviewView`) in SwiftUI ein.
/// Zeigt die Originaldatei an, ohne sie zu verändern (nur Lesen).
struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        if (nsView.previewItem as? NSURL) as URL? != url {
            nsView.previewItem = url as NSURL
        }
    }
}
