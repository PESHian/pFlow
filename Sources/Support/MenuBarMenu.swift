/// Titles of the menu bar items, in order. Dictation starts with Right
/// Command, never from the menu, so there is no start item.
enum MenuBarMenu {
    static let launchAtLogin = "Launch at Login"
    static let approveLogin = "Approve Launch at Login…"
    static let settings = "Settings…"
    static let history = "Recording History…"
    static let formatPrefix = "Format: "
    static let editTemplates = "Edit Templates…"
    static let updates = "Check for updates…"
    static let about = "About pFlow"
    static let quit = "Quit pFlow"

    static let titles = [launchAtLogin, approveLogin, settings, history, formatPrefix, editTemplates, updates, about, quit]
}
