import Foundation

// 文字列、キーコード、候補の内容は受け取らず、処理の種類と件数だけを記録する。
enum InputDiagnosticEvent: String, Codable {
    case startup, activate, deactivateBegin, deactivateEnd, commitComposition
    case inputReceived, missingClient, engineResult, engineUnavailable, actionsApplied
    case clientCallBegin, clientCallEnd
    case eventReceived, eventBypassed, environmentSnapshot
    case redundantPreeditClearSkipped
}

enum InputDiagnosticEventKind: String, Codable {
    case keyDown, flagsChanged, other
}

enum InputDiagnosticBypassReason: String, Codable {
    case commandShortcut, unsupportedEvent, untranslatedKey, eisuSwitch
}

struct InputDiagnosticEnvironment: Codable, Equatable {
    var frontmostBundle: String?
    var frontmostPID: Int32?
    var inputSource: String?
    var sessionKeyDowns: UInt32
    var hardwareKeyDowns: UInt32
    var receivedKeyDowns: UInt64
    var receivedFlagsChanges: UInt64
    var sessionModifiers: UInt64
    var hardwareModifiers: UInt64
    var secureInput: Bool
}

enum InputDiagnosticCall: String, Codable {
    case bundleIdentifier, setMarkedText, insertText, markedRange
    case selectedRange, surroundingText, candidateAnchor
}

struct InputDiagnosticContext: Codable {
    var session: String
    var sequence: UInt64
    var active: Bool
    var client: String?
    var clientBundle: String?
    var frontmostBundle: String?
    var frontmostPID: Int32?
    var hasPreedit: Bool
    var candidatesVisible: Bool
}

struct InputDiagnosticDetails: Codable {
    var call: InputDiagnosticCall?
    var elapsedMs: Double?
    var textUTF16Length: Int?
    var consumed: Bool?
    var actions: [InputDiagnosticAction]?
    var rangeAvailable: Bool?
    var rangeLocation: Int?
    var rangeLength: Int?
    var eventKind: InputDiagnosticEventKind?
    var eventModifiers: UInt64?
    var sessionModifiers: UInt64?
    var hasCharacters: Bool?
    var hasCharactersIgnoringModifiers: Bool?
    var bypassReason: InputDiagnosticBypassReason?
    var environment: InputDiagnosticEnvironment?

    static func range(_ range: NSRange) -> Self {
        let available = range.location != NSNotFound && range.length != NSNotFound
        return Self(
            rangeAvailable: available,
            rangeLocation: available ? range.location : nil,
            rangeLength: available ? range.length : nil
        )
    }
}

struct InputDiagnosticAction: Codable {
    enum Kind: String, Codable {
        case updatePreedit, commit, showCandidates, hideCandidates, updateAux, hideAux
    }

    let kind: Kind
    var textUTF16Length: Int?
    var candidateCount: Int?

    init(_ action: EngineAction) {
        switch action {
        case .updatePreedit(let text, _, _):
            kind = .updatePreedit
            textUTF16Length = text.utf16.count
        case .commit(let text):
            kind = .commit
            textUTF16Length = text.utf16.count
        case .showCandidates(let candidates, _, _, _):
            kind = .showCandidates
            candidateCount = candidates.count
        case .hideCandidates: kind = .hideCandidates
        case .updateAux: kind = .updateAux
        case .hideAux: kind = .hideAux
        }
    }
}

struct InputDiagnosticEntry: Codable {
    var schema = 2
    var timestamp = Date()
    var uptime = ProcessInfo.processInfo.systemUptime
    var pid = ProcessInfo.processInfo.processIdentifier
    var run: String
    var build: String?
    var event: InputDiagnosticEvent
    var context: InputDiagnosticContext?
    var details: InputDiagnosticDetails
}

final class InputDiagnostics {
    static let preferenceKey = "InputDiagnosticsEnabled"
    static let shared = InputDiagnostics(
        enabled: UserDefaults.standard.bool(forKey: preferenceKey),
        fileURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/KarukanIME/input-diagnostics.log")
    )

    let isEnabled: Bool
    private let queue = DispatchQueue(label: "dev.togatoga.karukan.input-diagnostics", qos: .utility)
    private let run = UUID().uuidString
    private let build = Bundle.main.object(forInfoDictionaryKey: "KarukanDiagnosticBuild") as? String
    private let fileURL: URL
    private let maxBytes: UInt64
    private let archiveCount: Int
    private var handle: FileHandle?
    private var bytes: UInt64 = 0
    private var failed = false

    init(enabled: Bool, fileURL: URL, maxBytes: UInt64 = 8 * 1024 * 1024, archiveCount: Int = 3) {
        isEnabled = enabled
        self.fileURL = fileURL
        self.maxBytes = max(1, maxBytes)
        self.archiveCount = max(0, archiveCount)
    }

    deinit {
        try? handle?.close()
    }

    func record(
        _ event: InputDiagnosticEvent, context: InputDiagnosticContext? = nil,
        details: InputDiagnosticDetails = InputDiagnosticDetails()
    ) {
        guard isEnabled else { return }
        let entry = InputDiagnosticEntry(
            run: run, build: build, event: event, context: context, details: details)
        // 入力先への同期IPC中に停止しても、直前の記録を別キューから書き出せる。
        queue.async { self.append(entry) }
    }

    // テストで書き込み完了を待つためのもの。入力処理からは呼ばない。
    func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    private func append(_ entry: InputDiagnosticEntry) {
        guard !failed else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(entry)
            data.append(0x0A)
            // 設定したファイル容量を単一の記録で超えないようにする。
            guard data.count <= maxBytes else { return }
            try openIfNeeded()
            if bytes + UInt64(data.count) > maxBytes {
                try rotate()
                try openIfNeeded()
            }
            try handle?.write(contentsOf: data)
            bytes += UInt64(data.count)
        } catch {
            // 診断の失敗で入力を止めたり、同じエラーを出し続けたりしない。
            failed = true
            try? handle?.close()
            handle = nil
            NSLog("KarukanIME: input diagnostics disabled after a file error")
        }
    }

    private func openIfNeeded() throws {
        guard handle == nil else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
            guard fm.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            else { throw CocoaError(.fileWriteUnknown) }
        }
        handle = try FileHandle(forWritingTo: fileURL)
        bytes = try handle!.seekToEnd()
    }

    private func rotate() throws {
        try handle?.close()
        handle = nil
        let fm = FileManager.default
        let oldest = archiveCount > 0 ? archiveURL(archiveCount) : fileURL
        if fm.fileExists(atPath: oldest.path) { try fm.removeItem(at: oldest) }
        if archiveCount > 0 {
            if archiveCount > 1 {
                for index in stride(from: archiveCount - 1, through: 1, by: -1) {
                    let source = archiveURL(index)
                    if fm.fileExists(atPath: source.path) {
                        try fm.moveItem(at: source, to: archiveURL(index + 1))
                    }
                }
            }
            try fm.moveItem(at: fileURL, to: archiveURL(1))
        }
        bytes = 0
    }

    private func archiveURL(_ index: Int) -> URL {
        URL(fileURLWithPath: fileURL.path + ".\(index)")
    }
}
