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
    var requiresSpeechRecognition = true
    /// What the last Accessibility Grant press did, for the hint under the step.
    var accessibilityGrant: AccessibilityGrantOutcome?
    private var pollTimer: Timer?
    /// The key and click watch that follows the grant; tests pass their own.
    var watch: PersonInput = .shared
    /// The Accessibility trust check; tests pass their own.
    var trustCheck: () -> Bool = { AXIsProcessTrusted() }

    init() {}

    /// What one press of Grant does for Microphone and Speech Recognition:
    /// Apple's own prompt while undecided, the System Settings
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
        var resetOwnRow: () async -> Void
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
        await steps.resetOwnRow()
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
            resetOwnRow: { await Self.resetOwnAccessibilityRow() },
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

    private func grant(_ status: Status, prompt: () async -> Void, open: () -> Void) async {
        switch Self.grantPath(for: status) {
        case .prompt: await prompt()
        case .openSettings: open()
        case .nothing: break
        }
    }

    var allGranted: Bool {
        microphone == .granted && (!requiresSpeechRecognition || speech == .granted) && accessibility
    }

    func refresh() {
        microphone = Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
        speech = Self.map(SFSpeechRecognizer.authorizationStatus())
        accessibility = trustCheck()
        // From launch on, so a key the person pressed before a take (an
        // unfinished Japanese composition) is known when the take ends.
        // A tap from before a revoke is replaced once trust comes back.
        watch.follow(trusted: accessibility)
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
    /// Runs off the main actor: a press of Grant during a take must not
    /// stop the waveform or the live words while tccutil finishes.
    private static func resetOwnAccessibilityRow() async {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        await Task.detached(priority: .userInitiated) {
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
        }.value
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
    /// are all there is to go on: another app's Accessibility prompt raised
    /// in the same 2.5 s would be mistaken for ours (the list is not opened;
    /// the next press still works).
    static func watchForAccessibilityPrompt() -> () -> Bool {
        let before = Set(promptWindows().map(\.number))
        return { promptWindows().contains { !before.contains($0.number) } }
    }

    enum PrivacyPane: String {
        case accessibility = "Privacy_Accessibility"
        case microphone = "Privacy_Microphone"
        case speechRecognition = "Privacy_SpeechRecognition"
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
