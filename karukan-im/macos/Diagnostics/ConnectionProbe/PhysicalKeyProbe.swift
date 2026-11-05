import Cocoa
import Carbon
import CoreGraphics

// Diagnostic driver, to be executed only after explicit user authorization.
// Source selection is performed separately, via the probe's visible controls.
// This process cannot type into Slack, ChatGPT, or any other application.
let targetID = "dev.kazuhideoki.KarukanConnectionProbe"
let arguments = Array(CommandLine.arguments.dropFirst())
let logURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    .appendingPathComponent("client-events.jsonl")

func testWindowHasFocus() -> Bool {
    guard let log = try? String(contentsOf: logURL, encoding: .utf8),
          let line = log.split(separator: "\n").last,
          let state = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    else { return false }
    return state["keyWindow"] as? Bool == true && state["appActive"] as? Bool == true
        && state["firstResponderIsTextView"] as? Bool == true
        && (state["pid"] as? Int32) == NSWorkspace.shared.frontmostApplication?.processIdentifier
}

func fail(_ message: String) -> Never {
    fputs(message + "\n", stderr)
    exit(2)
}

if arguments == ["activate"] {
    let appURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        .appendingPathComponent("Karukan Connection Probe.app")
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    var complete = false
    var error: Error?
    NSWorkspace.shared.openApplication(at: appURL, configuration: config) { app, problem in
        error = problem
        if app?.bundleIdentifier != targetID && error == nil {
            error = CocoaError(.fileReadUnknown)
        }
        complete = true
    }
    let limit = Date().addingTimeInterval(10)
    while !complete && Date() < limit {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    if !complete { fail("Activation timed out") }
    if let error { fail("Activation failed: \(error.localizedDescription)") }
    let readyDeadline = Date().addingTimeInterval(3)
    while Date() < readyDeadline &&
          (NSWorkspace.shared.frontmostApplication?.bundleIdentifier != targetID || !testWindowHasFocus()) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == targetID, testWindowHasFocus() else {
        fail("Test app did not obtain focus; no keys will be sent")
    }
    print("Requested activation of the disposable test app")
    exit(0)
}

if arguments == ["check"] {
    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == targetID, testWindowHasFocus() else {
        fail("Refused: dedicated disposable text field does not have focus")
    }
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
        let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
    else { fail("Could not read selected input source") }
    let sourceID = Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
    let data = try JSONSerialization.data(withJSONObject: ["inputSource": sourceID])
    print(String(decoding: data, as: UTF8.self))
    exit(0)
}

guard arguments.count == 2, arguments[0] == "key" else {
    fail("Usage: PhysicalKeyProbe activate | key {k,a,return,eisu,kana,escape,raycastHotkey}")
}
let keys: [String: CGKeyCode] = ["k": 40, "a": 0, "return": 36, "eisu": 102, "kana": 104, "escape": 53, "raycastHotkey": 49]
guard let code = keys[arguments[1]] else { fail("Only the fixed diagnostic key set is allowed") }
guard CGPreflightPostEventAccess() else {
    fail("No existing event-posting permission; this program will not request or change permissions")
}
guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == targetID else {
    fail("Refused: disposable test app is not the frontmost application")
}
guard testWindowHasFocus() else {
    fail("Refused: test window has lost keyboard focus")
}
let deadline = Date().addingTimeInterval(2)
while Date() < deadline,
      NSWorkspace.shared.frontmostApplication?.bundleIdentifier == targetID,
      !CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty {
    Thread.sleep(forTimeInterval: 0.02)
}
let held = CGEventSource.flagsState(.combinedSessionState)
guard held.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty else {
    fail("Refused: a modifier is currently held")
}
guard let source = CGEventSource(stateID: .hidSystemState),
      let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
    fail("Could not construct diagnostic key events")
}
// Check again immediately before posting; never redirect text to another app.
guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == targetID else {
    fail("Refused: focus changed before posting")
}
down.flags = arguments[1] == "raycastHotkey" ? .maskCommand : []
up.flags = []
let eventID = Int64((UInt64(0x4b41_5255) << 32) | UInt64(arc4random()))
down.setIntegerValueField(.eventSourceUserData, value: eventID)
up.setIntegerValueField(.eventSourceUserData, value: eventID)
down.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.02)
up.post(tap: .cghidEventTap)
Thread.sleep(forTimeInterval: 0.1)
let result: [String: Any] = [
    "event": "postedKeyPair", "testEventID": eventID,
    "key": arguments[1], "downType": down.type.rawValue, "upType": up.type.rawValue,
    "downTimestamp": down.timestamp, "upTimestamp": up.timestamp,
    "pid": ProcessInfo.processInfo.processIdentifier,
]
if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
    print(String(decoding: data, as: UTF8.self))
}
