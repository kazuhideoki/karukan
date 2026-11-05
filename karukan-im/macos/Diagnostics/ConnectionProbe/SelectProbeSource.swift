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
let arguments = Array(CommandLine.arguments.dropFirst())
let timing = arguments.count == 2 ? arguments[1] : "immediate"
guard (1...2).contains(arguments.count),
    ["immediate", "settle-before", "hold-after", "pump-after", "stay-alive"].contains(timing),
    let id = [
        "ABC": "com.apple.keylayout.ABC", "Karukan": "dev.togatoga.inputmethod.Karukan.Japanese",
        "AppleJapanese": "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese",
    ][
        arguments[0]],
    probeIsFrontmost(), disposableFieldHasFocus()
else {
    fputs("Refused: unknown source or disposable test app is not frontmost\n", stderr)
    exit(2)
}
let sources =
    TISCreateInputSourceList(
        [
            kTISPropertyInputSourceID as String: id, kTISPropertyInputSourceIsEnabled as String: true,
        ] as CFDictionary, false
    )
    .takeRetainedValue() as! [TISInputSource]
guard let source = sources.first else { exit(3) }
if timing == "settle-before" { Thread.sleep(forTimeInterval: 0.6) }
guard probeIsFrontmost(), disposableFieldHasFocus() else { exit(2) }
let begin = Date().timeIntervalSince1970 * 1000
let result = TISSelectInputSource(source)
let end = Date().timeIntervalSince1970 * 1000
if timing == "hold-after" { Thread.sleep(forTimeInterval: 0.6) }
if timing == "pump-after" { RunLoop.main.run(until: Date().addingTimeInterval(0.6)) }
guard probeIsFrontmost(), disposableFieldHasFocus() else { exit(2) }
let data = try JSONSerialization.data(withJSONObject: [
    "source": id, "status": result, "timing": timing, "selectBegin": begin, "selectEnd": end,
    "readyTime": Date().timeIntervalSince1970 * 1000, "pid": ProcessInfo.processInfo.processIdentifier,
])
print(String(decoding: data, as: UTF8.self))
fflush(stdout)
if timing == "stay-alive", result == noErr {
    // The driver keeps this process alive through key delivery, then terminates
    // it. A bounded lifetime and focus checks also cover a lost parent.
    let limit = Date().addingTimeInterval(15)
    while Date() < limit, probeIsFrontmost(), disposableFieldHasFocus() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
}
exit(result == noErr ? 0 : 4)
