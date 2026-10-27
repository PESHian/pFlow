import Foundation

/// Hold the activation key to dictate, double-tap it for continuous recording,
/// tap it again to finish. Named for Right Command, the first and default key;
/// the rule is the same for every key (`ActivationKey`).
struct RightCommandActivation {
    enum State: Equatable { case idle, recording, awaitingSecondTap, continuous, processing, inserting }
    enum Effect: Equatable { case start, pause, resume, finish, cancel }
    private(set) var state: State = .idle
    private(set) var isDown = false
    private var pressedAt: TimeInterval = 0
    private var releasedAt: TimeInterval = 0
    static let doubleTapWindow: TimeInterval = 0.3
    static let tapDuration: TimeInterval = doubleTapWindow

    init() {}

    mutating func press(at time: TimeInterval) -> [Effect] {
        guard !isDown else { return [] }
        isDown = true
        pressedAt = time
        switch state {
        case .idle:
            state = .recording
            return [.start]
        case .awaitingSecondTap where time - releasedAt <= Self.doubleTapWindow:
            state = .continuous
            return [.resume]
        case .continuous:
            state = .processing
            return [.finish]
        default:
            return []
        }
    }

    mutating func release(at time: TimeInterval) -> [Effect] {
        guard isDown else { return [] }
        isDown = false
        guard state == .recording else { return [] }
        releasedAt = time
        if time - pressedAt <= Self.tapDuration {
            state = .awaitingSecondTap
            return [.pause]
        }
        state = .processing
        return [.finish]
    }

    mutating func expireTap(at time: TimeInterval) -> [Effect] {
        guard state == .awaitingSecondTap,
              time - releasedAt >= Self.doubleTapWindow else { return [] }
        state = .processing
        return [.finish]
    }

    // A modifier can remain held even when its virtual-key bitmap says up.
    // The normal side-specific event handles release with the other side held.
    mutating func recoverRelease(keyIsDown: Bool, at time: TimeInterval) -> [Effect] {
        guard isDown, !keyIsDown else { return [] }
        return release(at: time)
    }

    mutating func interrupt() -> [Effect] {
        let active = state != .idle
        state = .idle
        return active ? [.cancel] : []
    }

    mutating func reset() { self = RightCommandActivation() }
    mutating func beginInsertion() { if state == .processing { state = .inserting } }
    mutating func complete() { state = .idle }
    mutating func reconcileIdle(isBusy: Bool) {
        if !isBusy, !isDown { state = .idle }
    }
}

