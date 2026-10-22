import AppKit
import AVFoundation
import Speech
import ApplicationServices
import Carbon
import Observation

@MainActor
@Observable
final class PermissionsManager {
    enum Status: Equatable {
        case granted, denied, notDetermined
    }

    var microphone: Status = .notDetermined
    var speech: Status = .notDetermined
    var accessibility: Bool = false
    var automation: Status = .notDetermined
    var requiresSpeechRecognition = true
    /// What the last Accessibility Grant press did, for the hint under the step.
    var accessibilityGrant: AccessibilityGrantOutcome?
    private var pollTimer: Timer?

    init() {}

    /// What one press of Grant does for Microphone, Speech Recognition and
    /// Automation: Apple's own prompt while undecided, the System Settings
    /// pane once refused, nothing once granted. Never both at once.
    enum GrantPath: Equatable { case prompt, openSettings, nothing }

    static func grantPath(for status: Status) -> GrantPath {
        switch status {
        case .granted: return .nothing
        case .notDetermined: return .prompt
        case .denied: return .openSettings
        }
    }

    /// The steps one Accessibility Grant press can take, injectable so the
    /// rule is tested without touching this Mac's privacy settings.
    struct AccessibilityGrantSteps {
        var isTrusted: () -> Bool
        /// Clears pFlow's own Accessibility row. A row from an earlier build
        /// shows as ticked in System Settings while this build is not trusted,
        /// and while any row exists Apple's prompt will not show again.
        var resetOwnRow: () -> Void
        /// Starts watching for Apple's prompt; the closure it returns answers
        /// whether a prompt window has appeared since the watch began.
        var watchForPrompt: () -> () -> Bool
        var prompt: () -> Void
        var openSettings: () -> Void
        /// One short wait between looks for Apple's prompt (about a quarter second).
        var wait: () async -> Void
    }

    enum AccessibilityGrantOutcome: Equatable { case alreadyTrusted, granted, promptShown, settingsOpened }

    /// One press, one action: clear the stale row, ask for Apple's prompt,
    /// and only if no prompt appeared within about 2.5 s open the
    /// Accessibility list with pFlow already in it. Once the list is open
    /// nothing more is opened; a prompt that shows up later is left alone.
    static func grantAccessibility(_ steps: AccessibilityGrantSteps) async -> AccessibilityGrantOutcome {
        if steps.isTrusted() { return .alreadyTrusted }
        steps.resetOwnRow()
        let promptAppeared = steps.watchForPrompt()
        steps.prompt()
        for _ in 0..<promptWaits {
            if steps.isTrusted() { return .granted }
            if promptAppeared() { return .promptShown }
            await steps.wait()
        }
        if steps.isTrusted() { return .granted }
        if promptAppeared() { return .promptShown }
        steps.openSettings()
        return .settingsOpened
    }

    /// Quarter-second looks for Apple's prompt before the list is opened instead.
    static let promptWaits = 10
    private var accessibilityGrantInFlight = false

    /// One Grant press for Accessibility. A second press while one is still
    /// running does nothing. The grant itself is noticed by `startObserving`,
    /// so the window updates without a relaunch.
    func grantAccessibility(steps: AccessibilityGrantSteps? = nil) async {
        guard !accessibilityGrantInFlight else { return }
        accessibilityGrantInFlight = true
        defer { accessibilityGrantInFlight = false }
        accessibilityGrant = await Self.grantAccessibility(steps ?? liveAccessibilitySteps)
        refresh()
    }

    /// The one line under the Accessibility step after a press, or nil.
    var accessibilityHint: String? {
        guard !accessibility else { return nil }
        switch accessibilityGrant {
        case .promptShown: return "Choose Open System Settings in Apple's message, then turn on pFlow."
        case .settingsOpened: return "Turn on pFlow in the list that opened."
        case .alreadyTrusted, .granted, nil: return nil
        }
    }

    private var liveAccessibilitySteps: AccessibilityGrantSteps {
        AccessibilityGrantSteps(
            isTrusted: { AXIsProcessTrusted() },
            resetOwnRow: { Self.resetOwnAccessibilityRow() },
            watchForPrompt: { Self.watchForAccessibilityPrompt() },
            prompt: { Self.promptForAccessibility() },
            openSettings: { Self.openPrivacyPane(.accessibility) },
            wait: { try? await Task.sleep(nanoseconds: 250_000_000) }
        )
    }

    func grantMicrophone(prompt: (() async -> Void)? = nil, open: (() -> Void)? = nil) async {
        await grant(microphone, prompt: prompt ?? requestMicrophone, open: open ?? { Self.openPrivacyPane(.microphone) })
    }

    func grantSpeech(prompt: (() async -> Void)? = nil, open: (() -> Void)? = nil) async {
        await grant(speech, prompt: prompt ?? requestSpeech, open: open ?? { Self.openPrivacyPane(.speechRecognition) })
    }

    /// One Grant press for Automation: the prompt while undecided, the pane
    /// once it was denied.
    func grantAutomation(prompt: (() async -> Void)? = nil, open: (() -> Void)? = nil) async {
        await grant(automation, prompt: prompt ?? requestAutomation, open: open ?? openAutomationSettings)
    }

    private func grant(_ status: Status, prompt: () async -> Void, open: () -> Void) async {
        switch Self.grantPath(for: status) {
        case .prompt: await prompt()
        case .openSettings: open()
        case .nothing: break
        }
    }

    var allGranted: Bool {
        microphone == .granted && (!requiresSpeechRecognition || speech == .granted) && accessibility && automation == .granted
    }

    func refresh() {
        microphone = Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
        speech = Self.map(SFSpeechRecognizer.authorizationStatus())
        accessibility = AXIsProcessTrusted()

        Self.wakeSystemEvents()
        let latestAutomation = Self.automationStatus(prompt: false)
        // System Events reports undetermined while asleep even though the grant
        // is on file, so never let that transient reading undo a grant we've
        // already observed; only an explicit denial should.
        if !(latestAutomation == .notDetermined && automation == .granted) {
            automation = latestAutomation
        }
    }

    /// System Events launches on demand. Nudging it awake before checking keeps
    /// the reported status honest.
    private nonisolated static func wakeSystemEvents() {
        let bundleID = "com.apple.systemevents"
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Runs off the main actor because the prompt call blocks until the user answers.
    func requestAutomation() async {
        let result = await Task.detached { () -> Status in
            // Without System Events running the call returns "not found" instead
            // of showing the prompt.
            Self.wakeSystemEvents()
            try? await Task.sleep(nanoseconds: 300_000_000)
            return Self.automationStatus(prompt: true)
        }.value
        automation = result
    }

    func openAutomationSettings() {
        Self.openPrivacyPane(.automation)
    }

    private nonisolated static func automationStatus(prompt: Bool) -> Status {
        let bundleID = "com.apple.systemevents"
        var target = AEAddressDesc()

        let created = bundleID.withCString { pointer in
            AECreateDesc(typeApplicationBundleID, pointer, strlen(pointer), &target)
        }
        guard created == noErr else { return .notDetermined }
        defer { AEDisposeDesc(&target) }

        switch AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, prompt) {
        case noErr:
            return .granted
        case OSStatus(errAEEventNotPermitted):
            return .denied
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .notDetermined
        case OSStatus(procNotFound):
            // System Events isn't running yet; it launches on demand.
            return .notDetermined
        default:
            return .notDetermined
        }
    }

    /// Three signals, because none alone is dependable: the (undocumented)
    /// system accessibility-change notification for latency, app activation
    /// (Apple DTS's suggested mechanism), and a sparse poll as the backstop.
    func startObserving() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Fires slightly before the trust value actually flips.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self?.refreshAndNotify()
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshAndNotify() }
        }

        setPolling(interval: accessibility ? 5.0 : 1.0)
    }

    private func setPolling(interval: TimeInterval) {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAndNotify() }
        }
        timer.tolerance = interval / 4
        // .common so it keeps firing while a menu is being tracked.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func refreshAndNotify() {
        let wasGranted = accessibility
        refresh()
        guard wasGranted != accessibility else { return }
        // Back off once granted; poll attentively while we're still waiting.
        setPolling(interval: accessibility ? 5.0 : 1.0)
    }

    func requestMicrophone() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        refresh()
    }

    func requestSpeech() async {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
        }
        refresh()
    }

    /// macOS privacy rows are keyed by the app's signature. Test builds now
    /// carry one stable requirement (scripts/mac_release.py), but a row made
    /// by an older build stays ticked in System Settings while this build is
    /// not trusted. `tccutil` clears only pFlow's own row and needs no admin.
    private static func resetOwnAccessibilityRow() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "Accessibility", bundleID]
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                NSLog("pFlow: tccutil reset exited \(task.terminationStatus)")
            }
        } catch {
            NSLog("pFlow: tccutil reset failed: \(error.localizedDescription)")
        }
    }

    private static func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Apple's Accessibility prompt is drawn by the system helper
    /// universalAccessAuthWarn (seen on macOS 27 with a throwaway bundle).
    private static let promptOwner = "universalAccessAuthWarn"

    private static func promptWindows() -> [(number: Int, owner: String)] {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.compactMap { window in
            guard let owner = window[kCGWindowOwnerName as String] as? String, owner == promptOwner,
                  let number = window[kCGWindowNumber as String] as? Int else { return nil }
            return (number, owner)
        }
    }

    /// Only a prompt window that appeared after our request counts; a dialog
    /// that was already on screen is not ours. Window titles are withheld
    /// without Screen Recording permission, so the window's owner and timing
    /// are all there is to go on.
    static func watchForAccessibilityPrompt() -> () -> Bool {
        let before = Set(promptWindows().map(\.number))
        return { promptWindows().contains { !before.contains($0.number) } }
    }

    enum PrivacyPane: String {
        case accessibility = "Privacy_Accessibility"
        case microphone = "Privacy_Microphone"
        case speechRecognition = "Privacy_SpeechRecognition"
        case automation = "Privacy_Automation"
    }

    /// Opens one Privacy & Security list. The newer and the older address
    /// are both tried, and System Settings itself is the last resort, so a
    /// press always shows something.
    static func openPrivacyPane(_ pane: PrivacyPane) {
        let addresses = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane.rawValue)",
            "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)",
        ]
        for address in addresses {
            if let url = URL(string: address), NSWorkspace.shared.open(url) { return }
        }
        if let settings = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            NSWorkspace.shared.openApplication(at: settings, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private static func map(_ status: AVAuthorizationStatus) -> Status {
        switch status {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    private static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> Status {
        switch status {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }
}
