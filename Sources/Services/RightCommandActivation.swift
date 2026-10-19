import Foundation

enum CommandKey {
    static func rightCommandTransition(keyCode: Int64, flags: UInt64) -> Bool? {
        guard keyCode == 54 else { return nil }
        return flags & 0x10 != 0
    }
}

struct RightCommandActivation {
    enum State: Equatable { case idle, recording, awaitingSecondTap, continuous, processing, inserting }
    enum Effect: Equatable { case start, pause, resume, finish, cancel }
    private(set) var state: State = .idle
    private(set) var isDown = false
    private var pressedAt: TimeInterval = 0
    private var releasedAt: TimeInterval = 0
    static let doubleTapWindow: TimeInterval = 0.3
    static let tapDuration: TimeInterval = 0.18

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
    // The normal right-specific event handles release with Left Command held.
    mutating func recoverRelease(commandIsDown: Bool, at time: TimeInterval) -> [Effect] {
        guard isDown, !commandIsDown else { return [] }
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

