import Carbon
import Cocoa

enum Action: Int, CaseIterable {
    case record, submit
    /// Dictates like `.record`, wrapping the text in the user's template.
    case bracket
    /// Escape, bound only while recording: stops and discards the recording.
    case escape
    /// Inserts the wrapper with the cursor at its placeholder, without recording.
    case insertWrapper
}

/// A key plus the exact set of modifiers held with it.
struct Hotkey: Equatable {
    static let modifierMask: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]

    private static let namedKeys: [String: UInt16] = [
        "space": 49, "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5,
        "h": 4, "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31,
        "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13,
        "x": 7, "y": 16, "z": 6,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    let keyCode: UInt16
    let flags: CGEventFlags
    /// Display name of the key, e.g. "J" or "Space".
    let keyName: String

    init(keyCode: UInt16, flags: CGEventFlags, keyName: String) {
        self.keyCode = keyCode
        self.flags = flags.intersection(Hotkey.modifierMask)
        self.keyName = keyName
    }

    /// From the Python tool's config: key name plus modifier names.
    init?(key: String, modifiers: [String]) {
        guard let code = Hotkey.namedKeys[key.lowercased()] else { return nil }
        var f: CGEventFlags = []
        for m in modifiers {
            switch m.lowercased() {
            case "cmd", "command", "super": f.insert(.maskCommand)
            case "shift": f.insert(.maskShift)
            case "ctrl", "control": f.insert(.maskControl)
            case "alt", "option": f.insert(.maskAlternate)
            default: break
            }
        }
        self.init(keyCode: code, flags: f, keyName: key.count == 1 ? key.uppercased() : key.capitalized)
    }

    /// From a key press in the shortcut recorder.
    init(event: NSEvent) {
        let m = event.modifierFlags
        var f: CGEventFlags = []
        if m.contains(.command) { f.insert(.maskCommand) }
        if m.contains(.shift) { f.insert(.maskShift) }
        if m.contains(.control) { f.insert(.maskControl) }
        if m.contains(.option) { f.insert(.maskAlternate) }
        let name = Hotkey.namedKeys.first { $0.value == event.keyCode }?.key
        let display = name.map { $0.count == 1 ? $0.uppercased() : $0.capitalized }
            ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        self.init(keyCode: event.keyCode, flags: f, keyName: display)
    }

    var label: String {
        var s = ""
        if flags.contains(.maskControl) { s += "⌃" }
        if flags.contains(.maskAlternate) { s += "⌥" }
        if flags.contains(.maskShift) { s += "⇧" }
        if flags.contains(.maskCommand) { s += "⌘" }
        return s + keyName
    }

    fileprivate var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if flags.contains(.maskCommand) { m |= UInt32(cmdKey) }
        if flags.contains(.maskShift) { m |= UInt32(shiftKey) }
        if flags.contains(.maskControl) { m |= UInt32(controlKey) }
        if flags.contains(.maskAlternate) { m |= UInt32(optionKey) }
        return m
    }

    var plist: [String: Any] { ["keyCode": Int(keyCode), "flags": flags.rawValue, "keyName": keyName] }

    init?(plist: Any?) {
        guard let d = plist as? [String: Any], let code = d["keyCode"] as? Int,
              let raw = d["flags"] as? UInt64, let name = d["keyName"] as? String else { return nil }
        self.init(keyCode: UInt16(code), flags: CGEventFlags(rawValue: raw), keyName: name)
    }
}

/// System-wide shortcuts through RegisterEventHotKey, the standard macOS
/// hotkey API: the system consumes the key (nothing leaks into the focused
/// app) and reports both press and release, so hold-to-talk needs no key
/// tracking of our own.
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    var onDown: (Action) -> Void = { _ in }
    var onUp: (Action) -> Void = { _ in }
    /// Labels of shortcuts the system refused (already taken by another app).
    private(set) var failed: [String] = []

    private var bindings: [Action: Hotkey] = [:]
    private var refs: [EventHotKeyRef] = []
    private var down: Set<Action> = []
    private var handler: EventHandlerRef?
    private var suspended = false

    func set(_ bindings: [Action: Hotkey]) {
        self.bindings = bindings
        if !suspended { register() }
    }

    /// Lets the shortcut recorder see keys that are currently bound.
    func suspend() { suspended = true; unregister() }
    func resume() { suspended = false; register() }

    private var escapeRef: EventHotKeyRef?

    /// Claims Escape (as `.escape`) only while enabled, so it works normally
    /// in other apps the rest of the time. Registered on its own so the other
    /// shortcuts, and a held hold-to-talk key, are left untouched.
    func setEscapeEnabled(_ enabled: Bool) {
        if enabled, escapeRef == nil {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: 0x5642_4152, id: UInt32(Action.escape.rawValue))
            if RegisterEventHotKey(53 /* Escape */, 0, id, GetEventDispatcherTarget(), 0, &ref) == noErr {
                escapeRef = ref
            }
        } else if !enabled, let ref = escapeRef {
            UnregisterEventHotKey(ref)
            escapeRef = nil
            down.remove(.escape)
        }
    }

    private func register() {
        unregister()
        installHandler()
        failed = []
        for (action, hotkey) in bindings {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: 0x5642_4152 /* "VBAR" */, id: UInt32(action.rawValue))
            let status = RegisterEventHotKey(UInt32(hotkey.keyCode), hotkey.carbonModifiers, id,
                                             GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) } else { failed.append(hotkey.label) }
        }
    }

    private func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        down = []
    }

    private func installHandler() {
        guard handler == nil else { return }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData!).takeUnretainedValue()
            // Carbon dispatches hotkey events on the main thread.
            MainActor.assumeIsolated { center.fire(id.id, pressed: pressed) }
            return noErr
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    private func fire(_ id: UInt32, pressed: Bool) {
        guard let action = Action(rawValue: Int(id)) else { return }
        if pressed {
            if down.insert(action).inserted { onDown(action) }  // ignore key repeat
        } else if down.remove(action) != nil {
            onUp(action)
        }
    }
}
