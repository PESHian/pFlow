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
    /// Where typed text goes now: the start of the selection (nil when unknown).
    var caretLocation: Int? { get }
    /// The client's text in `range` (nil when it cannot be read).
    func text(in range: NSRange) -> String?
    /// How long the client's whole text is (nil when unknown).
    var textLength: Int? { get }
}

/// How taking marked words back out of a client went.
enum InputMethodTakeBack: String {
    /// Nothing marked, and the client's text around where they were does not hold them.
    case gone
    /// The client's text holds them: the app committed them itself (a blur, a click).
    case committed
    /// The client still reports marked text.
    case stillMarked
    /// The client's text around them could not be read: no proof either way.
    case unread

    /// Proven out of the client: pFlow may go on another way.
    var proven: Bool { self == .gone }
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
    /// Where the marked words began in that client.
    private var markStart: Int?
    /// How the last take-back went: asked again with nothing marked, the same answer.
    private var takeBack: InputMethodTakeBack?
    /// The words of the last take-back, where they began and the client, to look again.
    private var takenBack: (words: String, start: Int?, client: MarkedTextClient)?
    /// How much of the words' end is read back where they would be if committed, in UTF-16 units
    /// (an app keeps only a little text around the caret for input methods; Chrome about 100 units).
    static let tailLength = 60

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
        if markedController != controller || markStart == nil { markStart = client.caretLocation }
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
        guard binding.mayCommit(markedController) else { return clear() == .gone }
        markedClient.insert(marked)
        marked = ""
        return true
    }

    /// Takes the marked text back out of the client that shows it: an empty
    /// mark, never an insert. Gone only when that client reports nothing marked
    /// and its own text around where the words were does not hold them (an app
    /// can commit a composition itself, on a blur or a click, without telling
    /// the input method). Anything else is no proof, and pFlow pastes nothing.
    @discardableResult
    func clear() -> InputMethodTakeBack {
        guard let markedClient else { marked = ""; return .gone }
        if marked.isEmpty, let takeBack { return takeBack }
        let result = takeBackResult(markedClient)
        takeBack = result
        return result
    }

    private func takeBackResult(_ markedClient: MarkedTextClient) -> InputMethodTakeBack {
        let words = marked
        markedClient.setMarked("")
        marked = ""
        takenBack = (words, markStart, markedClient)
        return Self.verdict(words: words, start: markStart, client: markedClient)
    }

    /// Where the words are now, by the client's own reads (nothing written).
    static func verdict(words: String, start: Int?, client: MarkedTextClient) -> InputMethodTakeBack {
        guard client.markedLength == 0 else { return .stillMarked }
        let probe = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !probe.isEmpty else { return .gone }
        guard let start else { return .unread }
        // Where the client's caret is now: right after the words if the app committed them, back
        // where they began if they came out. Anything else, or no caret: no proof.
        guard let caret = client.caretLocation else { return .unread }
        let length = (words as NSString).length
        let head = min(length, Self.tailLength)
        if caret == start + length, length > 0 {
            guard let before = client.text(in: NSRange(location: caret - head, length: head)) else { return .unread }
            return before == (words as NSString).substring(from: length - head) ? .committed : .unread
        }
        guard caret == start else { return .unread }
        // Back at the start: the text there must not begin with the words. At the end of the text
        // there is nothing after the start (an app answers a read past its end with nothing at all),
        // and less text than the words cannot hold them.
        let available = client.textLength.map { max(0, $0 - start) }
        if available == 0 { return .gone }
        guard let after = client.text(in: NSRange(location: start, length: min(head, available ?? head))) else { return .unread }
        return after == (words as NSString).substring(to: head) ? .committed : .gone
    }

    /// The last take-back looked at again: an app can answer reads a moment late (Chromium answers
    /// from a cache of the page's text), so words read as still there may be gone a moment later.
    /// Nothing is written. No take-back on record: no proof.
    func recheck() -> InputMethodTakeBack {
        guard let takenBack else { return .unread }
        let result = Self.verdict(words: takenBack.words, start: takenBack.start, client: takenBack.client)
        takeBack = result
        return result
    }

    /// A take-back that is not proven at once is looked at again, `looks` times, `wait` apart, until
    /// proven gone. Never anything more: words still read as there (a cache that stays late longer
    /// than the looks, or an app that committed them) are left exactly as they are; pFlow then pastes
    /// nothing beside them and keeps the text on its card. pFlow Dictation never deletes text.
    /// On the main actor: a text client is only ever read from the main thread (read from a
    /// background thread, IMK answers nothing and every look reads as no proof).
    @MainActor
    func settle(_ first: InputMethodTakeBack, looks: Int, wait: () async -> Void) async -> InputMethodTakeBack {
        var result = first, left = looks
        while !result.proven, left > 0 {
            await wait()
            result = recheck()
            left -= 1
        }
        return result
    }

    func end() {
        binding.end()
        reset()
    }

    private func reset() {
        marked = ""
        markedController = nil
        markedClient = nil
        markStart = nil
        takeBack = nil
        takenBack = nil
    }
}
