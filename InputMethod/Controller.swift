import Cocoa
import InputMethodKit

/// One per text client. All the decisions are in `Link`; the controller only
/// reports activations and the person's own input, and never consumes a key.
@objc(PFlowInputController)
final class PFlowInputController: IMKInputController {
    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        Link.shared.activated(self, client: sender as? (IMKTextInput & NSObjectProtocol))
    }

    override func deactivateServer(_ sender: Any!) {
        Link.shared.deactivated(self)
        super.deactivateServer(sender)
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]).rawValue)
    }

    /// The person's own input. A key or a click while live words are shown:
    /// the words are committed exactly as they are (they never vanish), then
    /// the event goes on to the app untouched. Modifier changes (the held
    /// Right Command of push-to-talk) are not the person's input here.
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, event.type != .flagsChanged else { return false }
        Link.shared.personInput(event.type == .keyDown ? "key" : "click", controller: self)
        return false
    }

    /// The app ends the composition itself (a click elsewhere, focus moving):
    /// the live words stay as they are.
    override func commitComposition(_ sender: Any!) {
        Link.shared.appCommits(self)
    }
}
