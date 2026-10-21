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
    /// Apple's Accessibility prompt shows once per app record, so a later
    /// press goes straight to System Settings instead of doing nothing.
    var accessibilityPrompted: Bool {
        defaults.string(forKey: Self.promptedKey) == Self.promptedValue
    }

    static let promptedKey = "pflow.accessibilityPrompted"
    private static var promptedValue: String {
        Bundle.main.bundlePath + "@" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
    }
    private let defaults: UserDefaults
    private var pollTimer: Timer?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// What one press of Grant does. Exactly one path per press: Apple's own
    /// prompt (which names the app and offers Open System Settings) or the
    /// System Settings pane, never both at once.
    enum GrantPath: Equatable { case prompt, openSettings, nothing }

    static func accessibilityPath(granted: Bool, promptedBefore: Bool) -> GrantPath {
        if granted { return .nothing }
        return promptedBefore ? .openSettings : .prompt
    }

    static func automationPath(_ status: Status) -> GrantPath {
        switch status {
        case .granted: return .nothing
        case .notDetermined: return .prompt
        case .denied: return .openSettings
        }
    }

    /// One Grant press for Accessibility. The grant itself is noticed by
    /// `startObserving`, so the window updates without a relaunch.
    func grantAccessibility(prompt: (() -> Void)? = nil, open: (() -> Void)? = nil) {
        switch Self.accessibilityPath(granted: accessibility, promptedBefore: accessibilityPrompted) {
        case .prompt:
            defaults.set(Self.promptedValue, forKey: Self.promptedKey)
            (prompt ?? requestAccessibility)()
        case .openSettings:
            (open ?? openAccessibilitySettings)()
        case .nothing:
            break
        }
    }

    /// One Grant press for Automation: the prompt while undecided, the pane
    /// once it was denied.
    func grantAutomation(prompt: (() async -> Void)? = nil, open: (() -> Void)? = nil) async {
        switch Self.automationPath(automation) {
        case .prompt:
            if let prompt { await prompt() } else { await requestAutomation() }
        case .openSettings:
            (open ?? openAutomationSettings)()
        case .nothing:
            break
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
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
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

    /// Ad-hoc signed builds have no stable designated requirement, so every
    /// rebuild looks like a different app to TCC. The tell-tale symptom is the
    /// checkbox appearing checked in System Settings while `AXIsProcessTrusted()`
    /// still returns false. Clearing the stale record lets the user re-grant.
    func resetAccessibilityGrant() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "Accessibility", bundleID]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            NSLog("pFlow: tccutil reset failed: \(error.localizedDescription)")
        }
        refresh()
        // The record is gone, so Apple's prompt can show again: one path.
        defaults.removeObject(forKey: Self.promptedKey)
        grantAccessibility()
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

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        refresh()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
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
