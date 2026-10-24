import Cocoa
import InputMethodKit
import Carbon

// Spike palette input method: never consumes keys; writes only on a command from the local driver.
final class Bridge {
    static let shared = Bridge()
    var current: IMKInputController?
    var currentClient: (IMKTextInput & NSObjectProtocol)?
    var log: [String] = []
    var activations = 0
    func note(_ s: String) { log.append(s); if log.count > 200 { log.removeFirst() } }
}

@objc(PFlowSpikeController)
final class PFlowSpikeController: IMKInputController {
    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        let c = sender as? (IMKTextInput & NSObjectProtocol)
        Bridge.shared.current = self
        Bridge.shared.currentClient = c
        Bridge.shared.activations += 1
        Bridge.shared.note("activate \(c?.bundleIdentifier() ?? "?") \(String(format: "%.3f", Date().timeIntervalSince1970))")
    }
    override func deactivateServer(_ sender: Any!) {
        let c = sender as? (IMKTextInput & NSObjectProtocol)
        Bridge.shared.note("deactivate \(c?.bundleIdentifier() ?? "?") \(String(format: "%.3f", Date().timeIntervalSince1970))")
        super.deactivateServer(sender)
    }
    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        Bridge.shared.note("event \(event?.type.rawValue ?? 0)")
        return false
    }
}

func respond(_ line: String) -> String {
    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
    let cmd = parts.first ?? ""
    let arg = parts.count > 1 ? parts[1].replacingOccurrences(of: "\\n", with: "\n") : ""
    let b = Bridge.shared
    guard cmd == "log" || cmd == "status" || b.currentClient != nil else { return "{\"error\":\"no client\"}" }
    func j(_ d: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: d), encoding: .utf8)! }
    switch cmd {
    case "log": return j(["log": b.log])
    case "status":
        guard let c = b.currentClient else { return j(["client": NSNull(), "activations": b.activations]) }
        let sel = c.selectedRange(), mk = c.markedRange()
        return j(["client": c.bundleIdentifier() ?? "?", "length": c.length(), "sel": [sel.location, sel.length],
                  "marked": [mk.location == NSNotFound ? -1 : mk.location, mk.length], "activations": b.activations,
                  "uid": c.uniqueClientIdentifierString() ?? "?"])
    case "mark":
        let ns = arg as NSString
        b.currentClient!.setMarkedText(arg, selectionRange: NSRange(location: ns.length, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let mk = b.currentClient!.markedRange()
        return j(["ok": true, "marked": [mk.location == NSNotFound ? -1 : mk.location, mk.length]])
    case "commit":
        b.currentClient!.insertText(arg, replacementRange: NSRange(location: NSNotFound, length: 0))
        let mk = b.currentClient!.markedRange(), sel = b.currentClient!.selectedRange()
        return j(["ok": true, "marked": [mk.location == NSNotFound ? -1 : mk.location, mk.length], "sel": [sel.location, sel.length]])
    case "unmark":
        b.currentClient!.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        return j(["ok": true])
    case "read":
        let c = b.currentClient!
        let sel = c.selectedRange()
        let end = sel.location == NSNotFound ? 0 : sel.location
        let start = max(0, end - 200)
        var actual = NSRange()
        let s = c.attributedSubstring(from: NSRange(location: start, length: end - start))?.string
        let s2 = c.string(from: NSRange(location: start, length: end - start), actualRange: &actual)
        return j(["length": c.length(), "sel": [sel.location, sel.length], "tail": s ?? NSNull(), "tail2": s2 ?? NSNull()])
    default: return "{\"error\":\"?\"}"
    }
}

// Spike-only command socket (VM, fictional text). The product uses a checked private channel.
func serve(path: String) {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
    _ = path.withCString { p in withUnsafeMutablePointer(to: &addr.sun_path) { strcpy(UnsafeMutableRawPointer($0).assumingMemoryBound(to: CChar.self), p) } }
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    chmod(path, 0o600)
    listen(fd, 4)
    Thread.detachNewThread {
        while true {
            let c = accept(fd, nil, nil); if c < 0 { continue }
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = read(c, &buf, buf.count)
            if n > 0 {
                let line = String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .newlines)
                var out = ""
                DispatchQueue.main.sync { out = respond(line) }
                _ = out.withCString { write(c, $0, strlen($0)) }
            }
            close(c)
        }
    }
}

let info = Bundle.main.infoDictionary!
if CommandLine.arguments.contains("--tis") {
    let id = Bundle.main.bundleIdentifier!
    let list = (TISCreateInputSourceList([kTISPropertyInputSourceID: id] as CFDictionary, true)?.takeRetainedValue() as? [TISInputSource]) ?? []
    print("register", TISRegisterInputSource(Bundle.main.bundleURL as CFURL))
    for s in list { print("enable", TISEnableInputSource(s)) }
    let after = (TISCreateInputSourceList([kTISPropertyInputSourceID: id] as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource]) ?? []
    print("enabled-now", after.count)
    for s in after { print("select", TISSelectInputSource(s)) }
    exit(0)
}
let server = IMKServer(name: info["InputMethodConnectionName"] as? String, bundleIdentifier: Bundle.main.bundleIdentifier)
serve(path: NSTemporaryDirectory() + "pfim-spike.sock")
Bridge.shared.note("started \(server != nil)")
NSApplication.shared.run()
