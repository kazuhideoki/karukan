import Carbon
import Cocoa

// イベントタップやキー内容の取得は行わず、OSの集計値と入力ソースだけを照合する。
final class InputDiagnosticEnvironmentMonitor {
    static let shared = InputDiagnosticEnvironmentMonitor()
    private var timer: Timer?
    private var lastSnapshot: InputDiagnosticEnvironment?
    private var receivedKeyDowns: UInt64 = 0
    private var receivedFlagsChanges: UInt64 = 0

    static var sessionModifiers: UInt64 {
        CGEventSource.flagsState(.combinedSessionState).rawValue
            & UInt64(NSEvent.ModifierFlags.deviceIndependentFlagsMask.rawValue)
    }

    func received(_ type: NSEvent.EventType) {
        guard InputDiagnostics.shared.isEnabled else { return }
        if type == .keyDown { receivedKeyDowns &+= 1 }
        if type == .flagsChanged { receivedFlagsChanges &+= 1 }
    }

    func start() {
        guard InputDiagnostics.shared.isEnabled, timer == nil else { return }
        sample()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.sample() }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func sample() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        var sourceID: String?
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        {
            sourceID = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
        }
        let snapshot = InputDiagnosticEnvironment(
            frontmostBundle: frontmost?.bundleIdentifier,
            frontmostPID: frontmost?.processIdentifier, inputSource: sourceID,
            sessionKeyDowns: CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown),
            hardwareKeyDowns: CGEventSource.counterForEventType(.hidSystemState, eventType: .keyDown),
            receivedKeyDowns: receivedKeyDowns, receivedFlagsChanges: receivedFlagsChanges,
            sessionModifiers: Self.sessionModifiers,
            hardwareModifiers: CGEventSource.flagsState(.hidSystemState).rawValue
                & UInt64(NSEvent.ModifierFlags.deviceIndependentFlagsMask.rawValue),
            secureInput: IsSecureEventInputEnabled()
        )
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        InputDiagnostics.shared.record(
            .environmentSnapshot, details: InputDiagnosticDetails(environment: snapshot))
    }
}

// 呼び出し元のイベントは保持せず、文字列が空でないかだけを記録に渡す。
func inputDiagnosticEventDetails(_ event: NSEvent) -> InputDiagnosticDetails {
    let kind: InputDiagnosticEventKind
    switch event.type {
    case .keyDown: kind = .keyDown
    case .flagsChanged: kind = .flagsChanged
    default: kind = .other
    }
    var details = InputDiagnosticDetails(
        eventTimestamp: event.timestamp,
        eventKind: kind,
        eventModifiers: UInt64(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue),
        sessionModifiers: InputDiagnosticEnvironmentMonitor.sessionModifiers,
        hasCharacters: event.type == .keyDown ? !(event.characters ?? "").isEmpty : nil,
        hasCharactersIgnoringModifiers: event.type == .keyDown
            ? !(event.charactersIgnoringModifiers ?? "").isEmpty : nil
    )
    // Only correlate explicitly tagged events from the disposable test app.
    // User event payloads, characters and key codes are never persisted here.
    details.testEventID = event.cgEvent.flatMap {
        inputDiagnosticProbeEventID($0.getIntegerValueField(.eventSourceUserData))
    }
    return details
}

func inputDiagnosticProbeEventID(_ raw: Int64) -> Int64? {
    UInt64(bitPattern: raw) >> 32 == 0x4b41_5255 ? raw : nil
}
