import CoreGraphics
import Foundation

/// A text client as the input method's take sees it: an IMKTextInput in
/// pFlow Dictation, a fake in pFlow's tests. Shared by both programs.
protocol MarkedTextClient: AnyObject {
    var bundle: String? { get }
    /// Shows `text` as replaceable marked text at the caret ("" takes it back out).
    func setMarked(_ text: String)
    /// Puts `text` in for good, over any marked text.
    func insert(_ text: String)
    /// Characters marked in the client now (0 when none).
    var markedLength: Int { get }
    /// The caret's rectangle on screen (Cocoa coordinates, origin bottom left), nil when unknown.
    var caretRect: CGRect? { get }
}

/// What the input method writes for one take, and through which client
/// (shared, so pFlow's tests cover every rule):
/// - marked text only to the client bound for the take, or the one on probation;
/// - the finished text only through a bound client that pFlow confirmed this take;
/// - marked text is taken back out with an empty mark in the very client that
///   holds it, never by inserting anything, and confirmed gone.
final class InputMethodTakeCore {
    private(set) var binding = InputMethodBinding()
    /// The marked text and the client that shows it.
    private(set) var marked = ""
    private var markedController: ObjectIdentifier?
    private var markedClient: MarkedTextClient?

    var hasMarks: Bool { !marked.isEmpty }

    func begin(bundle: String, after: TimeInterval) -> InputMethodBinding.Event {
        reset()
        return binding.begin(bundle: bundle, after: after)
    }

    func rebind(after: TimeInterval) -> InputMethodBinding.Event { binding.rebind(after: after) }

    func activated(_ activation: InputMethodBinding.Activation) -> InputMethodBinding.Event { binding.activated(activation) }

    /// The leftover client goes on probation if it is in the take's app and, when pFlow sent the
    /// target window's frame, its caret is inside that window.
    func probe(_ controller: ObjectIdentifier, client: MarkedTextClient, window: CGRect?) -> Bool {
        if let window, let caret = client.caretRect, caret != .zero,
           !window.insetBy(dx: -8, dy: -8).contains(CGPoint(x: caret.midX, y: caret.midY)) { return false }
        return binding.probe(controller, bundle: client.bundle)
    }

    func confirm() { binding.confirm() }

    func mayMark(_ controller: ObjectIdentifier?) -> Bool { binding.mayMark(controller) }
    func mayCommit(_ controller: ObjectIdentifier?) -> Bool { binding.mayCommit(controller) }

    /// The whole transcript as marked text in `client`; false when it is not the take's.
    func mark(_ text: String, controller: ObjectIdentifier, client: MarkedTextClient) -> Bool {
        guard binding.mayMark(controller) else { return false }
        // Words already shown in another client of the take (probation ended in a fresh one) come out first.
        if let markedClient, markedController != controller, !marked.isEmpty { markedClient.setMarked("") }
        client.setMarked(text)
        marked = text
        markedController = controller
        markedClient = client
        binding.marked = true
        return true
    }

    /// The finished text over the marked text, only through a confirmed client.
    func commit(_ text: String, controller: ObjectIdentifier, client: MarkedTextClient) -> Bool {
        guard binding.mayCommit(controller) else { return false }
        client.insert(text)
        marked = ""
        return true
    }

    /// The words shown stay exactly as they are, where the take was confirmed. Where it was not,
    /// they may be in the wrong place: they are taken back out instead.
    @discardableResult
    func keepAsIs() -> Bool {
        guard !marked.isEmpty, let markedClient else { return true }
        guard binding.mayCommit(markedController) else { return clear() }
        markedClient.insert(marked)
        marked = ""
        return true
    }

    /// Takes the marked text back out of the client that shows it: an empty
    /// mark, never an insert. True only when that client reports nothing marked.
    @discardableResult
    func clear() -> Bool {
        guard let markedClient else { marked = ""; return true }
        markedClient.setMarked("")
        marked = ""
        return markedClient.markedLength == 0
    }

    func end() {
        binding.end()
        reset()
    }

    private func reset() {
        marked = ""
        markedController = nil
        markedClient = nil
    }
}
