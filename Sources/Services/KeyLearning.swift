import AppKit
import Observation

/// Settings → Shortcut → Press a key. Listens in pFlow's own window only,
/// and takes every key while it does, so nothing is typed or triggered. Stops
/// with the new key, or with Escape, Cancel, 15 seconds of nothing, the window
/// losing focus, or a take starting; the old key stays unless a new one was learned.
@MainActor
@Observable
final class KeyLearning {
    private(set) var listening = false
    /// Why the last key pressed can't be used, while still listening.
    private(set) var note: String?

    static let timeoutSeconds: Double = 15

    #if DEBUG
    /// The Debug harness reads what learning saw (key codes and flags only).
    static var trace: [String] = []
    #endif

    @ObservationIgnored private var learner = KeyLearner()
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var onLearned: ((ActivationKey) -> Void)?
    @ObservationIgnored private var onEnd: (() -> Void)?

    func start(onLearned: @escaping (ActivationKey) -> Void, onEnd: @escaping () -> Void) {
        guard !listening else { return }
        listening = true
        note = nil
        learner = KeyLearner()
        self.onLearned = onLearned
        self.onEnd = onEnd
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return nil
        }
        for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            })
        }
        restartTimer()
    }

    /// Stops listening; the key stays as it is.
    func stop() {
        guard listening else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        timer?.cancel()
        timer = nil
        listening = false
        note = nil
        onLearned = nil
        let end = onEnd
        onEnd = nil
        end?()
    }

    func handle(_ event: NSEvent) {
        let outcome: KeyLearner.Outcome
        switch event.type {
        case .keyDown:
            outcome = learner.keyDown(event.keyCode, isRepeat: event.isARepeat,
                                      flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)))
        case .keyUp:
            outcome = learner.keyUp(event.keyCode)
        case .flagsChanged:
            outcome = learner.flagsChanged(event.keyCode, flags: UInt64(event.modifierFlags.rawValue))
        default:
            return
        }
        #if DEBUG
        Self.trace.append("\(event.type == .keyDown ? "down" : event.type == .keyUp ? "up" : "flags") \(event.keyCode) repeat \(event.type == .keyDown && event.isARepeat) flags \(String(event.modifierFlags.rawValue, radix: 16)) -> \(outcome)")
        #endif
        switch outcome {
        case .listening:
            break
        case .refused(let why):
            note = why
            restartTimer()
        case .learned(let key):
            let learned = onLearned
            stop()
            learned?(key)
        case .cancelled:
            stop()
        }
    }

    private func restartTimer() {
        timer?.cancel()
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Self.timeoutSeconds)) } catch { return }
            self?.stop()
        }
    }
}
