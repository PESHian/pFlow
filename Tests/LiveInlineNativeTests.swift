import AppKit
import ApplicationServices
import Testing
@testable import Yap

/// A window the test owns, holding one real AppKit text control. Nothing here
/// touches another app, posts key events, or reads the clipboard's contents.
@MainActor
final class NativeTextWindow {
    let window: NSWindow
    let control: NSView

    init(_ control: NSView) {
        self.control = control
        window = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 520, height: 220),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "pFlow live typing test"
        let content = NSView(frame: window.contentLayoutRect)
        control.frame = content.bounds.insetBy(dx: 12, dy: 12)
        if control is NSTextField { control.frame.size.height = 24 }
        content.addSubview(control)
        window.contentView = content
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(control)
    }

    static func textView(_ text: NSAttributedString, selection: NSRange) -> (NativeTextWindow, NSTextView) {
        let view = NSTextView(frame: .zero)
        view.isRichText = true
        view.textStorage?.setAttributedString(text)
        let window = NativeTextWindow(view)
        view.setSelectedRange(selection)
        return (window, view)
    }

    static func textField(_ text: String, secure: Bool = false) -> (NativeTextWindow, NSTextField) {
        let field = secure ? NSSecureTextField(string: text) : NSTextField(string: text)
        let window = NativeTextWindow(field)
        field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        return (window, field)
    }

    func close() {
        window.orderOut(nil)
        window.close()
    }
}

/// The control's own AppKit accessibility implementation, called in process.
/// Needs no permission, so it runs on every test host. An NSTextField does
/// not apply a selected-text change made this way on itself, so its field
/// editor (the text view that holds the text while it is edited) is used.
@MainActor
final class InProcessAccessibilityField: LiveTextField {
    private let control: NSView
    private let window: NSWindow
    private var view: NSView { (control as? NSTextField)?.currentEditor() as? NSTextView ?? control }

    init(_ host: NativeTextWindow) {
        control = host.control
        window = host.window
    }

    private var focused: Bool {
        window.firstResponder === view
    }

    func state() -> LiveFieldState {
        LiveFieldState(app: getpid(), element: focused ? LiveFieldState.target : "other",
                       secure: control is NSSecureTextField || control.accessibilitySubrole() == .secureTextField,
                       trusted: true, value: view.accessibilityValue() as? String,
                       selection: view.accessibilitySelectedTextRange())
    }

    func canWriteRanges(keeping selection: NSRange) -> Bool {
        select(selection) && view.accessibilitySelectedTextRange() == selection
    }

    func select(_ range: NSRange) -> Bool {
        view.setAccessibilitySelectedTextRange(range)
        return true
    }

    func replace(_ range: NSRange, with text: String) -> Bool {
        _ = select(range)
        view.setAccessibilitySelectedText(text)
        return true
    }
}

/// Real Accessibility calls into the test's own window, exactly as pFlow
/// talks to another app. Only possible when the test host is trusted.
@MainActor
private func axField(_ host: NativeTextWindow) -> LiveTextField? {
    let app = AXUIElementCreateApplication(getpid())
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
          let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return AXLiveTextField(pid: getpid(), element: value as! AXUIElement)
}

@MainActor
struct LiveInlineNativeTests {
    typealias FieldMaker = (NativeTextWindow) -> LiveTextField?

    private func begin(_ field: LiveTextField?) throws -> LiveInlineSession {
        let field = try #require(field)
        switch LiveInlineSession.begin(id: UUID().uuidString, field: field) {
        case .success(let session): return session
        case .failure(let stop):
            Issue.record("live typing refused: \(stop)")
            throw stop
        }
    }

    // MARK: Scenarios, run by each field kind below

    /// Unicode in and around the span, CRLF after it, styled text on both
    /// sides, recognizer revisions, then the final once.
    private func unicodeAndFormatting(_ make: FieldMaker) throws {
        let bold = NSFont.boldSystemFont(ofSize: 14)
        let text = NSMutableAttributedString(string: "Hi 👋🏽 ", attributes: [.font: bold])
        text.append(NSAttributedString(string: "\r\n— cafe\u{301} 中文", attributes: [.foregroundColor: NSColor.systemRed]))
        let (host, view) = NativeTextWindow.textView(text, selection: NSRange(location: 8, length: 0))
        defer { host.close() }
        let session = try begin(make(host))
        for words in ["Merci 🙏 à", "Merci 🙏 à bientôt", "Merci 🙏 à bientôt 再见", "Merci 🙏 à bientôt 再见"] {
            #expect(session.update(words) == nil, "\(words)")
        }
        #expect(Array(view.string.utf16) == Array("Hi 👋🏽 Merci 🙏 à bientôt 再见\r\n— cafe\u{301} 中文".utf16))
        #expect(session.update("Merci 🙏 a bientot") == nil)
        #expect(session.finalize("Merci 🙏, à bientôt 再见。") == .applied)
        let expected = "Hi 👋🏽 Merci 🙏, à bientôt 再见。\r\n— cafe\u{301} 中文"
        #expect(Array(view.string.utf16) == Array(expected.utf16))
        #expect(view.selectedRange() == NSRange(location: 31, length: 0))
        let storage = try #require(view.textStorage)
        #expect(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == bold)
        #expect(storage.attribute(.font, at: 7, effectiveRange: nil) as? NSFont == bold)
        let after = (expected as NSString).range(of: "\r\n").location
        var red = NSRange()
        #expect(storage.attribute(.foregroundColor, at: after, effectiveRange: &red) as? NSColor == .systemRed)
        #expect(NSMaxRange(red) == storage.length)
    }

    private func selectionCancel(_ make: FieldMaker) throws {
        let (host, view) = NativeTextWindow.textView(NSAttributedString(string: "Pack the old tent today"),
                                                     selection: NSRange(location: 9, length: 8))
        defer { host.close() }
        let session = try begin(make(host))
        _ = session.update("new")
        _ = session.update("new canvas")
        _ = session.update("new canvas tarp")
        #expect(view.string == "Pack the new canvas today")
        #expect(session.cancel() == .removed)
        #expect(view.string == "Pack the old tent today")
        #expect(view.selectedRange() == NSRange(location: 9, length: 8))
    }

    /// The person's own edit, made straight to the text, with no key events.
    private func userEditInBetween(_ make: FieldMaker) throws {
        let (host, view) = NativeTextWindow.textView(NSAttributedString(string: "Title\n"), selection: NSRange(location: 6, length: 0))
        defer { host.close() }
        let session = try begin(make(host))
        _ = session.update("Draft")
        _ = session.update("Draft notes")
        #expect(view.string == "Title\nDraft")
        view.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 5), with: "Topic")
        #expect(session.update("Draft notes for") == .text)
        #expect(session.update("Draft notes for Monday") == nil)
        #expect(session.finalize("Draft notes for Monday.") == .kept(.text))
        #expect(session.cancel() == .left(.text))
        #expect(view.string == "Topic\nDraft")
    }

    private func caretMoved(_ make: FieldMaker) throws {
        let (host, view) = NativeTextWindow.textView(NSAttributedString(string: "Dear Sam,\n"), selection: NSRange(location: 10, length: 0))
        defer { host.close() }
        let session = try begin(make(host))
        _ = session.update("Thanks for")
        _ = session.update("Thanks for the map")
        view.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(session.update("Thanks for the map and") == .caret)
        view.setSelectedRange(NSRange(location: 20, length: 0))
        #expect(session.finalize("Thanks for the map and compass.") == .kept(.caret))
        #expect(view.string == "Dear Sam,\nThanks for")
    }

    private func templateFinal(_ make: FieldMaker) throws {
        let (host, view) = NativeTextWindow.textView(NSAttributedString(string: ""), selection: NSRange(location: 0, length: 0))
        defer { host.close() }
        let session = try begin(make(host))
        _ = session.update("Use the police report")
        _ = session.update("Use the police report template. Officer")
        #expect(view.string == "Use the police report")
        #expect(session.finalize("Narrative\nOfficer Pesh arrived.\n\nNo one was hurt.") == .applied)
        #expect(view.string == "Narrative\nOfficer Pesh arrived.\n\nNo one was hurt.")
    }

    private func textField(_ make: FieldMaker) throws {
        let (host, field) = NativeTextWindow.textField("Subject: ")
        defer { host.close() }
        let session = try begin(make(host))
        _ = session.update("Boat")
        _ = session.update("Boat trip")
        #expect(field.currentEditor()?.string == "Subject: Boat")
        #expect(session.finalize("Boat trip on Sunday") == .applied)
        #expect(field.currentEditor()?.string == "Subject: Boat trip on Sunday")
    }

    private func secureField(_ make: FieldMaker) throws {
        let (host, _) = NativeTextWindow.textField("", secure: true)
        defer { host.close() }
        let field = try #require(make(host))
        guard case .failure(let stop) = LiveInlineSession.begin(id: "secure", field: field) else {
            Issue.record("live typing began in a password field")
            return
        }
        #expect(stop == .secure)
    }

    private func runAll(_ make: FieldMaker) throws {
        let clipboard = NSPasteboard.general.changeCount
        try unicodeAndFormatting(make)
        try selectionCancel(make)
        try userEditInBetween(make)
        try caretMoved(make)
        try templateFinal(make)
        try textField(make)
        try secureField(make)
        // Only the change count is read; the clipboard's contents are never looked at.
        #expect(NSPasteboard.general.changeCount == clipboard)
    }

    @Test func appKitTextControlsKeepEverythingOutsideTheOwnedSpan() throws {
        try runAll { InProcessAccessibilityField($0) }
    }

    @Test(.enabled(if: AXIsProcessTrusted(), "needs Accessibility permission for the test host"))
    func realAccessibilityWritesKeepEverythingOutsideTheOwnedSpan() throws {
        try runAll { axField($0) }
    }
}
