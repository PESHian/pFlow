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
    /// Replaces the client's text in `range` with `text` (the only use: pFlow's own words the app
    /// committed itself, taken back out of exactly where they are).
    func replace(_ range: NSRange, with text: String)
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
    /// The app had committed them itself; they came back out of exactly where they were, proven.
    case removed

    /// Proven out of the client: pFlow may go on another way.
    var proven: Bool { self == .gone || self == .removed }
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
    /// The app put the last mark in as typed text: it shows no marked text.
    private(set) var typedNotMarked = false
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
        // An app with no marked text takes a mark as typed text: nothing shows as marked.
        if !text.isEmpty, client.markedLength == 0 { typedNotMarked = true }
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
    func recheck() -> InputMethodTakeBack {
        guard let takenBack else { return takeBack ?? .gone }
        let result = Self.verdict(words: takenBack.words, start: takenBack.start, client: takenBack.client)
        takeBack = result
        return result
    }

    /// Words the app committed itself (it has no marked text, or committed them on a blur) come back
    /// out of exactly where they are: only while the client's text there is the words, start and end,
    /// with the caret right after them and nothing marked; then proven gone, or no proof.
    func removeCommitted() -> InputMethodTakeBack {
        guard let takenBack, let start = takenBack.start else { return takeBack ?? .unread }
        let words = takenBack.words, client = takenBack.client
        guard Self.verdict(words: words, start: start, client: client) == .committed else { return recheck() }
        let length = (words as NSString).length, head = min(length, Self.tailLength)
        guard client.text(in: NSRange(location: start, length: head)) == (words as NSString).substring(to: head) else {
            takeBack = .committed
            return .committed
        }
        client.replace(NSRange(location: start, length: length), with: "")
        let after = Self.verdict(words: words, start: start, client: client)
        takeBack = after == .gone ? .removed : after
        return takeBack!
    }

    /// The app took the last mark as typed text (nothing marked, the words in its text right before
    /// the caret): they come back out, as a take-back, and the take goes on without the input method.
    /// Nil when that is not what the client shows: the take carries on with its marks.
    func takeBackTyped() -> InputMethodTakeBack? {
        guard typedNotMarked, let markedClient else { return nil }
        typedNotMarked = false
        guard Self.verdict(words: marked, start: markStart, client: markedClient) == .committed else { return nil }
        takenBack = (marked, markStart, markedClient)
        marked = ""
        return removeCommitted()
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
        typedNotMarked = false
    }
}
