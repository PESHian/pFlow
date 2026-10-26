import Cocoa
import InputMethodKit

// pFlow Dictation: the input method pFlow uses to show live words the way
// Apple Dictation does (replaceable marked text, then one commit), with no
// key events at all. It never changes a key the person types: every key
// passes through. It writes only while pFlow asks, only into the app pFlow
// named, and only to the text client that was active when the take began.
let info = Bundle.main.infoDictionary ?? [:]
let server = IMKServer(name: info["InputMethodConnectionName"] as? String, bundleIdentifier: Bundle.main.bundleIdentifier)
_ = server
Link.shared.start()
NSApplication.shared.run()
