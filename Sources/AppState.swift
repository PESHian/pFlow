import AppKit
import Foundation
import Observation
import SwiftData
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    let modelContainer: ModelContainer
    let permissions = PermissionsManager()
    let launchAtLogin = LaunchAtLoginService()
    let vocabulary = VocabularyStore()
    let templates = TemplateStore()
    let templateFormatter = TemplateFormatter()
    let clipboardSettings = ClipboardSettings()
    let whisperModel = WhisperModelStore.shared
    var transcriptionEngine: TranscriptionEngine {
        didSet {
            transcriptionEngine.save()
            permissions.requiresSpeechRecognition = transcriptionEngine == .apple
            if transcriptionEngine == .apple { applyDictationLocale() }
        }
    }

    /// Read at the start of each take; a change applies to the next one.
    var liveTextMode: LiveTextMode {
        didSet { liveTextMode.save() }
    }

    var currentInputName: String?
    var soundsEnabled: Bool {
        didSet { UserDefaults.standard.set(soundsEnabled, forKey: "soundsEnabled") }
    }

    var cleanupEnabled: Bool {
        didSet {
            UserDefaults.standard.set(cleanupEnabled, forKey: "cleanupEnabled")
            if cleanupEnabled { cleanup.prewarm() }
        }
    }

    var mainPage: MainPage = .settings

    /// Settings → Troubleshooting log, off until turned on. Off deletes what was kept.
    var troubleshootingLog: Bool {
        didSet {
            UserDefaults.standard.set(troubleshootingLog, forKey: TroubleshootingLog.defaultsKey)
            TroubleshootingLog.settingChanged()
            guard !troubleshootingLog else { return }
            TroubleshootingLog.clear()
            // pFlow Dictation reads the setting every few seconds: a line it wrote meanwhile goes too.
            DispatchQueue.main.asyncAfter(deadline: .now() + TroubleshootingLog.refreshSeconds + 1) { [weak self] in
                if self?.troubleshootingLog == false { TroubleshootingLog.clear() }
            }
        }
    }

    /// Hold it to dictate (Settings → Shortcut). Takes effect at once.
    var activationKey: ActivationKey {
        didSet {
            activationKey.save()
            activationKeys.key = activationKey
        }
    }

    /// Settings → Shortcut → Press a key, while it listens.
    let keyLearning = KeyLearning()

    var showInDock: Bool {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: "showInDock")
            applyDockVisibility()
        }
    }

    /// With this and `showInDock` both off, Yap runs on the shortcut alone and puts
    /// nothing on screen. Opening it again from Spotlight or Finder is the way back:
    /// `applicationShouldHandleReopen` surfaces a window without launching a second copy.
    var showInMenuBar: Bool {
        didSet { UserDefaults.standard.set(showInMenuBar, forKey: "showInMenuBar") }
    }

    /// "system" follows the OS locale; otherwise a BCP-47 identifier.
    var dictationLanguage: String {
        didSet {
            UserDefaults.standard.set(dictationLanguage, forKey: "dictationLanguage")
            applyDictationLocale()
        }
    }

    private(set) var availableLocales: [Locale] = []

    var effectiveDictationLocale: Locale {
        dictationLanguage == Self.systemLanguage ? .current : Locale(identifier: dictationLanguage)
    }

    static let systemLanguage = "system"

    private(set) var coordinator: RecordingCoordinator!

    private let hotkeys = HotkeyManager()
    private let activationKeys = ActivationKeyMonitor()
    private let escapeMonitor = EscapeMonitor()
    private let injector = TextInjector()
    private let hud = HUDController()
    /// The setup page is opened by itself once per launch for a missing Accessibility grant.
    private var accessibilityWarned = false
    private let sounds = SystemSoundPlayer()
    let cleanup = TranscriptCleanupService()
    private let deviceObserver = DefaultInputObserver()
    private var history: HistoryStore!
    private var windowCloseObserver: NSObjectProtocol?
    private let dictation: DictationSession

    private init() {
        do {
            modelContainer = try ModelContainer(for: Transcript.self)
        } catch {
            fatalError("pFlow: failed to create model container: \(error)")
        }

        soundsEnabled = (UserDefaults.standard.object(forKey: "soundsEnabled") as? Bool) ?? true
        transcriptionEngine = TranscriptionEngine.saved()
        liveTextMode = LiveTextMode.saved()
        showInDock = (UserDefaults.standard.object(forKey: "showInDock") as? Bool) ?? false
        showInMenuBar = (UserDefaults.standard.object(forKey: "showInMenuBar") as? Bool) ?? true
        cleanupEnabled = (UserDefaults.standard.object(forKey: "cleanupEnabled") as? Bool) ?? true
        activationKey = ActivationKey.saved()
        let keepLog = UserDefaults.standard.bool(forKey: TroubleshootingLog.defaultsKey)
        troubleshootingLog = keepLog
        if !keepLog { TroubleshootingLog.clear() }
        currentInputName = AudioDevices.defaultInputName()

        let language = UserDefaults.standard.string(forKey: "dictationLanguage") ?? Self.systemLanguage
        let dictation = DictationSession(
            locale: language == Self.systemLanguage ? .current : Locale(identifier: language)
        )
        self.dictation = dictation
        dictationLanguage = language

        let history = HistoryStore(context: modelContainer.mainContext)
        self.history = history

        sounds.enabled = { [weak self] in self?.soundsEnabled ?? true }
        injector.copyToClipboard = { [weak self] in self?.clipboardSettings.copyDictation ?? false }

        templateFormatter.cleanupFullDictation = { [weak self] in self?.cleanupEnabled ?? false }
        coordinator = RecordingCoordinator(
            session: dictation,
            injector: injector,
            history: history,
            hud: hud,
            sounds: sounds,
            cleaner: cleanup,
            cleanupEnabled: { [weak self] in self?.cleanupEnabled ?? false },
            vocabulary: { [weak self] in self?.vocabulary.preservationTerms ?? [] },
            deviceName: { [weak self] in self?.currentInputName },
            replacements: { [weak self] in self?.vocabulary.replacements ?? [] },
            formatter: templateFormatter,
            activeTemplate: { [weak self] in self?.templates.active },
            availableTemplates: { [weak self] in self?.templates.templates ?? [] },
            selectTemplate: { [weak self] in self?.templates.activeID = $0.id },
            liveTextMode: { [weak self] in self?.liveTextMode ?? .off }
        )

        dictation.contextualStrings = { [weak self] in self?.vocabulary.recognitionTerms ?? [] }
        dictation.selectedEngine = { [weak self] in self?.transcriptionEngine ?? .apple }
        permissions.requiresSpeechRecognition = transcriptionEngine == .apple
    }

    func bootstrap() {
        applyDockVisibility()
        observeWindowClosesForDockVisibility()
        permissions.refresh()
        launchAtLogin.refresh()
        if UserDefaults.standard.object(forKey: "pflow.loginAttempted") == nil {
            UserDefaults.standard.set(true, forKey: "pflow.loginAttempted")
            launchAtLogin.set(true)
        }

        // Accessibility takes effect live — no restart needed. Observing simply
        // keeps the UI honest the moment the user grants it.
        permissions.startObserving()

        // A test build is signed per build, so a grant made for the previous
        // one does not cover this one. The card carries the one-press Grant,
        // and the setup page opens by itself the first time a take finds
        // Accessibility off.
        hud.setGrantAccessibility { [weak self] in
            Task { await self?.permissions.grantAccessibility() }
        }
        coordinator.accessibilityMissing = { [weak self] in
            guard let self, !accessibilityWarned else { return }
            accessibilityWarned = true
            openOnboarding()
        }

        // pFlow Dictation: installed or updated from this app, then the private channel.
        InputMethodInstall.ensure()
        InputMethodLink.shared.start()

        hotkeys.disable()
        activationKeys.recordingIsBusy = { [weak self] in self?.coordinator.state != .idle }
        activationKeys.onActivation = { [weak self] effect in
            guard let self else { return }
            if effect == .start {
                NSLog("pFlow: recording requested; microphone=\(self.permissions.microphone), speech=\(self.permissions.speech), accessibility=\(self.permissions.accessibility)")
            }
            self.coordinator.handle(effect)
        }
        activationKeys.key = activationKey
        activationKeys.start()

        escapeMonitor.onEscape = { [weak self] in
            self?.coordinator.handleEscape()
        }
        escapeMonitor.start()

        // Build the HUD window and resolve the speech model up front, so the
        // first press of the shortcut is immediate rather than paying setup cost.
        hud.prepare()
        let locale = effectiveDictationLocale
        if transcriptionEngine == .apple {
            Task.detached(priority: .utility) {
                await DictationSession.prewarm(locale: locale)
            }
        }

        Task { [weak self] in
            let locales = await TranscriptionService.availableLocales()
            self?.availableLocales = locales.sorted {
                Self.languageName(for: $0).localizedCaseInsensitiveCompare(Self.languageName(for: $1)) == .orderedAscending
            }
        }
        if cleanupEnabled { cleanup.prewarm() }

        // Delivered on the main queue by the observer, so assign directly.
        deviceObserver.start { [weak self] name in
            self?.currentInputName = name
        }
    }

    private func applyDockVisibility() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    /// Flipping the policy to `.accessory` does not drop the Dock icon while a
    /// window is still on screen, so turning off "Show in Dock" from Settings
    /// leaves the icon until the window closes. Re-assert the policy once a window
    /// closes so closing Settings actually hides it.
    private func observeWindowClosesForDockVisibility() {
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.showInDock else { return }
                self.applyDockVisibility()
            }
        }
    }

    private func applyDictationLocale() {
        let locale = effectiveDictationLocale
        dictation.setLocale(locale)
        guard transcriptionEngine == .apple else { return }
        Task.detached(priority: .utility) {
            await DictationSession.prewarm(locale: locale)
        }
    }

    static func languageName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier(.bcp47))
            ?? locale.identifier(.bcp47)
    }

    /// Settings → Shortcut → Press a key: the activation key starts nothing
    /// until the new one is pressed, or listening stops.
    func learnActivationKey() {
        guard coordinator.state == .idle else { return }
        activationKeys.paused = true
        keyLearning.start(onLearned: { [weak self] key in self?.activationKey = key },
                          onEnd: { [weak self] in self?.activationKeys.paused = false })
    }

    /// Settings → Troubleshooting log → Save log…: every kept line in one file,
    /// in Downloads unless the person picks another place, then shown in Finder.
    func saveTroubleshootingLog() {
        let panel = NSSavePanel()
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd HHmm"
        panel.nameFieldStringValue = "pFlow log \(day.string(from: Date())).txt"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let version = "\(MacUpdates.current) (\(build))"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let text = TroubleshootingLog.report(lines: TroubleshootingLog.lines(), version: version,
                                                 system: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                NSSound.beep()
            }
        }
    }

    func toggleRecording() {
        keyLearning.stop()
        Task { await coordinator.toggle() }
    }

    /// Manual restart escape hatch. Never runs mid-dictation — that would throw
    /// away audio the user already spoke.
    func restartApp() {
        guard coordinator.state == .idle else { return }
        hud.show(device: nil)
        hud.setPhase(.restarting)
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            AppRelauncher.relaunch()
        }
    }

    /// Surfaces a window when the user opens Yap from Finder/Dock. Without this,
    /// launching an already-running agent app appears to do nothing at all.
    func presentMainWindow() {
        if permissions.allGranted {
            openMain(page: mainPage)
        } else {
            openOnboarding()
        }
    }

    /// Settings and History are pages within one window, not separate windows,
    /// so transcripts are always a click away.
    func openMain(page: MainPage = .settings) {
        mainPage = page
        WindowManager.shared.show(
            id: "main", title: "pFlow · by Pesh",
            size: MainWindowView.defaultSize, minSize: MainWindowView.minimumSize
        ) {
            MainWindowView()
                .environment(self)
                .modelContainer(self.modelContainer)
        }
    }

    func openAbout() {
        WindowManager.shared.show(
            id: "about", title: "About pFlow",
            size: NSSize(width: 360, height: 440), resizable: false
        ) { AboutView() }
    }

    func openOnboarding() {
        WindowManager.shared.show(
            id: "onboarding", title: "Welcome to pFlow",
            size: NSSize(width: 460, height: 650), resizable: false
        ) { OnboardingView().environment(self) }
    }
}
