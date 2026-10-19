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
