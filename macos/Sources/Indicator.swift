import ApplicationServices
import Cocoa

/// A small pulsing dot beside the text cursor while recording or transcribing.
/// Apps draw their own caret, so the caret itself cannot be made to blink.
@MainActor
final class RecordingIndicator {
    private static let side = 18.0
    private let panel: NSPanel
    private let dot = CALayer()

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.side, height: Self.side),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Dictation runs in other apps; NSPanel otherwise hides on deactivation.
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = NSView(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        view.wantsLayer = true
        dot.frame = CGRect(x: 3, y: 3, width: 12, height: 12)
        dot.cornerRadius = 6
        dot.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        dot.borderWidth = 1.5
        view.layer?.addSublayer(dot)
        panel.contentView = view
    }

    /// Shows the dot in `color`, moving it to the caret when `reposition` is set.
    func show(_ color: NSColor, reposition: Bool) {
        dot.backgroundColor = color.cgColor
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.2
        pulse.duration = 0.5
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.removeAllAnimations()
        dot.add(pulse, forKey: "pulse")
        if reposition { panel.setFrameOrigin(Self.anchor()) }
        panel.orderFrontRegardless()
    }

    func hide() {
        dot.removeAllAnimations()
        panel.orderOut(nil)
    }

    /// Just right of the text caret when the focused app reports it, otherwise
    /// beside the mouse pointer.
    private static func anchor() -> NSPoint {
        if let caret = caretRect(), let primary = NSScreen.screens.first {
            // Accessibility measures from the top-left of the primary screen.
            return NSPoint(x: caret.maxX + 4,
                           y: primary.frame.height - caret.maxY + (caret.height - side) / 2)
        }
        let mouse = NSEvent.mouseLocation
        return NSPoint(x: mouse.x + 12, y: mouse.y - 24)
    }

    private static func caretRect() -> CGRect? {
        // Electron apps such as VS Code expose their text only once asked to.
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid),
                                         "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                                            kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement

        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
                                            &range) == .success, let range else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         range, &bounds) == .success,
              let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect),
              rect.height > 0, rect.origin != .zero else { return nil }
        return rect
    }
}
