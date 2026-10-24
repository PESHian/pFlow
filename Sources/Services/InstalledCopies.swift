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
    /// cache or trash. A copy whose version cannot be read is never offered.
    /// Pure, so it is tested with fixture bundles.
    static func older(than running: Copy, among installed: [Copy]) -> [Copy] {
        let me = running.url.standardizedFileURL.resolvingSymlinksInPath().path
        return installed.filter { copy in
            copy.url.standardizedFileURL.resolvingSymlinksInPath().path != me
                && !isScratch(copy.url)
                && compare(copy.version, running.version) == .orderedAscending
        }
    }

    /// A copy running from a build folder, a cache, the Trash or a mounted
    /// volume is a developer or test run: it must not quit, retire or re-point
    /// anything that belongs to the real install.
    static func actsForInstall(_ running: Copy) -> Bool { !isScratch(running.url) }

    /// What a freshly launched copy does about other running instances of the
    /// same bundle ID: quit older ones (and a relaunch's previous instance of
    /// the same version), step aside when a newer one is already running,
    /// leave unknown versions alone. A scratch copy only quits its own earlier
    /// instance at the same path.
    struct InstancePlan: Equatable {
        var quit: [Copy] = []
        var stepAside = false
    }

    static func instancePlan(running: Copy, others: [Copy]) -> InstancePlan {
        var plan = InstancePlan()
        let me = running.url.standardizedFileURL.resolvingSymlinksInPath().path
        for other in others {
            let samePath = other.url.standardizedFileURL.resolvingSymlinksInPath().path == me
            if !actsForInstall(running) {
                if samePath { plan.quit.append(other) }
                continue
            }
            switch compare(other.version, running.version) {
            case .orderedAscending?: plan.quit.append(other)
            case .orderedSame?: plan.quit.append(other)
            case .orderedDescending?: plan.stepAside = true
            case nil: continue
            }
        }
        if plan.stepAside { plan.quit = [] }
        return plan
    }

    /// Paths that hold builds, backups or trash rather than installs.
    static func isScratch(_ url: URL) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        if parts.contains(where: { [".Trash", "DerivedData", "build", "Caches"].contains($0) }) { return true }
        return parts.count > 1 && parts[1] == "Volumes"
    }

    /// Numeric components only; nil for anything else ("0.3.10-beta", "").
    static func parse(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == parts.count && !numbers.isEmpty ? numbers : nil
    }

    /// Numeric per component: "0.3.10" is newer than "0.3.9"; "0.3" equals
    /// "0.3.0". Nil when either version cannot be read.
    static func compare(_ a: String, _ b: String) -> ComparisonResult? {
        guard let x = parse(a), let y = parse(b) else { return nil }
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

    /// Run first at launch. Returns true when a newer copy is already running
    /// and this one should quit instead of starting up.
    @MainActor static func retireOtherInstances() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me }
        let copies = others.map { app in
            app.bundleURL.flatMap(copy(at:)) ?? Copy(url: app.bundleURL ?? URL(fileURLWithPath: "/"), version: "")
        }
        let plan = instancePlan(running: running, others: copies)
        if plan.stepAside {
            NSLog("pFlow: a newer copy is already running; this one quits")
            return true
        }
        for (app, copy) in zip(others, copies) where plan.quit.contains(copy) { app.terminate() }
        return false
    }

    /// Run once at launch, after other instances were asked to quit. A scratch
    /// copy does nothing at all.
    @MainActor static func retireOlderCopies(login: LaunchAtLoginService, defaults: UserDefaults = .standard) {
        guard let bundleID = Bundle.main.bundleIdentifier, actsForInstall(running) else { return }
        let found = older(than: running, among: installed(bundleID: bundleID))
        guard !found.isEmpty else { return }
        ReasonLog.note("older copies installed:", LogCount(found.count))
        _ = pointLoginItemAtThisCopy(status: SMAppService.mainApp.status,
                                     register: { try SMAppService.mainApp.register() },
                                     refresh: { login.refresh() })

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
    /// point at the older copy. Registering again (never unregistering first,
    /// so a failure cannot lose the login item) asks the system to use this
    /// bundle. Whatever happens, the service state is refreshed so Settings
    /// shows the truth. Returns true when the item is enabled afterwards.
    static func pointLoginItemAtThisCopy(status: SMAppService.Status, register: () throws -> Void,
                                         refresh: () -> Void) -> Bool {
        guard status == .enabled else { return false }
        defer { refresh() }
        do {
            try register()
            return true
        } catch {
            NSLog("pFlow: could not re-point launch at login: \(error.localizedDescription)")
            return false
        }
    }

    private static func shortPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folder = url.deletingLastPathComponent().path
        return folder.hasPrefix(home) ? "~" + folder.dropFirst(home.count) : folder
    }
}
