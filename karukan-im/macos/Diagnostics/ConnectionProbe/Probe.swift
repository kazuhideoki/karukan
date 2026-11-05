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
    }
}

// Deliberately no keyDown override and no custom NSTextInputContext.
final class ProbeTextView: NSTextView {
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
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
    var trialTimeout: DispatchWorkItem?
    var comparisonGeneration = 0
    let textView = ProbeTextView(frame: NSRect(x: 0, y: 0, width: 1000, height: 220))

    func applicationDidFinishLaunching(_ notification: Notification) {
        observedView = textView
        window = NSWindow(
            contentRect: NSRect(x: 100, y: 160, width: 1120, height: 460),
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
            guard let self else { return }
            guard NSApp.isActive else {
                self.abortComparison()
                return
            }
            if order == "before" { self.selectSource("dev.togatoga.inputmethod.Karukan.Japanese") }
            DispatchQueue.main.asyncAfter(deadline: .now() + (order == "before" ? 0.05 : 0)) {
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
        guard automatedCases.isEmpty, NSApp.isActive, window.isKeyWindow else { return }
        automatedCases = [
            "baseline", "keep", "before", "after", "rapid",
            "baseline", "rapid", "after", "before", "keep",
            "baseline", "keep", "before", "after", "rapid",
            "baseline", "rapid", "after", "before", "keep",
        ]
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
            automatedCases = []
            record("comparisonCompleted")
            statusLabel.stringValue = "20 comparisons completed — keyboard and mouse are free"
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
        statusLabel.stringValue = "Comparison \(automatedIndex + 1)/20 — \(condition)"
        let timeout = DispatchWorkItem { [weak self] in self?.abortComparison() }
        trialTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: timeout)
    }

    func finishTrialAfterReturn() {
        guard awaitingReturn, automatedCases.indices.contains(automatedIndex) else { return }
        awaitingReturn = false
        trialTimeout?.cancel()
        record("trialResult", extra: ["condition": automatedCases[automatedIndex], "caseIndex": automatedIndex])
        automatedIndex += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.nextAutomatedTrial() }
    }

    func abortComparison() {
        comparisonGeneration += 1
        trialTimeout?.cancel()
        awaitingReturn = false
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
