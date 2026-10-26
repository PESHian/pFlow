import Foundation
import os
import ApplicationServices

/// Why a take's words went in, or did not, kept in the system log so a miss
/// on a person's Mac can be read afterwards:
///
///     log show --last 1d --info --style compact --predicate 'subsystem == "com.pesh.pflow"'
///
/// Every line is a fixed sentence plus fixed reason names. Never dictated
/// text, field contents, app names or window titles.
enum ReasonLog {
    static let subsystem = "com.pesh.pflow"
    private static let logger = Logger(subsystem: subsystem, category: "insertion")

    #if DEBUG
    /// The newest lines, for the Debug harness to record per take.
    static var recent: [String] = []
    #endif

    static func note(_ line: StaticString) {
        write(line.description)
    }

    static func note(_ line: StaticString, _ reason: some LogReason) {
        write("\(line.description) \(reason.logName)")
    }

    private static func write(_ text: String) {
        logger.notice("\(text, privacy: .public)")
        #if DEBUG
        recent.append(text)
        if recent.count > 200 { recent.removeFirst(recent.count - 200) }
        #endif
    }
}

/// A reason with a fixed name, safe for the system log.
protocol LogReason {
    var logName: String { get }
}

extension InsertionBlock: LogReason {
    var logName: String {
        if case .typingStopped(let stop) = self { return "typingStopped.\(stop.rawValue)" }
        return "\(self)"
    }
}

extension LiveInlineOwnership.Stop: LogReason {
    var logName: String { rawValue }
}

extension InjectionOutcome: LogReason {
    var logName: String {
        switch self {
        case .pasted: return "pasted"
        case .unconfirmed: return "unconfirmed"
        case .leftOnClipboard: return "leftOnClipboard"
        case .savedToHistory(let block): return "savedToHistory.\(block.logName)"
        case .blockedBySecureInput: return "blockedBySecureInput"
        }
    }
}

extension LiveInlineStart: LogReason {
    var logName: String {
        switch self {
        case .typing: return "typing"
        case .waiting: return "waiting"
        case .preview(let stop): return "preview.\(stop.rawValue)"
        }
    }
}

/// How a field's read-back differed from what pFlow expected there, by kind
/// only (never the text): the reason line after a write could not be confirmed.
enum ReadBackShape: String, LogReason {
    case unreadable, trailingLineBreak, leadingLineBreak, zeroWidth, quotes, spaces, letterCase, missing, extra, other

    var logName: String { rawValue }

    static func classify(expected: String, read: String?) -> ReadBackShape? {
        guard let read else { return .unreadable }
        let e = EditorPlaceholder.plain(expected), r = EditorPlaceholder.plain(read)
        if e == r { return nil }
        let lineBreaks = CharacterSet.newlines
        if r.hasPrefix(e), r.dropFirst(e.count).unicodeScalars.allSatisfy(lineBreaks.contains) { return .trailingLineBreak }
        if r.hasSuffix(e), r.dropLast(e.count).unicodeScalars.allSatisfy(lineBreaks.contains) { return .leadingLineBreak }
        let zeroWidth: Set<Unicode.Scalar> = ["\u{200B}", "\u{FEFF}", "\u{2060}"]
        func strip(_ s: String) -> String { String(String.UnicodeScalarView(s.unicodeScalars.filter { !zeroWidth.contains($0) })) }
        if strip(r) == strip(e) { return .zeroWidth }
        func straight(_ s: String) -> String {
            s.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
                .replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
        }
        if straight(r) == straight(e) { return .quotes }
        func squeezed(_ s: String) -> String { s.split(whereSeparator: { $0 == " " }).joined(separator: " ") }
        if squeezed(r) == squeezed(e) { return .spaces }
        if r.lowercased() == e.lowercased() { return .letterCase }
        if e.hasPrefix(r) { return .missing }
        if r.hasPrefix(e) { return .extra }
        return .other
    }
}

extension NoTypePlace: LogReason {
    var logName: String { "\(self)" }
}

/// An Accessibility error by its number only.
struct AXErrorName: LogReason {
    let logName: String
    init(_ error: AXError) { logName = "AXError.\(error.rawValue)" }
}

/// A count, for the log.
struct LogCount: LogReason {
    let logName: String
    init(_ count: Int) { logName = "\(count)" }
}
