import Testing
@testable import Yap

struct MenuBarMenuTests {
    @Test func menuBarHasSettingsAndNoStartItem() {
        #expect(MenuBarMenu.titles.contains("Settings…"))
        #expect(!MenuBarMenu.titles.contains("Open pFlow…"))
        #expect(!MenuBarMenu.titles.contains { $0.contains("Dictation") })
        #expect(MenuBarMenu.titles.first == MenuBarMenu.launchAtLogin && MenuBarMenu.titles.last == MenuBarMenu.quit)
    }
}
