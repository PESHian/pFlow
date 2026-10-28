import Foundation

/// Settings → Troubleshooting log, off until the person turns it on. While on,
/// pFlow and pFlow Dictation keep their reason lines (fixed sentences and
/// reason names: never dictated text, field contents, app names or window
/// titles) in the system log and in files in pFlow's support folder, which
/// Save log… joins into one file to send. Turning it off deletes the files.
/// While it is off, a Release build writes no reason line anywhere; Debug
/// builds (test Macs only) always write the system log. Shared by both programs.
enum TroubleshootingLog {
    static let defaultsKey = "troubleshootingLog"
    /// Per file; at this size it becomes the one older file and a new one starts.
    static let maxBytes = 1_000_000
    /// Re-read from pFlow's settings at most this often (pFlow Dictation reads them from another process).
    static let refreshSeconds: TimeInterval = 2

    enum Writer: String, CaseIterable {
        case app = "pFlow"
        case inputMethod = "pFlow Dictation"
    }

    #if DEBUG
    /// Tests turn the log on or off and keep it in a folder of their own.
    static var testing: (on: Bool, folder: URL)? {
        get { lock.lock(); defer { lock.unlock() }; return testingValue }
        set { lock.lock(); testingValue = newValue; lock.unlock() }
    }
    private static var testingValue: (on: Bool, folder: URL)?
    #endif

    static var folder: URL {
        #if DEBUG
        if let testing { return testing.folder }
        let name = "Logs Debug"
        #else
        let name = "Logs"
        #endif
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/pFlow", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    private static let lock = NSLock()
    private static var cached: (on: Bool, at: TimeInterval)?
    private static let queue = DispatchQueue(label: "pflow.troubleshooting-log", qos: .utility)

    /// Whether the person turned the log on, from pFlow's own settings.
    static var isOn: Bool {
        lock.lock()
        defer { lock.unlock() }
        #if DEBUG
        if let testingValue { return testingValue.on }
        #endif
        let now = ProcessInfo.processInfo.systemUptime
        if let cached, now - cached.at < refreshSeconds { return cached.on }
        let app = InputMethodWire.appIdentifier as CFString
        CFPreferencesAppSynchronize(app)
        let on = CFPreferencesCopyAppValue(defaultsKey as CFString, app) as? Bool ?? false
        cached = (on, now)
        return on
    }

    /// pFlow changed the setting: the next line reads it again.
    static func settingChanged() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    /// One reason line, stamped now, added to the writer's file in the background.
    static func append(_ line: String, by writer: Writer, now: Date = Date(), in folder: URL = TroubleshootingLog.folder) {
        let stamped = stamp(now) + "  " + writer.rawValue + "  " + line + "\n"
        queue.async { write(stamped, by: writer, in: folder) }
    }

    /// Deletes every log file. Lines already on their way are deleted with them.
    static func clear(in folder: URL = TroubleshootingLog.folder) {
        queue.async { try? FileManager.default.removeItem(at: folder) }
    }

    /// Waits for every line already handed over (tests, and Save log…).
    static func flush() { queue.sync {} }

    /// Every kept line from both programs, oldest first.
    static func lines(in folder: URL = TroubleshootingLog.folder) -> [String] {
        flush()
        var all: [String] = []
        for writer in Writer.allCases {
            for url in [older(writer, in: folder), current(writer, in: folder)] {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                all += text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            }
        }
        // The stamp leads every line and sorts as text; a stable sort keeps each program's own order.
        return all.enumerated().sorted { ($0.element.prefix(23), $0.offset) < ($1.element.prefix(23), $1.offset) }.map(\.element)
    }

    /// The file Save log… writes: what it is, then every line.
    static func report(lines: [String], version: String, system: String, saved: Date = Date()) -> String {
        var text = "pFlow troubleshooting log\n"
        text += "pFlow \(version) · macOS \(system) · saved \(stamp(saved))\n"
        text += "Steps only: never your words, what is in your fields, app names or window titles.\n\n"
        text += lines.isEmpty ? "(no lines yet)\n" : lines.joined(separator: "\n") + "\n"
        return text
    }

    static func current(_ writer: Writer, in folder: URL = TroubleshootingLog.folder) -> URL {
        folder.appendingPathComponent(writer.rawValue + ".log")
    }

    static func older(_ writer: Writer, in folder: URL = TroubleshootingLog.folder) -> URL {
        folder.appendingPathComponent(writer.rawValue + " (older).log")
    }

    private static func write(_ text: String, by writer: Writer, in folder: URL) {
        let fm = FileManager.default
        let url = current(writer, in: folder)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size >= maxBytes {
            try? fm.removeItem(at: older(writer, in: folder))
            try? fm.moveItem(at: url, to: older(writer, in: folder))
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
}
