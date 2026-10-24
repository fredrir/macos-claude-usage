import AppKit
import SwiftUI

/// Keeps the settings page from opening with a text control already focused.
///
/// The shortcut recorder is a search field, so the window hands it the initial focus whenever the page
/// has no SwiftUI text field to focus first — and it starts recording straight away. Nothing in the page
/// should own focus on open.
struct WindowInitialFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ClearingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class ClearingView: NSView {
    private var keyObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
            self.keyObserver = nil
        }

        guard let window else { return }

        clearTextFocus(in: window)

        // The settings window hides instead of closing, so it becomes key again each time the page is reopened.
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: nil
        ) { [weak window] _ in
            guard let window else { return }
            clearTextFocus(in: window)
        }
    }
}

/// Drops the window's first responder while a text control owns it, so the recorder falls back to its idle state
/// instead of waiting for a shortcut.
private func clearTextFocus(in window: NSWindow) {
    // The window installs its initial focus as it appears, so let that settle first.
    Task { @MainActor in
        guard let responder = window.firstResponder, responder is NSText || responder is NSTextField else {
            return
        }
        window.makeFirstResponder(nil)
    }
}
