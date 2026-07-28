import AppKit
import Carbon
import SwiftUI

struct HotKeyRecorderField: NSViewRepresentable {
    let display: String
    let onRecord: (UInt32, UInt32, String) -> Void

    func makeNSView(context: Context) -> HotKeyRecorderNSView {
        let view = HotKeyRecorderNSView()
        view.display = display
        view.onRecord = onRecord
        return view
    }

    func updateNSView(_ nsView: HotKeyRecorderNSView, context: Context) {
        nsView.display = display
        nsView.onRecord = onRecord
        nsView.needsDisplay = true
    }
}

@MainActor
final class HotKeyRecorderNSView: NSView {
    var display = "⌘⇧V"
    var onRecord: ((UInt32, UInt32, String) -> Void)?
    private var isRecording = false

    override var acceptsFirstResponder: Bool { true }
    override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            isRecording = false
            window?.makeFirstResponder(nil)
            needsDisplay = true
            return
        }

        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.isEmpty else {
            NSSound.beep()
            return
        }

        var carbonModifiers: UInt32 = 0
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }

        let value = Self.displayString(event: event, flags: flags)
        display = value
        isRecording = false
        onRecord?(UInt32(event.keyCode), carbonModifiers, value)
        window?.makeFirstResponder(nil)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        (isRecording ? NSColor.labelColor : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.labelColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()

        let text = isRecording ? String(localized: "hotkey.recording") : display
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: isRecording ? NSColor.windowBackgroundColor : NSColor.labelColor
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let rect = NSRect(
            x: (self.bounds.width - size.width) / 2,
            y: (self.bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { String(localized: "hotkey.accessibility") }
    override func accessibilityValue() -> Any? { display }

    private static func displayString(event: NSEvent, flags: NSEvent.ModifierFlags) -> String {
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }

        let key: String
        switch Int(event.keyCode) {
        case kVK_Return: key = "↩"
        case kVK_Tab: key = "⇥"
        case kVK_Space: key = "SPACE"
        case kVK_Delete: key = "⌫"
        case kVK_LeftArrow: key = "←"
        case kVK_RightArrow: key = "→"
        case kVK_DownArrow: key = "↓"
        case kVK_UpArrow: key = "↑"
        case kVK_F1: key = "F1"
        case kVK_F2: key = "F2"
        case kVK_F3: key = "F3"
        case kVK_F4: key = "F4"
        case kVK_F5: key = "F5"
        case kVK_F6: key = "F6"
        case kVK_F7: key = "F7"
        case kVK_F8: key = "F8"
        case kVK_F9: key = "F9"
        case kVK_F10: key = "F10"
        case kVK_F11: key = "F11"
        case kVK_F12: key = "F12"
        default:
            key = event.charactersIgnoringModifiers?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased() ?? "?"
        }
        return result + (key.isEmpty ? "?" : key)
    }
}
