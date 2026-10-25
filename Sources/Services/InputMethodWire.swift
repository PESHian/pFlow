import Foundation
import Security

/// The private channel between pFlow and its input method (pFlow Dictation),
/// shared by both programs. A Unix socket in pFlow's own support folder
/// (mode 0700, the socket 0600): pFlow listens, the input method connects,
/// and each side checks the other's code signature from the kernel's audit
/// token before a single message is read. No distributed notifications, no
/// pasteboard, no files with words in them. Words are never logged.
enum InputMethodWire {
    static let sourceID = "com.pesh.inputmethod.pFlow"
    static let bundleName = "pFlow Dictation.app"
    static let appIdentifier = "com.pesh.Yap"
    /// Longest message, in bytes; a take's words are far shorter.
    static let maxMessage = 1 << 20

    static var folder: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/pFlow/Input", isDirectory: true)
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
            /// pFlow → input method: take the marked text back out (a cancelled take).
            case cancel
            /// pFlow → input method: live words stop here; commit the marked text exactly as it is.
            case keep
            /// pFlow → input method: the take is over.
            case end
            /// input method → pFlow: the take can no longer be written (`reason`: key, click, appCommit, clientChanged).
            case interrupted
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

        init(_ kind: Kind, take: String? = nil, text: String? = nil, seq: Int? = nil, bundle: String? = nil, uid: String? = nil,
             ok: Bool? = nil, source: String? = nil, reason: String? = nil, markedLength: Int? = nil, seen: Bool? = nil) {
            self.kind = kind; self.take = take; self.text = text; self.seq = seq; self.bundle = bundle; self.uid = uid
            self.ok = ok; self.source = source; self.reason = reason; self.markedLength = markedLength; self.seen = seen
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
