import AppKit
import SwiftUI

final class HUDPanel: NSPanel, NSWindowDelegate {
    private var positioning = false
    init(model: HUDModel) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // the SwiftUI view draws its own soft shadow

        let hosting = DraggableHUDView(rootView: RecordingHUDView(model: model))
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
        delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Layout is forced before measuring: reading `fittingSize` while SwiftUI still has a stale layout returns the wrong size, so the panel would appear at one size and visibly snap to another.
    func reposition() {
        positioning = true
        defer { positioning = false }
        // Anchor to the screen holding the app being dictated into. Fall back to
        // the mouse's screen, then the main one, so the widget still lands
        // somewhere sensible when no focused window can be resolved.
        guard let screen = FocusedWindow.screen()
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main else { return }
        let visible = screen.visibleFrame

        contentView?.layoutSubtreeIfNeeded()
        let size = contentView?.fittingSize ?? NSSize(width: 120, height: 32)
        guard size.width > 0, size.height > 0 else { return }
        setContentSize(size)

        // The window includes a transparent shadow margin, so offset by it to
        // keep the visible card where it looks right.
        let defaults = UserDefaults.standard
        var origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 40)
        if defaults.object(forKey: "pflow.hud.x") != nil {
            origin = NSPoint(x: defaults.double(forKey: "pflow.hud.x"), y: defaults.double(forKey: "pflow.hud.y"))
        }
        let candidate = NSRect(origin: origin, size: size)
        let display = NSScreen.screens.max {
            let a = $0.visibleFrame.intersection(candidate)
            let b = $1.visibleFrame.intersection(candidate)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        } ?? screen
        let bounds = display.visibleFrame
        if !origin.x.isFinite || !origin.y.isFinite {
            origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.minY + 40)
        }
        origin.x = max(bounds.minX, min(origin.x, bounds.maxX - size.width))
        origin.y = max(bounds.minY, min(origin.y, bounds.maxY - size.height))
        setFrameOrigin(origin)
    }

    @objc private func displaysChanged() { reposition() }
    func windowDidMove(_ notification: Notification) {
        guard !positioning else { return }
        UserDefaults.standard.set(frame.origin.x, forKey: "pflow.hud.x")
        UserDefaults.standard.set(frame.origin.y, forKey: "pflow.hud.y")
    }
}

private final class DraggableHUDView: NSHostingView<RecordingHUDView> {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
