import Carbon
import Cocoa

// Only this app's disposable fields are observed. No event tap or global key
// monitor is installed. No input-context getters are used by the trace sink.
let outputDirectory = Bundle.main.bundleURL.deletingLastPathComponent()
let logURL = outputDirectory.appendingPathComponent("client-events.jsonl")
let runID = UUID().uuidString
let traceEnabled = !CommandLine.arguments.contains("--no-context-trace")
let statusLabel = NSTextField(labelWithString: "Ready")
var trial = 0
var sampledSource: String?
var dispatchSequence = 0
var dispatchStack: [Int] = []
var markedWriteCount = 0
weak var observedView: NSTextView?
var primaryWindow: NSWindow?
weak var probeDelegate: ProbeDelegate?

func currentSource() -> String? {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
        let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
    else { return nil }
    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
}

func eventMetadata(_ event: NSEvent) -> [String: Any] {
    var result: [String: Any] = [
        "eventType": event.type.rawValue, "eventTimestamp": event.timestamp,
        "modifiers": event.modifierFlags.rawValue,
        "eventUserData": event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0,
        "eventSourcePID": event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? 0,
        "eventTargetPID": event.cgEvent?.getIntegerValueField(.eventTargetUnixProcessID) ?? 0,
        "eventSourceState": event.cgEvent?.getIntegerValueField(.eventSourceStateID) ?? 0,
        "cgEventType": event.cgEvent?.type.rawValue ?? 0,
    ]
    if event.type == .keyDown || event.type == .keyUp || event.type == .flagsChanged {
        // Key codes are restricted to this disposable app, unlike the IME log.
        result["keyCode"] = event.keyCode
        if event.type == .keyDown || event.type == .keyUp { result["isRepeat"] = event.isARepeat }
    }
    return result
}

func record(_ event: String, extra: [String: Any] = [:]) {
    var row: [String: Any] = [
        "schema": 1, "timestamp": Date().timeIntervalSince1970 * 1000,
        "uptime": ProcessInfo.processInfo.systemUptime, "event": event,
        "run": runID, "trial": trial, "pid": ProcessInfo.processInfo.processIdentifier,
        "appActive": NSApp.isActive, "contextTracing": traceEnabled,
        "manualKeys": probeDelegate?.manualComparison ?? false,
        "dispatchStack": dispatchStack, "isMainThread": Thread.isMainThread,
        "keyWindow": primaryWindow?.isKeyWindow ?? false,
    ]
    row["sampledSource"] = sampledSource
    if let view = observedView {
        row["view"] = String(describing: ObjectIdentifier(view))
        row["firstResponderIsTextView"] = view.window?.firstResponder === view
        row["hasMarkedText"] = view.hasMarkedText()
        row["markedLocation"] = view.markedRange().location
        row["length"] = view.string.utf16.count
        row["matchesKa"] = view.string == "か"
        row["matchesLatinKa"] = view.string == "ka"
        row["containsKana"] = view.string.unicodeScalars.contains { (0x3040...0x30ff).contains($0.value) }
    }
    row.merge(extra) { _, value in value }
    guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
    if !FileManager.default.fileExists(atPath: logURL.path) {
        _ = FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    if let file = try? FileHandle(forWritingTo: logURL) {
        defer { try? file.close() }
        _ = try? file.seekToEnd()
        try? file.write(contentsOf: data + Data([10]))
    }
}

@objc(ProbeApplication)
final class ProbeApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        let keyboard = [.keyDown, .keyUp, .flagsChanged].contains(event.type)
        guard keyboard else {
            super.sendEvent(event)
            return
        }
        dispatchSequence += 1
        dispatchStack.append(dispatchSequence)
        record("sendEventBegin", extra: eventMetadata(event))
        super.sendEvent(event)
        record("sendEventEnd", extra: eventMetadata(event))
        dispatchStack.removeLast()
        if event.type == .keyUp, event.keyCode == 36 { probeDelegate?.finishTrialAfterReturn() }
        if event.type == .keyUp, event.keyCode == 0 { probeDelegate?.finishPrimeAfterLetter() }
    }
}

// Deliberately no keyDown override and no custom NSTextInputContext.
final class ProbeTextView: NSTextView {
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedWriteCount += 1
        record("setMarkedTextBegin")
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        record("setMarkedTextEnd")
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        record("insertTextBegin")
        super.insertText(string, replacementRange: replacementRange)
        record("insertTextEnd")
    }
}

final class ProbeDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var overlay: NSPanel?
    var automatedCases: [String] = []
    var automatedIndex = 0
    var awaitingReturn = false
    var awaitingPrime = false
    var awaitingSource = false
    var trialTimeout: DispatchWorkItem?
    var comparisonGeneration = 0
    var startRequested = false
    var compareRecovery = false
    var manualComparison = false
    var recoveryPhase: Int?
    var recoveryStartLength = 0
    var recoveryStartMarkedWrites = 0
    let recoveryNames = ["unchanged", "after-context-snapshot", "after-context-reconnect"]
    let textView = ProbeTextView(frame: NSRect(x: 0, y: 0, width: 1000, height: 220))

    func applicationDidFinishLaunching(_ notification: Notification) {
        observedView = textView
        window = NSWindow(
            contentRect: NSRect(x: 100, y: 160, width: 1120, height: 640),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        primaryWindow = window
        window.title = "Karukan Connection Probe — disposable text only"
        window.delegate = self
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false
        for controls: [(String, Selector)] in [
            [
                ("Reset test field", #selector(reset)), ("ABC", #selector(abc)),
                ("Karukan", #selector(karukan)), ("Reconnect text context", #selector(reconnect)),
            ],
            [
                ("Overlay: keep source", #selector(overlayKeep)),
                ("Overlay: restore before focus", #selector(overlayBefore)),
                ("Overlay: restore after focus", #selector(overlayAfter)),
            ],
            [("Run 20 comparisons (about 45 seconds)", #selector(runComparison))],
            [
                ("Run 20 ABC-primed switches", #selector(runPrimedComparison)),
                ("Preflight (no keys)", #selector(preflight)),
            ],
            [("Run 36 source-order comparisons", #selector(runSourceComparison))],
            [("Run 24 Karukan / Apple comparisons", #selector(runIMEComparison))],
            [("手入力で確認（Karukan / Apple）", #selector(runManualComparison))],
        ] {
            let buttons = NSStackView()
            for (label, action) in controls {
                buttons.addArrangedSubview(NSButton(title: label, target: self, action: action))
            }
            root.addArrangedSubview(buttons)
        }
        root.addArrangedSubview(
            NSTextField(
                labelWithString:
                    "Only disposable test text. Logs contain event metadata and document lengths, never text."))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.isRichText = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 24, weight: .regular)
        textView.setAccessibilityLabel("Disposable IME test field")
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(scroll)
        statusLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        root.addArrangedSubview(statusLabel)
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            root.leftAnchor.constraint(equalTo: window.contentView!.leftAnchor),
            root.rightAnchor.constraint(equalTo: window.contentView!.rightAnchor),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit Connection Probe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)
        sampledSource = currentSource()
        record("ready")
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            let source = currentSource()
            if source != sampledSource {
                sampledSource = source
                record("sourceSnapshot")
            }
            let expected =
                self.automatedCases.indices.contains(self.automatedIndex)
                    && self.automatedCases[self.automatedIndex].hasPrefix("apple-primed")
                ? "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"
                : "dev.togatoga.inputmethod.Karukan.Japanese"
            if self.awaitingSource, source == expected {
                self.awaitingSource = false
                self.readyForTrial(self.automatedCases[self.automatedIndex])
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { _ in record("sourceChangeNotification") }
    }

    @objc func reset() {
        textView.inputContext?.discardMarkedText()
        textView.string = ""
        trial += 1
        window.makeFirstResponder(textView)
        record("reset")
        statusLabel.stringValue = "Trial \(trial)"
    }

    @objc func abc() {
        window.makeFirstResponder(textView)
        selectSource("com.apple.keylayout.ABC")
    }
    @objc func karukan() {
        window.makeFirstResponder(textView)
        selectSource("dev.togatoga.inputmethod.Karukan.Japanese")
    }

    func selectSource(_ id: String) {
        let query = [kTISPropertyInputSourceID as String: id] as CFDictionary
        let sources = TISCreateInputSourceList(query, false).takeRetainedValue() as! [TISInputSource]
        record("selectSourceBegin", extra: ["requestedSource": id])
        let result = sources.first.map { TISSelectInputSource($0) } ?? OSStatus(-1)
        record("selectSourceEnd", extra: ["requestedSource": id, "status": result])
    }

    @objc func reconnect() {
        record("reconnectBegin")
        window.makeFirstResponder(textView)
        textView.inputContext?.deactivate()
        textView.inputContext?.activate()
        record("reconnectEnd")
    }

    @objc func overlayKeep() { showOverlay(order: "keep") }
    @objc func overlayBefore() { showOverlay(order: "before") }
    @objc func overlayAfter() { showOverlay(order: "after") }

    func showOverlay(order: String, completion: (() -> Void)? = nil) {
        guard overlay == nil else { return }
        let generation = comparisonGeneration
        record("overlayBegin", extra: ["restoreOrder": order])
        let panel = NSPanel(
            contentRect: NSRect(x: window.frame.midX - 220, y: window.frame.midY, width: 440, height: 120),
            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Disposable nonactivating overlay (closes automatically)"
        let field = NSTextField(frame: NSRect(x: 20, y: 40, width: 400, height: 30))
        field.placeholderString = "No typing required"
        panel.contentView!.addSubview(field)
        overlay = panel
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        if order != "keep" { selectSource("com.apple.keylayout.ABC") }
        // A bounded local reproduction; no other application receives keys.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.comparisonGeneration == generation else { return }
            guard NSApp.isActive else {
                self.abortComparison()
                return
            }
            if order == "before" { self.selectSource("dev.togatoga.inputmethod.Karukan.Japanese") }
            DispatchQueue.main.asyncAfter(deadline: .now() + (order == "before" ? 0.05 : 0)) {
                guard self.comparisonGeneration == generation else { return }
                guard NSApp.isActive else {
                    self.abortComparison()
                    return
                }
                panel.orderOut(nil)
                self.window.makeKeyAndOrderFront(nil)
                self.window.makeFirstResponder(self.textView)
                if order == "after" { self.selectSource("dev.togatoga.inputmethod.Karukan.Japanese") }
                self.overlay = nil
                record("overlayEnd", extra: ["restoreOrder": order])
                completion?()
            }
        }
    }

    @objc func runComparison() {
        requestComparison([
            "baseline", "keep", "before", "after", "rapid",
            "baseline", "rapid", "after", "before", "keep",
            "baseline", "keep", "before", "after", "rapid",
            "baseline", "rapid", "after", "before", "keep",
        ])
    }

    @objc func runPrimedComparison() { requestComparison(Array(repeating: "primed", count: 20)) }

    @objc func runIMEComparison() {
        requestComparison(
            Array(
                repeating: ["primed", "apple-primed", "primed-selector-alive", "apple-primed-alive"], count: 6
            ).flatMap { $0 }, withRecovery: true)
    }

    @objc func runManualComparison() {
        requestComparison(["primed", "apple-primed", "primed", "apple-primed"], withRecovery: true, manualKeys: true)
    }

    @objc func runSourceComparison() {
        let conditions = [
            "primed", "primed-post-delay", "primed-selector-hold",
            "primed-selector-pump", "primed-pre-delay", "primed-in-process",
        ]
        // Rotate order so each condition occupies every position in one block.
        let cases = (0..<conditions.count).flatMap { offset in
            Array(conditions[offset...] + conditions[..<offset])
        }
        requestComparison(cases, withRecovery: true)
    }

    @objc func preflight() { requestComparison([], preflightOnly: true) }

    func requestComparison(
        _ cases: [String], preflightOnly: Bool = false, withRecovery: Bool = false, manualKeys: Bool = false
    ) {
        guard automatedCases.isEmpty, !startRequested else { return }
        startRequested = true
        record("comparisonRequested", extra: ["preflightOnly": preflightOnly])
        // AXPress can invoke a button in a background window. Request focus
        // once in response to that explicit button action, then check it after
        // the action has returned. Never keep reactivating against user input.
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.startRequested = false
            guard NSApp.isActive, self.window.isKeyWindow, self.window.firstResponder === self.textView else {
                record("comparisonStartRejected")
                statusLabel.stringValue = "Test field did not obtain focus — no keys requested"
                return
            }
            if preflightOnly {
                record("preflightReady")
                statusLabel.stringValue = "Preflight ready — no keys sent and no source selected"
            } else {
                self.compareRecovery = withRecovery
                self.manualComparison = manualKeys
                self.startComparison(cases)
            }
        }
    }

    func startComparison(_ cases: [String]) {
        guard automatedCases.isEmpty, NSApp.isActive, window.isKeyWindow else { return }
        automatedCases = cases
        automatedIndex = 0
        comparisonGeneration += 1
        record("comparisonBegin")
        nextAutomatedTrial()
    }

    func nextAutomatedTrial() {
        guard !automatedCases.isEmpty else { return }
        guard NSApp.isActive, window.isKeyWindow else {
            abortComparison()
            return
        }
        guard automatedIndex < automatedCases.count else {
            // The Apple condition only uses an already-enabled input source.
            // Restore Karukan while this disposable field still owns focus.
            if automatedCases.contains(where: { $0.hasPrefix("apple-primed") }) {
                selectSource("dev.togatoga.inputmethod.Karukan.Japanese")
            }
            automatedCases = []
            record("comparisonCompleted")
            statusLabel.stringValue =
                manualComparison
                ? "手入力試験が完了しました。Karukanへ戻しました。通常の作業へ戻れます。"
                : "Comparisons completed — keyboard and mouse are free"
            return
        }
        reset()
        let mode = automatedCases[automatedIndex]
        let generation = comparisonGeneration
        record("trialBegin", extra: ["condition": mode, "caseIndex": automatedIndex])
        // Restore a known source before each condition. Key generation is done
        // in a separate process, only after trialReady and foreground checks.
        selectSource("com.apple.keylayout.ABC")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.comparisonGeneration == generation else { return }
            guard NSApp.isActive, self.window.isKeyWindow else {
                self.abortComparison()
                return
            }
            if mode.hasPrefix("primed") || mode.hasPrefix("apple-primed") {
                self.awaitingPrime = true
                if self.manualComparison {
                    statusLabel.stringValue =
                        "手入力 \(self.automatedIndex + 1)/\(self.automatedCases.count)：a を1文字だけ押してください（Enter不要）"
                }
                record("trialPrimeReady", extra: ["condition": mode, "caseIndex": self.automatedIndex])
                self.setTrialTimeout()
                return
            }
            self.selectSource("dev.togatoga.inputmethod.Karukan.Japanese")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                guard self.comparisonGeneration == generation else { return }
                guard NSApp.isActive, self.window.isKeyWindow else {
                    self.abortComparison()
                    return
                }
                if mode == "baseline" {
                    self.readyForTrial(mode)
                } else if mode == "rapid" {
                    self.selectSource("com.apple.keylayout.ABC")
                    self.selectSource("dev.togatoga.inputmethod.Karukan.Japanese")
                    self.readyForTrial(mode)
                } else {
                    self.showOverlay(order: mode) { self.readyForTrial(mode) }
                }
            }
        }
    }

    func readyForTrial(_ condition: String) {
        guard !automatedCases.isEmpty else { return }
        guard NSApp.isActive, window.isKeyWindow, window.firstResponder === textView else {
            abortComparison()
            return
        }
        awaitingReturn = true
        record("trialReady", extra: ["condition": condition, "caseIndex": automatedIndex])
        statusLabel.stringValue =
            manualComparison
            ? "手入力 \(automatedIndex + 1)/\(automatedCases.count)：k → a → Enter を1回ずつ押してください"
            : "Comparison \(automatedIndex + 1)/\(automatedCases.count) — \(condition)"
        setTrialTimeout()
    }

    func setTrialTimeout() {
        trialTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.abortComparison() }
        trialTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + (manualComparison ? 30 : 4), execute: timeout)
    }

    func finishPrimeAfterLetter() {
        guard awaitingPrime else { return }
        awaitingPrime = false
        trialTimeout?.cancel()
        let valid = textView.string == "a" && !textView.hasMarkedText()
        record("trialPrimeObserved", extra: ["matchesLatinA": valid])
        guard valid else {
            abortComparison()
            return
        }
        textView.string = ""
        awaitingSource = true
        if manualComparison { statusLabel.stringValue = "切替中です。次の案内が出るまでお待ちください。" }
        let condition = automatedCases[automatedIndex]
        record("trialSourceSelectionRequested", extra: ["condition": condition, "caseIndex": automatedIndex])
        if condition == "primed-in-process" {
            selectSource("dev.togatoga.inputmethod.Karukan.Japanese")
        }
        setTrialTimeout()
    }

    func finishTrialAfterReturn() {
        guard awaitingReturn, automatedCases.indices.contains(automatedIndex) else { return }
        awaitingReturn = false
        trialTimeout?.cancel()
        if manualComparison { statusLabel.stringValue = "確認中です。次の案内が出るまでお待ちください。" }
        if recoveryPhase != nil {
            finishRecoveryAfterReturn()
            return
        }
        record("trialResult", extra: ["condition": automatedCases[automatedIndex], "caseIndex": automatedIndex])
        if textView.string != "か" || textView.hasMarkedText() {
            if compareRecovery {
                beginRecovery(0)
            } else {
                suspendOnFailure()
            }
            return
        }
        advanceTrial()
    }

    func advanceTrial() {
        automatedIndex += 1
        let generation = comparisonGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.comparisonGeneration == generation else { return }
            self.nextAutomatedTrial()
        }
    }

    func suspendOnFailure() {
        recoveryPhase = nil
        automatedCases = []
        record("comparisonSuspendedOnFailure")
        statusLabel.stringValue = "Unexpected result preserved — no more test input"
    }

    func beginRecovery(_ phase: Int) {
        guard NSApp.isActive, window.isKeyWindow, window.firstResponder === textView else {
            abortComparison()
            return
        }
        recoveryPhase = phase
        record("recoveryBegin", extra: ["phase": recoveryNames[phase], "caseIndex": automatedIndex])
        if phase == 1 {
            // Getters are deliberately excluded from the unchanged control.
            // Their observer effect is tested before explicit reconnection.
            let context = textView.inputContext
            var fields: [String: Any] = ["exists": context != nil]
            if let context {
                fields["context"] = String(describing: ObjectIdentifier(context))
                fields["selectedSource"] = context.selectedKeyboardInputSource
                fields["allowedLocales"] = context.allowedInputSourceLocales
            }
            record("recoveryContextSnapshot", extra: fields)
        } else if phase == 2 {
            record("recoveryReconnectBegin")
            let context = textView.inputContext
            context?.deactivate()
            context?.activate()
            record("recoveryReconnectEnd")
        }
        recoveryStartLength = textView.string.utf16.count
        recoveryStartMarkedWrites = markedWriteCount
        awaitingReturn = true
        if manualComparison {
            let names = ["無変更で再試行", "状態の確認後", "接続の再開後"]
            statusLabel.stringValue = "\(names[phase])：k → a → Enter を1回ずつ押してください"
        }
        record("recoveryReady", extra: ["phase": recoveryNames[phase], "caseIndex": automatedIndex])
        setTrialTimeout()
    }

    func finishRecoveryAfterReturn() {
        guard let phase = recoveryPhase else { return }
        let body = textView.string as NSString
        let suffix = body.length >= recoveryStartLength ? body.substring(from: recoveryStartLength) : ""
        let recovered = suffix == "か" && !textView.hasMarkedText()
        record(
            "recoveryResult",
            extra: [
                "phase": recoveryNames[phase], "caseIndex": automatedIndex,
                "lengthDelta": body.length - recoveryStartLength,
                "markedWrites": markedWriteCount - recoveryStartMarkedWrites, "committedKa": recovered,
            ])
        let generation = comparisonGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.comparisonGeneration == generation else { return }
            if phase + 1 < self.recoveryNames.count {
                self.beginRecovery(phase + 1)
            } else {
                self.recoveryPhase = nil
                if recovered { self.advanceTrial() } else { self.suspendOnFailure() }
            }
        }
    }

    func abortComparison() {
        comparisonGeneration += 1
        trialTimeout?.cancel()
        awaitingReturn = false
        awaitingPrime = false
        awaitingSource = false
        recoveryPhase = nil
        automatedCases = []
        overlay?.orderOut(nil)
        overlay = nil
        record("comparisonAborted")
        statusLabel.stringValue = "Comparison stopped — no more test input"
    }

    func windowDidBecomeKey(_ notification: Notification) { record("windowKey") }
    func windowDidResignKey(_ notification: Notification) { record("windowResign") }
    func applicationDidBecomeActive(_ notification: Notification) { record("appActive") }
    func applicationDidResignActive(_ notification: Notification) {
        record("appInactive")
        if !automatedCases.isEmpty { abortComparison() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = ProbeApplication.shared
if traceEnabled {
    KPInstallContextTrace { name, object, client, event, result, depth in
        var fields: [String: Any] = [
            "object": String(format: "0x%llx", object), "client": String(format: "0x%llx", client),
            "callDepth": depth,
        ]
        if let event { fields.merge(eventMetadata(event)) { _, value in value } }
        if result >= 0 { fields["consumed"] = result != 0 }
        record(String(cString: name), extra: fields)
    }
}
let delegate = ProbeDelegate()
probeDelegate = delegate
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
