import AppKit
import SwiftUI

/// Opens and reuses standalone SwiftUI windows for a menu-bar (agent) app, where
/// SwiftUI's `Window`/`Settings` scenes are awkward to drive programmatically.
@MainActor
final class WindowManager {
    static let shared = WindowManager()
    private var windows: [String: NSWindow] = [:]

    func updateAppearance() {
        let mode = AppearanceSettings.shared.mode
        let appearance: NSAppearance? = mode == .system ? nil : NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
        for window in windows.values { window.appearance = appearance }
    }

    func show<Content: View>(
        id: String,
        title: String,
        size: NSSize,
        minSize: NSSize? = nil,
        resizable: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        if let existing = windows[id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = Self.makeWindow(title: title, size: size, minSize: minSize, resizable: resizable, content: content)
        windows[id] = window
        updateAppearance()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The window as `show` opens it, not yet on screen.
    static func makeWindow<Content: View>(
        title: String, size: NSSize, minSize: NSSize?, resizable: Bool, @ViewBuilder content: () -> Content
    ) -> NSWindow {
        let hosting = NSHostingController(rootView: content().modifier(PeshAppearance()))
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        window.styleMask = style
        window.setContentSize(size)
        // The hosting view does not stop the window shrinking under its
        // content, so the window's own minimum carries the content's minimum.
        window.contentMinSize = minSize ?? (resizable ? .zero : size)
        // A settings window has no full-screen mode: entering it would hide
        // the menu bar and stretch the page across the screen.
        window.collectionBehavior = [.fullScreenNone]
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.center()
        return window
    }
}
