import Carbon
import Cocoa

// Source-selection half of the authorized disposable-field experiment.
// Keystrokes are posted by a separate process, never by this selector.
let ownID = "dev.kazuhideoki.KarukanConnectionProbe"
guard CommandLine.arguments.count == 2,
    let id = ["ABC": "com.apple.keylayout.ABC", "Karukan": "dev.togatoga.inputmethod.Karukan.Japanese"][
        CommandLine.arguments[1]],
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ownID
else {
    fputs("Refused: unknown source or disposable test app is not frontmost\n", stderr)
    exit(2)
}
let sources =
    TISCreateInputSourceList([kTISPropertyInputSourceID as String: id] as CFDictionary, false)
    .takeRetainedValue() as! [TISInputSource]
guard let source = sources.first else { exit(3) }
guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ownID else { exit(2) }
let result = TISSelectInputSource(source)
print("Selected \(id): OSStatus \(result)")
exit(result == noErr ? 0 : 4)
