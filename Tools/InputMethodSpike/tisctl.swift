import Carbon
import Foundation
func prop(_ s: TISInputSource, _ k: CFString) -> Any? {
    guard let p = TISGetInputSourceProperty(s, k) else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue()
}
func sources(_ id: String?) -> [TISInputSource] {
    let f: [CFString: Any]? = id.map { [kTISPropertyInputSourceID: $0] }
    return (TISCreateInputSourceList(f as CFDictionary?, true)?.takeRetainedValue() as? [TISInputSource]) ?? []
}
func describe(_ s: TISInputSource) -> String {
    "\(prop(s, kTISPropertyInputSourceID) ?? "?") cat=\(prop(s, kTISPropertyInputSourceCategory) ?? "?") type=\(prop(s, kTISPropertyInputSourceType) ?? "?") enableCap=\(prop(s, kTISPropertyInputSourceIsEnableCapable) ?? "?") enabled=\(prop(s, kTISPropertyInputSourceIsEnabled) ?? "?") selectCap=\(prop(s, kTISPropertyInputSourceIsSelectCapable) ?? "?") selected=\(prop(s, kTISPropertyInputSourceIsSelected) ?? "?")"
}
let a = CommandLine.arguments
let t0 = Date()
switch a[1] {
case "list": for s in sources(a.count > 2 ? a[2] : nil) { print(describe(s)) }
case "register": print("register", TISRegisterInputSource(URL(fileURLWithPath: a[2]) as CFURL))
case "enable": for s in sources(a[2]) { print("enable", TISEnableInputSource(s)) }
case "disable": for s in sources(a[2]) { print("disable", TISDisableInputSource(s)) }
case "select": for s in sources(a[2]) { print("select", TISSelectInputSource(s)) }
case "deselect": for s in sources(a[2]) { print("deselect", TISDeselectInputSource(s)) }
case "keyboard": print(prop(TISCopyCurrentKeyboardInputSource().takeRetainedValue(), kTISPropertyInputSourceID) ?? "?")
case "enabledlist":
    for s in (TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource]) ?? [] { print(describe(s)) }
default: print("?")
}
print(String(format: "ms %.0f", Date().timeIntervalSince(t0) * 1000))
