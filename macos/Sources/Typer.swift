import Cocoa

/// Inserts text in the focused app with synthetic key events.
enum Typer {
    private static let vKey: CGKeyCode = 9
    static let returnKey: CGKeyCode = 36
    /// Tag on every key event VoiceBar posts, so its own typing is not taken
    /// for the user's.
    static let marker: Int64 = 0x5642_4152

    static func press(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.setIntegerValueField(.eventSourceUserData, value: marker)
            event?.post(tap: .cghidEventTap)
        }
    }

    static func isOurs(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == marker
    }

    /// Waits (up to 1 s) for the user to let go of the hotkey modifiers, so
    /// they do not combine with the keys we post.
    static func waitForModifierRelease() async {
        for _ in 0..<50 {
            if CGEventSource.flagsState(.combinedSessionState).intersection(Hotkey.modifierMask).isEmpty {
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Pastes `text` via the clipboard, then restores the previous clipboard.
    static func paste(_ text: String) async {
        let board = NSPasteboard.general
        let saved: [NSPasteboardItem] = (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }

        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // nspasteboard.org markers: clipboard managers skip transient, concealed items.
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        board.clearContents()
        board.writeObjects([item])
        let ourChange = board.changeCount

        press(vKey, flags: .maskCommand)
        try? await Task.sleep(for: .milliseconds(500))

        // Restore only if nothing else has written to the clipboard since.
        if board.changeCount == ourChange {
            board.clearContents()
            if !saved.isEmpty { board.writeObjects(saved) }
        }
    }

}
