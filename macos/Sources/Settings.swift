import Cocoa
import Security
import ServiceManagement
import SwiftUI

/// API keys live in the login Keychain, not in a config file.
enum Keychain {
    private static let service = "com.rstiskalek.voicebar"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> String {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func set(_ account: String, _ value: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}

/// User settings: shortcuts and options in UserDefaults, keys in the Keychain.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    /// Called after a shortcut changes, so the app can re-register them.
    var onChange: () -> Void = {}
    /// Called after a microphone setting changes.
    var onAudioChange: () -> Void = {}

    @Published var hotkeys: [Action: Hotkey] { didSet { saveHotkeys(); onChange() } }
    @Published var keepMicReady: Bool {
        didSet { defaults.set(keepMicReady, forKey: "keepMicReady"); onAudioChange() }
    }
    @Published var holdToTalk: Bool { didSet { defaults.set(holdToTalk, forKey: "holdToTalk") } }
    @Published var provider: String { didSet { defaults.set(provider, forKey: "provider") } }
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    @Published var vocabulary: String { didSet { defaults.set(vocabulary, forKey: "vocabulary") } }
    /// Wrapper for the bracket shortcut; "..." marks where the dictation goes.
    @Published var wrapTemplate: String { didSet { defaults.set(wrapTemplate, forKey: "wrapTemplate") } }
    @Published var transcriptionKey: String { didSet { Keychain.set("transcription", transcriptionKey) } }
    @Published var launchAtLogin: Bool {
        didSet {
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                logger.error("launch at login: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private init() {
        Settings.importPythonConfigOnce()
        let d = UserDefaults.standard
        // ponytail: leftovers of the removed correct/delete shortcuts; drop this once every install has run it.
        Keychain.set("anthropic", "")
        ["hotkey.edit", "hotkey.delete", "claudeModel"].forEach { d.removeObject(forKey: $0) }
        // Added after the config import, so existing installs get the default once.
        if !d.bool(forKey: "seededBracketHotkey") {
            d.set(Hotkey(key: "j", modifiers: ["cmd", "shift"])!.plist, forKey: "hotkey.\(Action.bracket)")
            d.set(true, forKey: "seededBracketHotkey")
        }
        var keys: [Action: Hotkey] = [:]
        for action in Action.allCases {
            keys[action] = Hotkey(plist: d.object(forKey: "hotkey.\(action)"))
        }
        hotkeys = keys
        holdToTalk = d.object(forKey: "holdToTalk") as? Bool ?? false  // default: tap to start and stop
        keepMicReady = d.bool(forKey: "keepMicReady")
        provider = d.string(forKey: "provider") ?? "groq"
        language = d.string(forKey: "language") ?? "en"
        vocabulary = d.string(forKey: "vocabulary") ?? ""
        wrapTemplate = d.string(forKey: "wrapTemplate") ?? "[...]"
        transcriptionKey = Keychain.get("transcription")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func saveHotkeys() {
        for action in Action.allCases {
            if let hk = hotkeys[action] { defaults.set(hk.plist, forKey: "hotkey.\(action)") }
            else { defaults.removeObject(forKey: "hotkey.\(action)") }
        }
    }

    /// Seeds settings from ~/.config/voicebar/config.toml on first launch,
    /// with the Python tool's macOS defaults for anything it does not set.
    private static func importPythonConfigOnce() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "importedPythonConfig") else { return }
        let cfg = Config.load()

        func hotkey(_ table: String, key: String, mods: [String]) -> Hotkey? {
            Hotkey(key: cfg.string(table, "key") ?? key, modifiers: cfg.strings(table, "modifiers") ?? mods)
        }
        let seeded: [Action: Hotkey?] = [
            .record: hotkey("hotkey", key: "space", mods: ["cmd", "shift"]),
            .submit: hotkey("hotkey_submit", key: "space", mods: ["cmd", "shift", "ctrl"]),
        ]
        for (action, hk) in seeded {
            if let hk { d.set(hk.plist, forKey: "hotkey.\(action)") }
        }
        d.set(cfg.string("hotkey", "mode") == "hold", forKey: "holdToTalk")
        if let v = cfg.string("transcription", "backend") { d.set(v, forKey: "provider") }
        if let v = cfg.string("transcription", "language") { d.set(v, forKey: "language") }
        if let v = cfg.string("transcription", "prompt") { d.set(v, forKey: "vocabulary") }
        if let v = cfg.string("transcription", "api_key"), !v.isEmpty { Keychain.set("transcription", v) }
        d.set(true, forKey: "importedPythonConfig")
    }
}

// MARK: - Settings window

/// Captures the next key combination typed into the Settings window.
// ponytail: a class instead of SwiftUI @State, which needs a macro plugin the
// Command Line Tools do not ship.
@MainActor
final class ShortcutRecorder: ObservableObject {
    static let shared = ShortcutRecorder()
    /// The action whose shortcut is being recorded, if any.
    @Published private(set) var recording: Action?
    private var monitor: Any?

    func start(_ action: Action) {
        stop()
        recording = action
        HotkeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.capture(event) }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording != nil { HotkeyCenter.shared.resume() }
        recording = nil
    }

    private func capture(_ event: NSEvent) {
        guard let action = recording else { return }
        if event.keyCode == 53 { stop(); return }  // Esc cancels
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if mods.isEmpty || mods == .shift { NSSound.beep(); return }  // needs ⌘, ⌃ or ⌥
        stop()
        Settings.shared.hotkeys[action] = Hotkey(event: event)
    }
}

private struct ShortcutField: View {
    let action: Action
    @ObservedObject var settings = Settings.shared
    @ObservedObject var recorder = ShortcutRecorder.shared

    var body: some View {
        let recording = recorder.recording == action
        HStack(spacing: 6) {
            Button(recording ? "Type shortcut…" : (settings.hotkeys[action]?.label ?? "Click to set")) {
                recording ? recorder.stop() : recorder.start(action)
            }
            .frame(minWidth: 130)
            if settings.hotkeys[action] != nil, !recording {
                Button { settings.hotkeys[action] = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Remove shortcut")
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared

    var body: some View {
        Form {
            Section("Spoken language") {
                Picker("Language", selection: $settings.language) {
                    Text("English").tag("en")
                    Text("Czech").tag("cs")
                    Text("Automatic").tag("")
                    if !["en", "cs", ""].contains(settings.language) {
                        Text(settings.language).tag(settings.language)
                    }
                }
            }
            Section("Shortcuts") {
                LabeledContent("Dictate") { ShortcutField(action: .record) }
                LabeledContent("Dictate and press Return") { ShortcutField(action: .submit) }
                LabeledContent("Dictate wrapped") { ShortcutField(action: .bracket) }
                TextField("Wrap in", text: $settings.wrapTemplate, prompt: Text("empty: no wrapping"))
                Picker("Recording", selection: $settings.holdToTalk) {
                    Text("Press to start, press again to stop").tag(false)
                    Text("Hold the shortcut while speaking").tag(true)
                }
            }
            Section {
                Toggle("Keep microphone ready", isOn: $settings.keepMicReady)
            } header: {
                Text("Microphone")
            } footer: {
                Text("Keeps the microphone running between recordings so the first word is never clipped; macOS then shows its microphone indicator all the time.")
                    .foregroundStyle(.secondary)
            }
            Section("Transcription (Whisper)") {
                Picker("Provider", selection: $settings.provider) {
                    Text("Groq").tag("groq")
                    Text("OpenAI").tag("openai")
                }
                SecureField("API key", text: $settings.transcriptionKey)
                TextField("Vocabulary hint", text: $settings.vocabulary,
                          prompt: Text("e.g. UKIDSS, 2M++, Schechter, Petrosian"), axis: .vertical)
                    .lineLimit(2...4)
            }
            Section {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
