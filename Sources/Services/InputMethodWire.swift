import Foundation
import Security

/// The private channel between pFlow and its input method (pFlow Dictation),
/// shared by both programs. A Unix socket in pFlow's own support folder
/// (mode 0700, the socket 0600): pFlow listens, the input method connects,
/// and each side checks the other's code signature from the kernel's audit
/// token before a single message is read. No distributed notifications, no
/// pasteboard, no files with words in them. Words are never logged.
enum InputMethodWire {
    #if DEBUG
    /// Debug builds are their own input source and app, so a build or test run on a Mac
    /// where pFlow is installed never touches the real pFlow Dictation or pFlow.
    static let sourceID = "com.pesh.inputmethod.pFlow.debug"
    #else
    static let sourceID = "com.pesh.inputmethod.pFlow"
    #endif
    #if DEBUG
    static let bundleName = "pFlow Dictation Debug.app"
    #else
    static let bundleName = "pFlow Dictation.app"
    #endif
    #if DEBUG
    static let appIdentifier = "com.pesh.Yap.debug"
    #else
    static let appIdentifier = "com.pesh.Yap"
    #endif
    /// Longest message, in bytes; a take's words are far shorter.
    static let maxMessage = 1 << 20

    /// Where the socket lives. A Debug build has its own, so it never replaces the real pFlow's.
    static var folder: URL {
        #if DEBUG
        let name = "Input Debug"
        #else
        let name = "Input"
        #endif
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/pFlow", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    static var socketPath: String { folder.appendingPathComponent("link.sock").path }

    /// One message either way.
    struct Message: Codable, Equatable {
        enum Kind: String, Codable {
            /// input method → pFlow: the client it serves now (bundle ID and the client's own ID), sent on every activation.
            case client
            /// pFlow → input method: a take starts; `bundle` is the app it must be in, `source` the person's input source.
            case begin
            /// pFlow → input method: the whole current transcript as replaceable marked text.
            case mark
            /// input method → pFlow: how a mark went (`ok`, `markedLength`).
            case marked
            /// pFlow → input method: the finished text, committed once over the marked text.
            case commit
            /// input method → pFlow: how the commit went, and whether the client shows it before the caret (`seen`).
            case committed
            /// pFlow → input method: take the marked text back out with an empty mark; answered by `cleared`.
            case cancel
            /// input method → pFlow: the marked text is out (`ok`: the client reports nothing marked).
            case cleared
            /// pFlow → input method: no activation came; put the client active in the take's app on
            /// probation (`frame`: the target window), answered by `client` with `provisional`.
            case probe
            /// pFlow → input method: the take's marked words show in the target field; the client may commit.
            case confirm
            /// pFlow → input method: live words stop here; commit the marked text exactly as it is.
            case keep
            /// pFlow → input method: the take is over.
            case end
            /// input method → pFlow: the take can no longer be written (`reason`: key, click, appCommit, clientChanged).
            case interrupted
            /// pFlow → input method: pFlow selected the source again at `at`; only an activation from then on counts.
            case rebind
        }
        var kind: Kind
        var take: String?
        var text: String?
        var seq: Int?
        var bundle: String?
        var uid: String?
        var ok: Bool?
        var source: String?
        var reason: String?
        var markedLength: Int?
        var seen: Bool?
        /// System uptime when pFlow selected its source for the take (begin, rebind).
        var at: Double?
        /// The client is on probation (client).
        var provisional: Bool?
        /// The target window, x y width height in Cocoa screen coordinates (probe).
        var frame: [Double]?
        /// Debug builds only: the input method acts as if macOS sent no activation for this take.
        var simulateNoActivation: Bool?
        /// Debug builds only: the app of a client on probation commits the first marked words itself.
        var simulateAppCommit: Bool?

        init(_ kind: Kind, take: String? = nil, text: String? = nil, seq: Int? = nil, bundle: String? = nil, uid: String? = nil,
             ok: Bool? = nil, source: String? = nil, reason: String? = nil, markedLength: Int? = nil, seen: Bool? = nil,
             at: Double? = nil, provisional: Bool? = nil, frame: [Double]? = nil) {
            self.kind = kind; self.take = take; self.text = text; self.seq = seq; self.bundle = bundle; self.uid = uid
            self.ok = ok; self.source = source; self.reason = reason; self.markedLength = markedLength; self.seen = seen
            self.at = at; self.provisional = provisional; self.frame = frame
        }
    }

    /// Length-prefixed JSON: four bytes big-endian, then the message.
    static func frame(_ message: Message) -> Data? {
        guard let body = try? JSONEncoder().encode(message), body.count <= maxMessage else { return nil }
        var length = UInt32(body.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(body)
        return data
    }

    /// Takes whole messages off the front of `buffer`; a malformed or oversized one ends the stream (nil).
    static func unframe(_ buffer: inout Data) -> [Message]? {
        var out: [Message] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard length <= maxMessage else { return nil }
            guard buffer.count >= 4 + length else { break }
            let body = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + length)
            buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + 4 + length)
            guard let message = try? JSONDecoder().decode(Message.self, from: body) else { return nil }
            out.append(message)
        }
        return out
    }

    static func send(_ message: Message, on fd: Int32) -> Bool {
        guard let data = frame(message) else { return false }
        return data.withUnsafeBytes { raw -> Bool in
            var sent = 0
            while sent < data.count {
                let n = Darwin.send(fd, raw.baseAddress!.advanced(by: sent), data.count - sent, 0)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        return addr
    }

    // MARK: Peer checks

    /// The connected peer's running code, from the kernel's audit token (not a pid, which can be reused).
    static func peerCode(_ fd: Int32) -> SecCode? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return nil }
        let data = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code) == errSecSuccess else { return nil }
        return code
    }

    /// The designated requirement of the code bundle at `url`.
    static func requirement(ofBundle url: URL) -> SecRequirement? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    static func satisfies(_ code: SecCode, _ requirement: SecRequirement) -> Bool {
        SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    static func identifier(_ code: SecCode) -> String? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoIdentifier as String] as? String
    }

    static func path(_ code: SecCode) -> URL? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var url: CFURL?
        guard SecCodeCopyPath(staticCode, [], &url) == errSecSuccess else { return nil }
        return url as URL?
    }

    /// The input method shipped inside a pFlow app bundle.
    static func embedded(in app: URL) -> URL {
        app.appendingPathComponent("Contents/Library/Input Methods").appendingPathComponent(bundleName)
    }
}

/// Which text client a take writes to, as the input method decides it
/// (shared, so pFlow's tests cover it). A take binds only to a client
/// activated for this take: at or after the moment pFlow selected its source
/// for it (or selected it again), in the take's app. Never a leftover
/// activation from an earlier take, even one IMK never deactivated.
struct InputMethodBinding {
    struct Activation: Equatable {
        let controller: ObjectIdentifier
        let bundle: String?
        let at: TimeInterval
    }
    enum Event: Equatable { case none, bound, rebound, changed }

    private(set) var bundle: String?
    private(set) var after: TimeInterval = .infinity
    private(set) var bound: ObjectIdentifier?
    /// A client still active from before this take (macOS sent no new activation), on probation:
    /// it may show marked text, which pFlow then looks for in the target field. Never committed through.
    private(set) var provisional: ObjectIdentifier?
    /// pFlow saw this take's marked words in the target field (or, where the target cannot be read,
    /// the client was activated for this take): only then may the take commit.
    private(set) var confirmed = false
    private(set) var last: Activation?
    /// Words were marked in the bound client: it can no longer be swapped for another.
    var marked = false

    mutating func begin(bundle: String, after: TimeInterval) -> Event {
        self.bundle = bundle
        self.after = after
        bound = nil
        provisional = nil
        confirmed = false
        marked = false
        return bindLast()
    }

    /// pFlow selected the source again: only an activation from `after` on counts.
    mutating func rebind(after: TimeInterval) -> Event {
        guard bundle != nil, !marked, provisional == nil else { return .none }
        self.after = after
        bound = nil
        return bindLast()
    }

    mutating func activated(_ activation: Activation) -> Event {
        last = activation
        guard let bundle else { return .none }
        let fresh = activation.at >= after && activation.bundle == bundle
        if let provisional {
            if activation.controller == provisional { return .none }
            // A fresh activation before any words replaces the leftover; after words, nothing moves.
            guard !marked else { return .changed }
            guard fresh else { return .none }
            self.provisional = nil
            bound = activation.controller
            return .bound
        }
        guard let bound else {
            guard fresh else { return .none }
            self.bound = activation.controller
            return .bound
        }
        if activation.controller == bound { return .none }
        if fresh, !marked {
            self.bound = activation.controller
            confirmed = false
            return .rebound
        }
        return .changed
    }

    /// No activation came for this take: the client still active in the take's app goes on probation.
    mutating func probe(_ controller: ObjectIdentifier, bundle clientBundle: String?) -> Bool {
        guard let bundle, clientBundle == bundle, bound == nil, provisional == nil, !marked else { return false }
        provisional = controller
        return true
    }

    /// pFlow saw the take's words in the target field: the client is the take's, and may commit.
    mutating func confirm() {
        if let provisional {
            bound = provisional
            self.provisional = nil
        }
        if bound != nil { confirmed = true }
    }

    /// Marked text may go only to the bound client or the one on probation.
    func mayMark(_ controller: ObjectIdentifier?) -> Bool {
        controller != nil && (controller == bound || controller == provisional)
    }

    /// The finished text goes in only through a bound client that passed pFlow's check this take.
    func mayCommit(_ controller: ObjectIdentifier?) -> Bool {
        controller != nil && controller == bound && confirmed
    }

    mutating func end() {
        bundle = nil
        after = .infinity
        bound = nil
        provisional = nil
        confirmed = false
        marked = false
    }

    private mutating func bindLast() -> Event {
        guard let last, let bundle, last.at >= after, last.bundle == bundle else { return .none }
        bound = last.controller
        return .bound
    }

    /// The input method selected with no take and no pFlow to talk to puts the person's source back after this long.
    static let orphanDelay: TimeInterval = 3

    static func orphanRestoreDue(hasTake: Bool, connected: Bool, selectedIsOurs: Bool, sinceActivation: TimeInterval) -> Bool {
        !hasTake && !connected && selectedIsOurs && sinceActivation >= orphanDelay
    }
}
