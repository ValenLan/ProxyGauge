#if WINDOW_CAPABILITY_CHECK
import AppKit

@main
struct WindowCapabilityCheck {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 500),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        MainWindowCapability.enableFullScreen(for: window)
        guard window.titleVisibility == .hidden else {
            throw WindowCapabilityError.duplicateTitle
        }
        guard window.titlebarAppearsTransparent else {
            throw WindowCapabilityError.opaqueTitlebar
        }
        guard window.titlebarSeparatorStyle == .none else {
            throw WindowCapabilityError.titlebarSeparator
        }
        guard window.styleMask.contains(.resizable) else {
            throw WindowCapabilityError.notResizable
        }
        guard window.styleMask.contains(.fullSizeContentView) else {
            throw WindowCapabilityError.contentBelowTitlebar
        }
        guard window.collectionBehavior.contains(.fullScreenPrimary) else {
            throw WindowCapabilityError.notFullScreenPrimary
        }
        guard window.standardWindowButton(.zoomButton)?.isEnabled == true else {
            throw WindowCapabilityError.zoomButtonDisabled
        }
        print("ProxyGauge window capability tests passed.")
    }

    private enum WindowCapabilityError: Error {
        case notResizable
        case notFullScreenPrimary
        case zoomButtonDisabled
        case duplicateTitle
        case opaqueTitlebar
        case titlebarSeparator
        case contentBelowTitlebar
    }
}
#endif
