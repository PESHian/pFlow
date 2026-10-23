import AppKit
import SwiftUI

final class HUDPanel: NSPanel, NSWindowDelegate {
    private var positioning = false
    private let model: HUDModel
    init(model: HUDModel) {
        self.model = model
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
        hasShadow = false // the capsule draws its own look; the card turns the window shadow on

        let hosting = DraggableHUDView(rootView: RecordingHUDView(model: model))
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
        delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The card floats on a real window shadow; the capsule has none. The
    /// shadow follows the rounded card because the window itself is clear.
    func showsCardShadow(_ on: Bool) {
        guard hasShadow != on else { return }
        hasShadow = on
        invalidateShadow()
    }

    // Layout is forced before measuring: reading `fittingSize` while SwiftUI still has a stale layout returns the wrong size, so the panel would appear at one size and visibly snap to another.
    func reposition(avoidingCaret: Bool = false) {
        positioning = true
        defer { positioning = false }
        // Anchor to the screen holding the app being dictated into. Fall back to
        // the mouse's screen, then the main one, so the widget still lands
        // somewhere sensible when no focused window can be resolved.
        guard let screen = FocusedWindow.screen()
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        if model.livePreview {
            // Narrow screens get a narrower card instead of one that runs off the edge.
            model.previewMaxWidth = max(160, min(HUDModel.previewWidth, visible.width - 2 * Theme.s4))
        }

        contentView?.layoutSubtreeIfNeeded()
        let size = contentView?.fittingSize ?? NSSize(width: 120, height: 32)
        guard size.width > 0, size.height > 0 else { return }
        setContentSize(size)
        invalidateShadow()

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
        if avoidingCaret {
            origin = HUDPlacement.origin(for: NSRect(origin: origin, size: size),
                                         avoiding: FocusedWindow.caretRect(), in: bounds)
        }
        setFrameOrigin(origin)
    }

    @objc private func displaysChanged() { reposition() }
    func windowDidMove(_ notification: Notification) {
        guard !positioning else { return }
        UserDefaults.standard.set(frame.origin.x, forKey: "pflow.hud.x")
        UserDefaults.standard.set(frame.origin.y, forKey: "pflow.hud.y")
    }
}

enum HUDPlacement {
    /// Moves a card that would cover the text caret: above the caret when it
    /// fits on screen, otherwise below it. Left alone when neither fits.
    static func origin(for frame: NSRect, avoiding caret: NSRect?, in bounds: NSRect,
                       gap: CGFloat = Theme.s3) -> NSPoint {
        guard let caret, frame.intersects(caret.insetBy(dx: -gap / 2, dy: -gap / 2)) else { return frame.origin }
        let above = caret.maxY + gap
        if above + frame.height <= bounds.maxY { return NSPoint(x: frame.minX, y: above) }
        let below = caret.minY - gap - frame.height
        if below >= bounds.minY { return NSPoint(x: frame.minX, y: below) }
        return frame.origin
    }
}

private final class DraggableHUDView: NSHostingView<RecordingHUDView> {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
