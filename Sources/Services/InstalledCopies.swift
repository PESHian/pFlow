import AppKit
import ServiceManagement

/// Older installed copies of pFlow, found at launch. Finder's "Replace" can
/// leave an older copy in ~/Applications or elsewhere, and Launch Services
/// may keep opening that one. The running app quits other instances, offers
/// one plain prompt to move older copies to the Trash, and points
/// launch-at-login at itself. Nothing is deleted without a click.
enum InstalledCopies {
    struct Copy: Equatable {
        let url: URL
        let version: String
    }

    static let declinedKey = "pflow.olderCopies.declined"

    /// Which of `installed` are older copies of the running app: a lower
    /// version at another path that is a real install, not a build, backup,
    /// cache or trash. Pure, so it is tested with fixture bundles.
    static func older(than running: Copy, among installed: [Copy]) -> [Copy] {
        let me = running.url.standardizedFileURL.resolvingSymlinksInPath().path
        return installed.filter { copy in
            copy.url.standardizedFileURL.resolvingSymlinksInPath().path != me
                && !isScratch(copy.url)
                && compare(copy.version, running.version) == .orderedAscending
        }
    }

    /// Paths that hold builds, backups or trash rather than installs.
    static func isScratch(_ url: URL) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        if parts.contains(where: { [".Trash", "DerivedData", "build", "Caches"].contains($0) }) { return true }
        return parts.count > 1 && parts[1] == "Volumes"
    }

    /// Numeric per component: "0.3.10" is newer than "0.3.9"; "0.3" equals "0.3.0".
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(x.count, y.count) {
            let l = index < x.count ? x[index] : 0
            let r = index < y.count ? y[index] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// The copy at `url`, from its Info.plist; nil when it is not an app bundle.
    static func copy(at url: URL) -> Copy? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return Copy(url: url, version: info["CFBundleShortVersionString"] as? String ?? "0")
    }

    @MainActor static var running: Copy {
        Copy(url: Bundle.main.bundleURL,
             version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
    }

    /// Every copy Launch Services knows under this bundle ID.
    @MainActor static func installed(bundleID: String) -> [Copy] {
        NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).compactMap(copy(at:))
    }

    /// Run once at launch, after other instances were asked to quit.
    @MainActor static func retireOlderCopies(defaults: UserDefaults = .standard) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let found = older(than: running, among: installed(bundleID: bundleID))
        guard !found.isEmpty else { return }
        NSLog("pFlow: older copies installed: \(found.map { "\($0.version) at \($0.url.path)" })")
        pointLoginItemAtThisCopy()

        let declined = Set(defaults.stringArray(forKey: declinedKey) ?? [])
        let toAsk = found.filter { !declined.contains($0.url.path) }
        guard !toAsk.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = toAsk.count == 1 ? "An older copy of pFlow is still installed" : "Older copies of pFlow are still installed"
        alert.informativeText = toAsk.map { "pFlow \($0.version) in \(shortPath($0.url))" }.joined(separator: "\n")
            + "\n\nThis copy (pFlow \(running.version)) is the one running now. Moving the older \(toAsk.count == 1 ? "copy" : "copies") to the Trash keeps your Mac from opening \(toAsk.count == 1 ? "it" : "them") by mistake. Nothing is deleted; you can put \(toAsk.count == 1 ? "it" : "them") back from the Trash."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.recycle(toAsk.map(\.url)) { _, error in
                if let error { NSLog("pFlow: could not move older copies to the Trash: \(error.localizedDescription)") }
            }
        } else {
            defaults.set(Array(declined.union(toAsk.map(\.url.path))), forKey: declinedKey)
        }
    }

    /// Launch-at-login follows the bundle ID, so after a "Replace" it may still
    /// point at the older copy. Re-registering points it at this one.
    @MainActor private static func pointLoginItemAtThisCopy() {
        guard SMAppService.mainApp.status == .enabled else { return }
        do {
            try SMAppService.mainApp.unregister()
            try SMAppService.mainApp.register()
        } catch {
            NSLog("pFlow: could not re-point launch at login: \(error.localizedDescription)")
        }
    }

    private static func shortPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folder = url.deletingLastPathComponent().path
        return folder.hasPrefix(home) ? "~" + folder.dropFirst(home.count) : folder
    }
}
