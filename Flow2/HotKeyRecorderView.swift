import AppKit
import Carbon
import SwiftUI

struct HotKeyRecorderView: NSViewRepresentable {
    @Binding var shortcut: HotKeyShortcut
    var isEnabled = true

    func makeNSView(context: Context) -> HotKeyRecorderButton {
        let button = HotKeyRecorderButton()
        button.onShortcut = { shortcut in
            self.shortcut = shortcut
        }
        button.update(shortcut: shortcut, isEnabled: isEnabled)
        return button
    }

    func updateNSView(_ button: HotKeyRecorderButton, context: Context) {
        button.onShortcut = { shortcut in
            self.shortcut = shortcut
        }
        button.update(shortcut: shortcut, isEnabled: isEnabled)
    }
}

@MainActor
final class HotKeyRecorderButton: NSButton {
    var onShortcut: ((HotKeyShortcut) -> Void)?

    private var shortcut = HotKeyShortcut.controlSpace
    private var isCapturing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        target = self
        action = #selector(beginCapture)
        toolTip = "Click, then press a key combination. Press Escape to cancel."
        setAccessibilityLabel("Record keyboard shortcut")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    func update(shortcut: HotKeyShortcut, isEnabled: Bool) {
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        if !isCapturing {
            title = shortcut.displayName
        }
    }

    @objc
    private func beginCapture() {
        guard isEnabled else { return }
        isCapturing = true
        title = "Press shortcut…"
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isCapturing else {
            super.keyDown(with: event)
            return
        }
        capture(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isCapturing else {
            return super.performKeyEquivalent(with: event)
        }
        capture(event)
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        guard isCapturing else {
            super.cancelOperation(sender)
            return
        }
        finishCapture()
    }

    private func capture(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            finishCapture()
            return
        }

        guard !Self.modifierKeyCodes.contains(event.keyCode) else {
            return
        }

        let modifiers = HotKeyModifiers(event.modifierFlags)
        guard !modifiers.isEmpty else {
            NSSound.beep()
            title = "Include a modifier"
            return
        }

        let capturedShortcut = HotKeyShortcut(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers,
            keyDisplay: Self.keyDisplay(for: event)
        )
        shortcut = capturedShortcut
        onShortcut?(capturedShortcut)
        finishCapture()
    }

    private func finishCapture() {
        isCapturing = false
        title = shortcut.displayName
        if window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
    }

    private static let modifierKeyCodes: Set<UInt16> = [
        UInt16(kVK_Command),
        UInt16(kVK_RightCommand),
        UInt16(kVK_Shift),
        UInt16(kVK_RightShift),
        UInt16(kVK_Option),
        UInt16(kVK_RightOption),
        UInt16(kVK_Control),
        UInt16(kVK_RightControl),
        UInt16(kVK_CapsLock),
        UInt16(kVK_Function)
    ]

    private static func keyDisplay(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space:
            return "Space"
        case kVK_Return:
            return "Return"
        case kVK_Tab:
            return "Tab"
        case kVK_Delete:
            return "Delete"
        case kVK_ForwardDelete:
            return "Forward Delete"
        case kVK_LeftArrow:
            return "←"
        case kVK_RightArrow:
            return "→"
        case kVK_UpArrow:
            return "↑"
        case kVK_DownArrow:
            return "↓"
        case kVK_Home:
            return "Home"
        case kVK_End:
            return "End"
        case kVK_PageUp:
            return "Page Up"
        case kVK_PageDown:
            return "Page Down"
        case kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5,
             kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
             kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
             kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20:
            return functionKeyDisplay(for: Int(event.keyCode))
        default:
            let characters = event.charactersIgnoringModifiers?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            return characters?.isEmpty == false ? characters! : "Key \(event.keyCode)"
        }
    }

    private static func functionKeyDisplay(for keyCode: Int) -> String {
        let functionKeys = [
            kVK_F1: "F1",
            kVK_F2: "F2",
            kVK_F3: "F3",
            kVK_F4: "F4",
            kVK_F5: "F5",
            kVK_F6: "F6",
            kVK_F7: "F7",
            kVK_F8: "F8",
            kVK_F9: "F9",
            kVK_F10: "F10",
            kVK_F11: "F11",
            kVK_F12: "F12",
            kVK_F13: "F13",
            kVK_F14: "F14",
            kVK_F15: "F15",
            kVK_F16: "F16",
            kVK_F17: "F17",
            kVK_F18: "F18",
            kVK_F19: "F19",
            kVK_F20: "F20"
        ]
        return functionKeys[keyCode] ?? "Key \(keyCode)"
    }
}

private extension HotKeyModifiers {
    init(_ modifierFlags: NSEvent.ModifierFlags) {
        var modifiers: HotKeyModifiers = []
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            modifiers.insert(.command)
        }
        if flags.contains(.option) {
            modifiers.insert(.option)
        }
        if flags.contains(.control) {
            modifiers.insert(.control)
        }
        if flags.contains(.shift) {
            modifiers.insert(.shift)
        }
        self = modifiers
    }
}
