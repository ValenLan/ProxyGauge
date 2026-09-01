import AppKit
import SwiftUI

enum MainWindowCapability {
    static func enableFullScreen(for window: NSWindow) {
        window.styleMask.insert(.resizable)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.standardWindowButton(.zoomButton)?.isEnabled = true
    }
}

struct MainWindowCapabilityReader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            MainWindowCapability.enableFullScreen(for: window)
        }
    }
}
