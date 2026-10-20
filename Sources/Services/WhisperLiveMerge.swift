import Foundation

/// One Whisper segment from a live window. Times are milliseconds from the
/// start of that window, as Whisper reports them.
struct WhisperWindowSegment: Codable, Equatable, Sendable {
    let fromMs: Int
    let toMs: Int
    let text: String
    let noSpeechProbability: Double
}

/// One recognized window of a take. `startMs`/`endMs` are milliseconds from the
/// start of the take, counted in audio samples, never wall-clock time.
struct WhisperWindow: Codable, Equatable, Sendable {
    let startMs: Int
    let endMs: Int
    let segments: [WhisperWindowSegment]
}

/// Turns overlapping Whisper windows into one live transcript. Pure logic,
/// shared with Windows through `fixtures/live-text/whisper-windows`; the
/// README there is the specification. Display only: the finished text of a
/// take always comes from the whole-recording pass.
struct WhisperLiveMerger {
    /// Whisper's own default for "this segment is not speech".
    static let noSpeechLimit = 0.6
    /// A segment that ends this long before the window end has heard enough of
    /// what follows; it is kept and later windows start after it.
    static let settleMs = 1_000
    /// Most words compared when a window repeats the end of the kept text.
    static let overlapUnits = 8

    private struct Piece {
        let fromMs: Int
        let toMs: Int
        let text: String
    }

    /// Words no later window revises.
    private(set) var committed = ""
    /// Audio before this point is covered by `committed`; the next window starts here.
    private(set) var committedEndMs = 0
    private var tentative: [Piece] = []
    private var lastEndMs = 0

    var text: String { tentative.reduce(committed) { LiveTextUnits.join($0, $1.text) } }

    /// Applies one window. Returns true when the visible text changed.
    @discardableResult
    mutating func apply(_ window: WhisperWindow) -> Bool {
        // An older or repeated window can only take words back.
        guard window.endMs > lastEndMs, window.endMs > committedEndMs, window.startMs < window.endMs else { return false }
        let before = text
        lastEndMs = window.endMs

        var pieces = window.segments.filter(Self.isSpeech).compactMap { segment -> Piece? in
            let from = window.startMs + max(0, segment.fromMs)
            let to = min(window.endMs, window.startMs + max(segment.fromMs, segment.toMs))
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : Piece(fromMs: min(from, to), toMs: to, text: text)
        }

        // No later window will hear the audio before this one starts, so the
        // words already shown for it are kept as they are.
        if window.startMs > committedEndMs {
            for piece in tentative {
                committed = LiveTextUnits.join(committed, Self.prefix(of: piece, before: window.startMs))
            }
            committedEndMs = window.startMs
        }
        tentative = []

        // Words heard entirely before the kept boundary are already in `committed`.
        pieces.removeAll { $0.toMs <= committedEndMs }
        // Whisper's segment times are approximate, so a word at the boundary
        // can be heard by both windows.
        pieces = Self.dropRepeat(of: committed, from: pieces)

        var index = 0
        while index < pieces.count - 1, pieces[index].toMs <= window.endMs - Self.settleMs {
            committed = LiveTextUnits.join(committed, pieces[index].text)
            committedEndMs = max(committedEndMs, pieces[index].toMs)
            index += 1
        }
        tentative = Array(pieces[index...])
        return text != before
    }

    /// Silence and sound labels are not words. Whisper's typical silence
    /// hallucinations ("Thank you.") carry a high no-speech probability.
    static func isSpeech(_ segment: WhisperWindowSegment) -> Bool {
        guard segment.noSpeechProbability < noSpeechLimit else { return false }
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if (text.hasPrefix("[") && text.hasSuffix("]")) || (text.hasPrefix("(") && text.hasSuffix(")")) { return false }
        // Symbols such as ♪ are sound labels too: speech has a letter or digit.
        return text.unicodeScalars.contains { LiveTextUnits.isLetterOrNumber($0) }
    }

    /// The words of `piece` heard before `ms`, placing each word in time by its
    /// share of the segment's characters (Unicode scalars).
    private static func prefix(of piece: Piece, before ms: Int) -> String {
        let scalars = Array(piece.text.unicodeScalars)
        let total = scalars.count
        guard total > 0 else { return "" }
        let span = piece.toMs - piece.fromMs
        var end = 0
        for unit in LiveTextUnits.units(piece.text) {
            // Midpoint time < ms, kept in whole numbers so both platforms agree.
            guard 2 * piece.fromMs * total + span * (unit.start + unit.end) < 2 * ms * total else { break }
            end = unit.end
        }
        return LiveTextUnits.slice(scalars, 0, end)
    }

    /// Removes words at the start of `pieces` that repeat the end of `kept`.
    private static func dropRepeat(of kept: String, from pieces: [Piece]) -> [Piece] {
        let keptKeys = LiveTextUnits.units(kept).map(\.key).filter { !$0.isEmpty }.suffix(overlapUnits)
        var leading: [(piece: Int, unit: LiveTextUnits.Unit)] = []
        for (index, piece) in pieces.enumerated() where leading.count < overlapUnits {
            for unit in LiveTextUnits.units(piece.text) where !unit.key.isEmpty && leading.count < overlapUnits {
                leading.append((index, unit))
            }
        }
        let newKeys = leading.map(\.unit.key)
        guard let count = stride(from: min(keptKeys.count, newKeys.count), through: 1, by: -1)
            .first(where: { Array(keptKeys.suffix($0)) == Array(newKeys.prefix($0)) }) else { return pieces }
        let cut = leading[count - 1]
        let piece = pieces[cut.piece]
        let scalars = Array(piece.text.unicodeScalars)
        // Punctuation left at the cut belongs to the dropped word.
        let rest = LiveTextUnits.units(piece.text).first { $0.start >= cut.unit.end && !$0.key.isEmpty }
        let remaining = rest.map { LiveTextUnits.slice(scalars, $0.start, scalars.count) } ?? ""
        var result = Array(pieces[(cut.piece + 1)...])
        if !remaining.isEmpty { result.insert(Piece(fromMs: piece.fromMs, toMs: piece.toMs, text: remaining), at: 0) }
        return result
    }
}

/// Word units used to compare live windows. A unit is a run of non-space
/// characters; each Chinese or Japanese character is a unit by itself.
/// Positions count Unicode scalars so Swift and C# agree.
enum LiveTextUnits {
    struct Unit: Equatable {
        let start: Int
        let end: Int
        /// Lowercased, punctuation removed. Empty for punctuation-only units.
        let key: String
    }

    static func units(_ text: String) -> [Unit] {
        let scalars = Array(text.unicodeScalars)
        var result: [Unit] = []
        var start: Int?
        func close(_ end: Int) {
            if let begin = start { result.append(Unit(start: begin, end: end, key: key(scalars[begin..<end]))) }
            start = nil
        }
        for (index, scalar) in scalars.enumerated() {
            if scalar.properties.isWhitespace {
                close(index)
            } else if isIdeographic(scalar) {
                close(index)
                result.append(Unit(start: index, end: index + 1, key: key(scalars[index..<index + 1])))
            } else if start == nil {
                start = index
            }
        }
        close(scalars.count)
        return result
    }

    /// Joins two pieces of transcript with one space, or none where the
    /// language or punctuation does not take one.
    static func join(_ left: String, _ right: String) -> String {
        let a = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = a.unicodeScalars.last else { return b }
        guard let first = b.unicodeScalars.first else { return a }
        if isIdeographic(last) || isIdeographic(first) || noSpaceBefore.contains(first) { return a + b }
        return a + " " + b
    }

    static func slice(_ scalars: [Unicode.Scalar], _ from: Int, _ to: Int) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[from..<max(from, to)])
        return String(view).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let noSpaceBefore = Set(",.!?;:)]}%…、。，！？：；」』）".unicodeScalars)

    static func isIdeographic(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return true
        default: return false
        }
    }

    private static func key(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars.filter { !isPunctuation($0) })
        return String(view).lowercased()
    }

    static func isLetterOrNumber(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation: return true
        default: return false
        }
    }
}
