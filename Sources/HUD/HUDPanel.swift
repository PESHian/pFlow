import AppKit
import SwiftUI

final class HUDPanel: NSPanel, NSWindowDelegate {
    private var positioning = false
    private let model: HUDModel
    /// Where the saved spot lives (tests pass a scratch domain).
    private let defaults: UserDefaults
    /// The spot the person dragged the capsule to. Only their own drag writes it.
    static let spotX = "pflow.hud.spot.x"
    static let spotY = "pflow.hud.spot.y"
    /// Before 0.3.21 every move was saved, AppKit's own on a resize too, so a spot
    /// saved under these names may be one nobody chose; it is not used.
    static let oldSpotKeys = ["pflow.hud.x", "pflow.hud.y"]
    /// The window's size when the person pressed on it to drag. A move counts as
    /// theirs only while it is set and the size is unchanged: AppKit's moves on a
    /// resize change the size, pFlow's own go through `reposition`, which clears it.
    private var dragSize: NSSize?

    init(model: HUDModel, defaults: UserDefaults = .standard) {
        self.model = model
        self.defaults = defaults
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
        // Closed when replaced by a fresh panel; ARC owns it, not AppKit.
        isReleasedWhenClosed = false
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
        dragSize = nil
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

        for key in Self.oldSpotKeys where defaults.object(forKey: key) != nil { defaults.removeObject(forKey: key) }
        // The window includes a transparent shadow margin, so offset by it to
        // keep the visible card where it looks right.
        var origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 40)
        var bounds = visible
        if defaults.object(forKey: Self.spotX) != nil {
            let spot = NSPoint(x: defaults.double(forKey: Self.spotX), y: defaults.double(forKey: Self.spotY))
            // The saved spot counts only on a screen that is there now; off every screen, bottom center.
            if let display = Self.display(showing: NSRect(origin: spot, size: size), among: NSScreen.screens.map(\.visibleFrame)) {
                origin = spot
                bounds = display
            }
        }
        origin.x = max(bounds.minX, min(origin.x, bounds.maxX - size.width))
        origin.y = max(bounds.minY, min(origin.y, bounds.maxY - size.height))
        if avoidingCaret {
            origin = HUDPlacement.origin(for: NSRect(origin: origin, size: size),
                                         avoiding: FocusedWindow.caretRect(), in: bounds)
        }
        setFrameOrigin(origin)
    }

    /// The screen area that shows most of `frame`; nil when none shows any of it
    /// (or the spot is not a number).
    static func display(showing frame: NSRect, among screens: [NSRect]) -> NSRect? {
        guard frame.origin.x.isFinite, frame.origin.y.isFinite else { return nil }
        func area(_ screen: NSRect) -> CGFloat {
            let shared = screen.intersection(frame)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        guard let best = screens.max(by: { area($0) < area($1) }), area(best) > 0 else { return nil }
        return best
    }

    @objc private func displaysChanged() { reposition() }

    /// The person pressed on the panel to drag it.
    func personBeganDrag() { dragSize = frame.size }

    /// Hidden: a drag that was going on is over.
    override func orderOut(_ sender: Any?) {
        dragSize = nil
        super.orderOut(sender)
    }

    /// Saves the spot only for the person's own drag: never pFlow's moves, never AppKit's on a resize.
    func windowDidMove(_ notification: Notification) {
        guard !positioning, let dragSize, frame.size == dragSize else { return }
        defaults.set(frame.origin.x, forKey: Self.spotX)
        defaults.set(frame.origin.y, forKey: Self.spotY)
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
    override func mouseDown(with event: NSEvent) {
        (window as? HUDPanel)?.personBeganDrag()
        window?.performDrag(with: event)
    }
}
