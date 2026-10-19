import Testing
import AppKit
@testable import Yap

@MainActor
struct PasteboardSnapshotTests {
    @Test func restoresPreviousStringContents() throws {
        // Use a private, named pasteboard so we don't disturb the user's clipboard.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.frigade.yap.tests"))
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        let snapshot = try #require(PasteboardSnapshot.capture(pasteboard))

        pasteboard.clearContents()
        pasteboard.setString("temporary", forType: .string)
        #expect(pasteboard.string(forType: .string) == "temporary")

        PasteboardSnapshot.restore(snapshot, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "original")
    }

    @Test func temporaryPasteRestoresImageAndEveryItemType() throws {
        let board = NSPasteboard(name: .init("pflow.snapshot.tests.\(UUID())"))
        defer { board.releaseGlobally() }
        let custom = NSPasteboard.PasteboardType("com.pesh.tests.metadata")
        let first = NSPasteboardItem(), second = NSPasteboardItem()
        let png = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }.tiffRepresentation!
        first.setData(png, forType: .tiff)
        first.setString("screenshot", forType: .string)
        second.setData(Data([1, 2, 3]), forType: custom)
        board.writeObjects([first, second])
        let saved = try #require(PasteboardSnapshot.capture(board))
        board.clearContents()
        board.setString("dictated report", forType: .string)
        board.setString("session", forType: PasteboardSnapshot.sessionType)
        #expect(PasteboardSnapshot.restoreIfOwned(saved, to: board, change: board.changeCount, session: "session"))
        #expect(PasteboardSnapshot.capture(board) == saved)
        #expect(board.pasteboardItems?.count == 2)
    }

    @Test func cleanupNeverRestoresOverANewerCopyOrAnotherSession() throws {
        let board = NSPasteboard(name: .init("pflow.snapshot.tests.\(UUID())"))
        defer { board.releaseGlobally() }
        board.clearContents(); board.setString("original", forType: .string)
        let saved = try #require(PasteboardSnapshot.capture(board))
        board.clearContents(); board.setString("dictated report", forType: .string)
        board.setString("ours", forType: PasteboardSnapshot.sessionType)
        let change = board.changeCount
        #expect(!PasteboardSnapshot.restoreIfOwned(saved, to: board, change: change, session: "other"))
        #expect(board.string(forType: .string) == "dictated report")
        board.clearContents(); board.setString("new screenshot", forType: .string)
        #expect(!PasteboardSnapshot.restoreIfOwned(saved, to: board, change: change, session: "ours"))
        #expect(board.string(forType: .string) == "new screenshot")
    }

    @Test func unavailablePromisedDataAbortsSnapshotInsteadOfDroppingIt() {
        final class EmptyProvider: NSObject, NSPasteboardItemDataProvider {
            func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                            provideDataForType type: NSPasteboard.PasteboardType) {}
        }
        let board = NSPasteboard(name: .init("pflow.snapshot.tests.\(UUID())"))
        defer { board.releaseGlobally() }
        let provider = EmptyProvider(), item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.png])
        board.writeObjects([item])
        withExtendedLifetime(provider) { #expect(PasteboardSnapshot.capture(board) == nil) }
    }
}
