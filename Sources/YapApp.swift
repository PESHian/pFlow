import SwiftUI
import AppKit

/// Under the test harness, run a bare idle app so the full stack never boots —
/// unit tests bring their own isolated model containers.
@main
enum YapMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--apply-update" {
            exit(MacUpdateInstaller.apply(URL(fileURLWithPath: CommandLine.arguments[2])))
        }
        if CommandLine.arguments.contains("--check-setup") {
            let permissions = PermissionsManager()
            permissions.refresh()
            let login = LaunchAtLoginService()
            print("MICROPHONE=\(permissions.microphone) SPEECH=\(permissions.speech) ACCESSIBILITY=\(permissions.accessibility) AUTOMATION=\(permissions.automation)")
            print("LOGIN_ENABLED=\(login.isEnabled) LOGIN_NEEDS_APPROVAL=\(login.needsApproval) APPLE_INTELLIGENCE=\(TranscriptCleanupService().isAvailable)")
            return
        }
        #if DEBUG
        // Debug builds only: the live typing self-test. Runs before any app setup.
        if CommandLine.arguments.contains(InlineSelfTest.flag) {
            InlineSelfTest.start(arguments: CommandLine.arguments)
            return
        }
        #endif
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
            Toggle(MenuBarMenu.launchAtLogin, isOn: Binding(
                get: { app.launchAtLogin.isEnabled },
                set: { app.launchAtLogin.set($0) }
            ))
            if app.launchAtLogin.needsApproval {
                Button(MenuBarMenu.approveLogin) { app.launchAtLogin.openApproval() }
            }
            Divider()
            Button(MenuBarMenu.settings) { app.openMain(page: .settings) }
                .keyboardShortcut(",", modifiers: .command)
            Button(MenuBarMenu.history) { app.openMain(page: .history) }
            Menu(MenuBarMenu.formatPrefix + (app.templates.active?.name ?? "Plain dictation")) {
                Button("Plain dictation") { app.templates.activeID = nil }
                ForEach(app.templates.templates) { template in
                    Button(template.name) { app.templates.activeID = template.id }
                }
                Divider()
                Button(MenuBarMenu.editTemplates) { app.openMain(page: .templates) }
            }
            Divider()
            Button(MenuBarMenu.updates) { MacUpdates.shared.show() }
            Button(MenuBarMenu.about) { app.openAbout() }
            Button(MenuBarMenu.quit) { NSApplication.shared.terminate(nil) }
        } label: {
            Image(nsImage: MenuBarIcon.image(recording: isRecording))
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A relaunch briefly leaves the previous instance alive; an older copy
        // never quits a newer one, it steps aside.
        if InstalledCopies.retireOtherInstances() {
            NSApp.terminate(nil)
            return
        }

        let app = AppState.shared
        app.bootstrap()
        InstalledCopies.retireOlderCopies(login: app.launchAtLogin)

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
