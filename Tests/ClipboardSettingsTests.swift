import AppKit
import Testing
@testable import Yap

@MainActor
struct ClipboardSettingsTests {
    @Test func defaultsOffAndBothChoicesSurviveReload() {
        let name = "pflow.clipboard.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = ClipboardSettings(defaults: defaults)
        #expect(!settings.copyDictation)
        settings.copyDictation = true
        #expect(ClipboardSettings(defaults: defaults).copyDictation)
        settings.copyDictation = false
        #expect(!ClipboardSettings(defaults: defaults).copyDictation)
    }

    @Test func copyOffLeavesImageAndOtherRepresentationsUntouched() async {
        let board = NSPasteboard(name: .init("pflow.clipboard.tests.\(UUID())"))
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        image.setColor(.red, atX: 0, y: 0)
        let png = image.representation(using: .png, properties: [:])!
        item.setData(png, forType: .png)
        item.setString("copied screenshot", forType: .string)
        board.writeObjects([item])
        let change = board.changeCount
        let injector = TextInjector(pasteboard: board)
        injector.copyToClipboard = { false }
        #expect(await injector.deliver("dictated fix") == .savedToHistory)
        #expect(board.changeCount == change)
        #expect(board.data(forType: .png) == png)
        #expect(board.string(forType: .string) == "copied screenshot")
        board.clearContents(); board.setString("newer copy", forType: .string)
        let newerChange = board.changeCount
        #expect(await injector.deliver("another fix") == .savedToHistory)
        #expect(board.changeCount == newerChange)
        #expect(board.string(forType: .string) == "newer copy")
    }

    @Test func copyOnLeavesDictationAvailableWhenInsertionIsBlocked() async {
        let board = NSPasteboard(name: .init("pflow.clipboard.tests.\(UUID())"))
        defer { board.releaseGlobally() }
        board.clearContents(); board.setString("previous", forType: .string)
        let injector = TextInjector(pasteboard: board)
        injector.copyToClipboard = { true }
        let result = await injector.deliver("dictated fix")
        #expect(result == .leftOnClipboard || { if case .blockedBySecureInput = result { return true }; return false }())
        #expect(board.string(forType: .string) == "dictated fix")
    }

    /// Live typing put the finished text in: with "Copy dictation to clipboard"
    /// on it goes on the clipboard once; live words never do; off, nothing changes.
    @Test func liveTypedFinalIsCopiedOnceOnlyWhenCopyIsOn() throws {
        for copy in [true, false] {
            let board = NSPasteboard(name: .init("pflow.clipboard.tests.\(UUID())"))
            defer { board.releaseGlobally() }
            board.clearContents(); board.setString("older fictional copy", forType: .string)
            let injector = TextInjector(pasteboard: board)
            injector.copyToClipboard = { copy }
            let field = SimulatedTextField("Log: ")
            #expect(injector.beginLive(session: "take", field: field) == .typing)
            let before = board.changeCount
            #expect(injector.reconcileLive(session: "take", transcript: "harbor lights") == nil)
            #expect(injector.reconcileLive(session: "take", transcript: "harbor lights glow") == nil)
            #expect(field.value == "Log: harbor lights")
            #expect(board.changeCount == before, "copy \(copy): live words touched the clipboard")
            #expect(injector.finalizeLive(session: "take", text: "Harbor lights glow.") == .applied)
            #expect(field.value == "Log: Harbor lights glow.")
            if copy {
                #expect(board.changeCount == before + 1, "the finished text is copied exactly once")
                #expect(board.string(forType: .string) == "Harbor lights glow.")
            } else {
                #expect(board.changeCount == before)
                #expect(board.string(forType: .string) == "older fictional copy")
            }
        }
    }

    @Test func liveFinalKeptForHistoryIsNotCopied() {
        let board = NSPasteboard(name: .init("pflow.clipboard.tests.\(UUID())"))
        defer { board.releaseGlobally() }
        board.clearContents(); board.setString("older fictional copy", forType: .string)
        let injector = TextInjector(pasteboard: board)
        injector.copyToClipboard = { true }
        let field = SimulatedTextField("Log: ")
        #expect(injector.beginLive(session: "take", field: field) == .typing)
        _ = injector.reconcileLive(session: "take", transcript: "harbor lights")
        _ = injector.reconcileLive(session: "take", transcript: "harbor lights glow")
        field.current.selection = NSRange(location: 0, length: 0)
        let before = board.changeCount
        #expect(injector.finalizeLive(session: "take", text: "Harbor lights glow.") == .kept(.caret))
        #expect(board.changeCount == before)
        #expect(board.string(forType: .string) == "older fictional copy")
    }

    @Test func clipboardRouteCarriesFullLongUnicodeReport() async {
        let board = NSPasteboard(name: .init("pflow.clipboard.tests.\(UUID())"))
        defer { board.releaseGlobally() }
        let injector = TextInjector(pasteboard: board)
        injector.copyToClipboard = { true }
        let text = String(repeating: "Officer Lee: café, VPN, 👩🏽‍💻.\nEvidence: 1404.\n", count: 2000)
        _ = await injector.deliver(text)
        #expect(board.string(forType: .string) == text)
    }
}
