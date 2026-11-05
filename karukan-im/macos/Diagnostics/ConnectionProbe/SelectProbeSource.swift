import Carbon
import Cocoa

// Source-selection half of the authorized disposable-field experiment.
// Keystrokes are posted by a separate process, never by this selector.
let appURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    .appendingPathComponent("Karukan Connection Probe.app").resolvingSymlinksInPath()
guard let ownBundle = Bundle(url: appURL), let ownID = ownBundle.bundleIdentifier,
    ownID.hasPrefix("dev.kazuhideoki.KarukanConnectionProbe.h"),
    ownBundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "KarukanConnectionProbe"
else { exit(2) }
func probeIsFrontmost() -> Bool {
    guard let app = NSWorkspace.shared.frontmostApplication else { return false }
    return app.bundleIdentifier == ownID && app.bundleURL?.resolvingSymlinksInPath() == appURL
}
func disposableFieldHasFocus() -> Bool {
    let url = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        .appendingPathComponent("client-events.jsonl")
    guard let log = try? String(contentsOf: url, encoding: .utf8),
        let line = log.split(separator: "\n").last,
        let row = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    else { return false }
    return row["keyWindow"] as? Bool == true && row["appActive"] as? Bool == true
        && row["firstResponderIsTextView"] as? Bool == true
        && (row["pid"] as? Int32) == NSWorkspace.shared.frontmostApplication?.processIdentifier
}
guard CommandLine.arguments.count == 2,
    let id = ["ABC": "com.apple.keylayout.ABC", "Karukan": "dev.togatoga.inputmethod.Karukan.Japanese"][
        CommandLine.arguments[1]],
    probeIsFrontmost(), disposableFieldHasFocus()
else {
    fputs("Refused: unknown source or disposable test app is not frontmost\n", stderr)
    exit(2)
}
let sources =
    TISCreateInputSourceList([kTISPropertyInputSourceID as String: id] as CFDictionary, false)
    .takeRetainedValue() as! [TISInputSource]
guard let source = sources.first else { exit(3) }
guard probeIsFrontmost(), disposableFieldHasFocus() else { exit(2) }
let result = TISSelectInputSource(source)
print("Selected \(id): OSStatus \(result)")
exit(result == noErr ? 0 : 4)
