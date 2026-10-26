import AVFoundation
import Cocoa
import SwiftUI
import os

/// Readable with: log show --predicate 'subsystem == "com.rstiskalek.voicebar"' --last 10m
let logger = Logger(subsystem: "com.rstiskalek.voicebar", category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSTextFieldDelegate, NSWindowDelegate {
    private static let minSeconds = 0.3
    private static let maxSeconds = 300.0  // 9.6 MB of audio, under Groq's 25 MB free-tier limit
    private static let silencePeak = 500

    private let settings = Settings.shared
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let recorder = Recorder()
    private var settingsWindow: NSWindow?

    private enum State { case idle, recording, processing }
    private var state = State.idle {
        didSet {
            updateIcon()
            HotkeyCenter.shared.setEscapeEnabled(state == .recording)
            switch state {
            case .idle: indicator.hide()
            case .recording: indicator.show(.systemRed, reposition: true)
            case .processing: indicator.show(.systemOrange, reposition: false)
            }
        }
    }
    private let indicator = RecordingIndicator()
    private var recordingID = 0
    private var activeAction = Action.record
    private var targetApp: NSRunningApplication?

    /// App that consecutive dictations went into; the next one gets a leading space.
    private var continuingIn: pid_t?
    private var lastTranscript = ""
    private var status = "Ready" { didSet { logger.notice("status: \(self.status, privacy: .public)") } }

    private let recoveryURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VoiceBar/failed-recording.wav")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.editMenu()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        HotkeyCenter.shared.onDown = { [weak self] in self?.hotkeyDown($0) }
        HotkeyCenter.shared.onUp = { [weak self] in self?.hotkeyUp($0) }
        settings.onChange = { [weak self] in self?.applyHotkeys() }
        applyHotkeys()
        settings.onAudioChange = { [weak self] in self?.applyAudioSettings() }
        applyAudioSettings()

        // Once the user types or clicks, the cursor may no longer follow the last
        // dictation, so auto-spacing could hit other text.
        NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard !Typer.isOurs(event) else { return }
            MainActor.assumeIsolated { self?.continuingIn = nil }
        }

        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        // Pasting posts a ⌘V keystroke, which needs Accessibility; this prompts once.
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(prompt) {
            status = "Allow VoiceBar under Privacy & Security › Accessibility"
        }
        if settings.transcriptionKey.isEmpty { openSettings() }
        logger.notice("""
            started; accessibility=\(AXIsProcessTrusted(), privacy: .public) \
            microphone=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue, privacy: .public) (3 = authorized)
            """)
    }

    // MARK: - Shortcuts

    private func applyHotkeys() {
        HotkeyCenter.shared.set(settings.hotkeys)
        let bound = settings.hotkeys.map { "\($0.key)=\($0.value.label)" }.sorted().joined(separator: " ")
        logger.notice("shortcuts: \(bound, privacy: .public)")
        let failed = HotkeyCenter.shared.failed
        if !failed.isEmpty { status = "Shortcut in use by another app: \(failed.joined(separator: ", "))" }
    }

    private func applyAudioSettings() {
        recorder.setWarm(settings.keepMicReady)
    }

    private func hotkeyDown(_ action: Action) {
        if action == .escape { stopRecording(discard: true); return }
        switch state {
        case .idle: startRecording(action)
        case .recording where !settings.holdToTalk: stopRecording()
        default: break
        }
    }

    private func hotkeyUp(_ action: Action) {
        if settings.holdToTalk, state == .recording, action == activeAction { stopRecording() }
    }


    // MARK: - Recording

    private func startRecording(_ action: Action) {
        do {
            try recorder.start()
        } catch {
            fail("Microphone: \(error.localizedDescription)")
            return
        }
        activeAction = action
        targetApp = NSWorkspace.shared.frontmostApplication
        state = .recording
        status = "Recording (\(action)) for \(targetApp?.localizedName ?? "unknown app")"
        NSSound(named: "Tink")?.play()

        recordingID += 1
        let id = recordingID
        Task {
            try? await Task.sleep(for: .seconds(Self.maxSeconds))
            if state == .recording, recordingID == id { stopRecording() }
        }
    }

    private func stopRecording(discard: Bool = false) {
        guard state == .recording else { return }
        let pcm = recorder.stop()
        if discard {
            status = "Recording discarded"
            state = .idle
            return
        }
        let seconds = Double(pcm.count) / Double(2 * Recorder.sampleRate)
        logger.notice("recorded \(seconds, format: .fixed(precision: 2), privacy: .public) s (\(String(describing: self.activeAction), privacy: .public)), peak \(peakLevel(pcm), privacy: .public)")
        guard seconds >= Self.minSeconds else {
            status = "Recording too short"
            state = .idle
            return
        }
        // ponytail: fixed threshold (~-36 dBFS peak); make it a setting if a quiet mic trips it.
        guard peakLevel(pcm) >= Self.silencePeak else {
            status = "Only silence recorded"
            state = .idle
            return
        }
        state = .processing
        let action = activeAction
        let target = targetApp
        Task {
            await process(pcm, action: action, target: target)
            state = .idle
        }
    }

    private func process(_ pcm: Data, action: Action, target: NSRunningApplication?) async {
        guard !settings.transcriptionKey.isEmpty else {
            fail("Add a \(settings.provider.capitalized) API key in Settings")
            openSettings()
            return
        }
        status = "Transcribing…"
        let wav = wavData(pcm)
        let text: String
        do {
            text = try await transcriber().transcribe(wav: wav)
        } catch {
            saveRecovery(wav, action: action)
            let reason = (error as? URLError).map { "Network error (\($0.code.rawValue))" }
                ?? "Transcription failed: \(error.localizedDescription)"
            fail("\(reason); recording saved, use “Transcribe saved recording”")
            return
        }
        guard !isLikelyHallucination(text) else {
            status = text.isEmpty ? "No speech detected" : "Ignored “\(text)” (Whisper's filler for noise)"
            return
        }
        lastTranscript = text

        await Typer.waitForModifierRelease()
        if let target, target != NSWorkspace.shared.frontmostApplication {
            target.activate()
            try? await Task.sleep(for: .milliseconds(150))
        }

        let pid = target?.processIdentifier
        let body = action == .bracket ? wrap(text, in: settings.wrapTemplate) : text
        let insert = (continuingIn != nil && continuingIn == pid) ? " " + body : body
        await Typer.paste(insert)
        continuingIn = pid
        if action == .submit {
            try? await Task.sleep(for: .milliseconds(150))
            Typer.press(Typer.returnKey)
            continuingIn = nil
        }
        status = "Ready"
    }

    // MARK: - Services

    private var providerURL: URL {
        URL(string: settings.provider == "openai" ? "https://api.openai.com/v1" : "https://api.groq.com/openai/v1")!
    }

    private func transcriber() -> Transcriber {
        Transcriber(baseURL: providerURL, apiKey: settings.transcriptionKey,
                    model: settings.provider == "openai" ? "whisper-1" : "whisper-large-v3-turbo",
                    language: settings.language, prompt: settings.vocabulary)
    }

    private func saveRecovery(_ wav: Data, action: Action) {
        try? FileManager.default.createDirectory(at: recoveryURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? wav.write(to: recoveryURL)
        UserDefaults.standard.set(action.rawValue, forKey: "recoveryAction")
    }

    @objc private func transcribeSaved() {
        guard state == .idle, let wav = try? Data(contentsOf: recoveryURL), wav.count > 44 else { return }
        try? FileManager.default.removeItem(at: recoveryURL)
        let target = NSWorkspace.shared.frontmostApplication
        let action = Action(rawValue: UserDefaults.standard.integer(forKey: "recoveryAction")) ?? .record
        state = .processing
        Task {
            await process(Data(wav.dropFirst(44)), action: action, target: target)
            state = .idle
        }
    }

    private func fail(_ message: String) {
        status = message
        NSSound(named: "Basso")?.play()
    }

    // MARK: - Menu bar

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let (symbol, tint): (String, NSColor?) = switch state {
        case .idle: ("mic", nil)
        case .recording: ("mic.fill", .systemRed)
        case .processing: ("ellipsis.circle", nil)
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "VoiceBar")
        button.contentTintColor = tint
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func info(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        func action(_ title: String, _ selector: Selector, key: String = "") {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }

        info(status)
        for (code, name) in [("en", "English"), ("cs", "Czech")] {
            let item = NSMenuItem(title: "Language: \(name)", action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            item.state = settings.language == code ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        if let hotkey = settings.hotkeys[.record] {
            info("\(settings.holdToTalk ? "Hold" : "Press") \(hotkey.label) to dictate")
        }
        if !lastTranscript.isEmpty {
            let short = lastTranscript.count > 40 ? lastTranscript.prefix(40) + "…" : Substring(lastTranscript)
            action("Copy “\(short)”", #selector(copyLast))
        }
        // A text field in the menu, so the wrapper can be retyped without opening Settings.
        let field = NSTextField(string: settings.wrapTemplate)
        field.placeholderString = "empty: no wrapping"
        field.delegate = self
        field.target = self
        field.action = #selector(closeMenu)
        let label = NSTextField(labelWithString: "Wrap in:")
        let row = NSStackView(views: [label, field])
        row.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 14)
        row.frame.size = NSSize(width: 260, height: 30)
        let wrapItem = NSMenuItem()
        wrapItem.view = row
        menu.addItem(wrapItem)
        if FileManager.default.fileExists(atPath: recoveryURL.path) {
            action("Transcribe saved recording", #selector(transcribeSaved))
        }
        menu.addItem(.separator())
        action("Settings…", #selector(openSettings), key: ",")
        let quit = NSMenuItem(title: "Quit VoiceBar", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
    }

    func controlTextDidChange(_ note: Notification) {
        if let field = note.object as? NSTextField { settings.wrapTemplate = field.stringValue }
    }

    @objc private func selectLanguage(_ item: NSMenuItem) {
        guard let code = item.representedObject as? String else { return }
        settings.language = code
    }

    @objc private func closeMenu() { statusItem.menu?.cancelTracking() }

    @objc private func copyLast() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
    }

    // An unfinished shortcut recording would otherwise leave every shortcut off.
    func windowWillClose(_ notification: Notification) { ShortcutRecorder.shared.stop() }
    func applicationDidResignActive(_ notification: Notification) { ShortcutRecorder.shared.stop() }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "VoiceBar Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// A menu-bar app has no menu bar of its own, but text fields need the
    /// Edit menu's key equivalents for ⌘V, ⌘C, ⌘X, ⌘A and ⌘Z to work.
    private static func editMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem()
        item.submenu = edit
        let main = NSMenu()
        main.addItem(item)
        return main
    }
}
