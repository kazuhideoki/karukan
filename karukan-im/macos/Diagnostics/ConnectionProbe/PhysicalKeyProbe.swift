import Carbon
import Cocoa
import CoreGraphics

// Diagnostic driver, to be executed only after explicit user authorization.
// Source selection is performed by a separate selector or visible controls.
// This process cannot type into Slack, ChatGPT, or any other application.
let appURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    .appendingPathComponent("Karukan Connection Probe.app").resolvingSymlinksInPath()
guard let ownBundle = Bundle(url: appURL), let targetID = ownBundle.bundleIdentifier,
    targetID.hasPrefix("dev.kazuhideoki.KarukanConnectionProbe.h"),
    ownBundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "KarukanConnectionProbe"
else { fail("Refused: expected disposable probe bundle is missing") }

func probeIsFrontmost() -> Bool {
    guard let app = NSWorkspace.shared.frontmostApplication else { return false }
    return app.bundleIdentifier == targetID && app.bundleURL?.resolvingSymlinksInPath() == appURL
}
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
    while Date() < readyDeadline
        && (!probeIsFrontmost() || !testWindowHasFocus())
    {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    guard probeIsFrontmost(), testWindowHasFocus() else {
        fail("Test app did not obtain focus; no keys will be sent")
    }
    print("Requested activation of the disposable test app")
    exit(0)
}

if arguments == ["check"] {
    guard probeIsFrontmost(), testWindowHasFocus() else {
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

guard (2...3).contains(arguments.count), arguments[0] == "key" else {
    fail(
        "Usage: PhysicalKeyProbe activate | check | key {k,a,return,eisu,kana,escape,raycastHotkey} [hid|session|annotated|pid]"
    )
}
let delivery = arguments.count == 3 ? arguments[2] : (arguments[1] == "raycastHotkey" ? "hid" : "pid")
guard ["hid", "session", "annotated", "pid"].contains(delivery) else { fail("Unknown delivery boundary") }
let keys: [String: CGKeyCode] = [
    "k": 40, "a": 0, "return": 36, "eisu": 102, "kana": 104, "escape": 53, "raycastHotkey": 49,
]
guard let code = keys[arguments[1]] else { fail("Only the fixed diagnostic key set is allowed") }
guard CGPreflightPostEventAccess() else {
    fail("No existing event-posting permission; this program will not request or change permissions")
}
guard probeIsFrontmost() else {
    fail("Refused: disposable test app is not the frontmost application")
}
guard testWindowHasFocus() else {
    fail("Refused: test window has lost keyboard focus")
}
let deadline = Date().addingTimeInterval(2)
while Date() < deadline,
    probeIsFrontmost(),
    !CGEventSource.flagsState(.combinedSessionState).intersection([
        .maskCommand, .maskControl, .maskAlternate, .maskShift,
    ]).isEmpty
{
    Thread.sleep(forTimeInterval: 0.02)
}
let held = CGEventSource.flagsState(.combinedSessionState)
guard held.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty else {
    fail("Refused: a modifier is currently held")
}
guard let source = CGEventSource(stateID: .hidSystemState),
    let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
    let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
else {
    fail("Could not construct diagnostic key events")
}
// Check again immediately before posting; never redirect text to another app.
guard let target = NSWorkspace.shared.frontmostApplication,
    target.bundleIdentifier == targetID, target.bundleURL?.resolvingSymlinksInPath() == appURL, testWindowHasFocus()
else {
    fail("Refused: dedicated text field lost focus before posting")
}
let targetPID = target.processIdentifier
func post(_ event: CGEvent) {
    switch delivery {
    case "pid": event.postToPid(targetPID)
    case "session": event.post(tap: .cgSessionEventTap)
    case "annotated": event.post(tap: .cgAnnotatedSessionEventTap)
    default: event.post(tap: .cghidEventTap)
    }
}
down.flags = arguments[1] == "raycastHotkey" ? .maskCommand : []
up.flags = []
let eventID = Int64((UInt64(0x4b41_5255) << 32) | UInt64(arc4random()))
down.setIntegerValueField(.eventSourceUserData, value: eventID)
up.setIntegerValueField(.eventSourceUserData, value: eventID)
post(down)
Thread.sleep(forTimeInterval: 0.02)
post(up)
Thread.sleep(forTimeInterval: 0.1)
let result: [String: Any] = [
    "event": "postedKeyPair", "testEventID": eventID,
    "key": arguments[1], "downType": down.type.rawValue, "upType": up.type.rawValue,
    "downTimestamp": down.timestamp, "upTimestamp": up.timestamp,
    "pid": ProcessInfo.processInfo.processIdentifier,
    "delivery": delivery, "focusTargetPID": targetPID,
    "downTargetPID": down.getIntegerValueField(.eventTargetUnixProcessID),
    "upTargetPID": up.getIntegerValueField(.eventTargetUnixProcessID),
]
if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
    print(String(decoding: data, as: UTF8.self))
}
