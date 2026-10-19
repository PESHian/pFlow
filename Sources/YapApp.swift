import SwiftUI
import AppKit

/// Under the test harness, run a bare idle app so the full stack never boots —
/// unit tests bring their own isolated model containers.
@main
enum YapMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--check-setup") {
            let permissions = PermissionsManager()
            permissions.refresh()
            let login = LaunchAtLoginService()
            print("MICROPHONE=\(permissions.microphone) SPEECH=\(permissions.speech) ACCESSIBILITY=\(permissions.accessibility) AUTOMATION=\(permissions.automation)")
            print("LOGIN_ENABLED=\(login.isEnabled) LOGIN_NEEDS_APPROVAL=\(login.needsApproval) APPLE_INTELLIGENCE=\(TranscriptCleanupService().isAvailable)")
            return
        }
        if RuntimeMode.isTesting {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            app.run()
        } else {
            YapApp.main()
        }
    }
}

struct YapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app = AppState.shared

    private var isRecording: Bool { app.coordinator.state != .idle }

    var body: some Scene {
        MenuBarExtra(isInserted: $app.showInMenuBar) {
            Button(isRecording ? "Stop Dictation" : "Start Dictation") {
                app.toggleRecording()
            }
            Divider()
            Toggle("Launch at Login", isOn: Binding(
                get: { app.launchAtLogin.isEnabled },
                set: { app.launchAtLogin.set($0) }
            ))
            if app.launchAtLogin.needsApproval {
                Button("Approve Launch at Login…") { app.launchAtLogin.openApproval() }
            }
            Button("Open pFlow…") { app.openMain(page: .settings) }
            Button("Recording History…") { app.openMain(page: .history) }
            Menu("Format: " + (app.templates.active?.name ?? "Plain dictation")) {
                Button("Plain dictation") { app.templates.activeID = nil }
                ForEach(app.templates.templates) { template in
                    Button(template.name) { app.templates.activeID = template.id }
                }
                Divider()
                Button("Edit Templates…") { app.openMain(page: .templates) }
            }
            Divider()
            Button("About pFlow") { app.openAbout() }
            Button("Quit pFlow") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(nsImage: MenuBarIcon.image(recording: isRecording))
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A relaunch briefly leaves the previous instance alive.
        AppRelauncher.terminateOtherInstances()

        let app = AppState.shared
        app.bootstrap()

        if !app.permissions.allGranted {
            app.openOnboarding()
        }
    }

    /// Yap has no default window, so opening it from the Dock or Finder would
    /// otherwise look like nothing happened.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppState.shared.presentMainWindow()
        return true
    }

    /// Yap is a background dictation tool — closing a window must not quit it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
