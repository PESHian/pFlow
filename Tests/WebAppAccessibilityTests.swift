import AppKit
import Testing
@testable import Yap

@MainActor
struct WebAppAccessibilityTests {
    @Test func electronAndChromiumAppsAreToldApartByTheirFrameworks() {
        #expect(WebAppAccessibility.kind(frameworks: ["Electron Framework.framework", "Squirrel.framework"]) == .electron)
        #expect(WebAppAccessibility.kind(frameworks: ["Google Chrome Framework.framework"]) == .chromium)
        #expect(WebAppAccessibility.kind(frameworks: ["Microsoft Edge Framework.framework"]) == .chromium)
        #expect(WebAppAccessibility.kind(frameworks: ["Sparkle.framework", "Electron.framework"]) == nil)
        #expect(WebAppAccessibility.kind(frameworks: []) == nil)
    }

    @Test func electronTakesItsOwnFlagAndBrowsersTakeVoiceOvers() {
        #expect(WebAppAccessibility.attribute(for: .electron) == "AXManualAccessibility")
        #expect(WebAppAccessibility.attribute(for: .chromium) == "AXEnhancedUserInterface")
    }

    @Test func aProcessIsAskedAgainOnlyAfterAWhile() {
        let pid = pid_t(Int32.random(in: 100_000...900_000))
        #expect(WebAppAccessibility.dueToAsk(pid: pid, now: 100))
        #expect(!WebAppAccessibility.dueToAsk(pid: pid, now: 100 + WebAppAccessibility.askAgainAfter - 1))
        #expect(WebAppAccessibility.dueToAsk(pid: pid, now: 100 + WebAppAccessibility.askAgainAfter))
        #expect(WebAppAccessibility.dueToAsk(pid: pid + 1, now: 100), "another process is its own question")
    }

    @Test func anAppThatIsNotAWebAppIsNeverAsked() {
        #expect(WebAppAccessibility.kind(of: NSRunningApplication.current) == nil)
        #expect(!WebAppAccessibility.enable(NSRunningApplication.current))
    }
}
