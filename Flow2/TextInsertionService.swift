import AppKit
import ApplicationServices
import Carbon
import Foundation

enum TextInsertionError: LocalizedError {
    case emptyTranscript
    case accessibilityUnavailable
    case focusedElementUnavailable
    case directInsertionFailed(String)
    case eventSourceUnavailable
    case keyEventUnavailable
    case secureInputEnabled

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return "Transcript is empty."
        case .accessibilityUnavailable:
            return "Accessibility permission is unavailable."
        case .focusedElementUnavailable:
            return "Could not resolve the focused UI element."
        case .directInsertionFailed(let details):
            return "Direct insertion failed: \(details)"
        case .eventSourceUnavailable:
            return "Could not create a keyboard event source."
        case .keyEventUnavailable:
            return "Could not create keyboard events for paste."
        case .secureInputEnabled:
            return "Secure input is enabled, so macOS blocks synthetic keystrokes. Close any focused password field and try again."
        }
    }
}

@MainActor
final class TextInsertionService {
    func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func insert(_ text: String, targetApp: NSRunningApplication?) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TextInsertionError.emptyTranscript
        }

        await activateTargetAppIfNeeded(targetApp)

        if isTerminalApp(targetApp) {
            return try await typeText(trimmed, targetApp: targetApp)
        }

        if shouldPreferPasteInsertion(targetApp) {
            return try await paste(trimmed)
        }

        do {
            return try insertDirectly(trimmed, targetApp: targetApp)
        } catch {
            let fallback = try await paste(trimmed)
            return "Direct insertion failed (\(error.localizedDescription)); \(fallback)"
        }
    }

    private func insertDirectly(_ text: String, targetApp: NSRunningApplication?) throws -> String {
        guard AXIsProcessTrusted() else {
            throw TextInsertionError.accessibilityUnavailable
        }

        let element = try focusedElement(for: targetApp)
        let role = copyStringAttribute(kAXRoleAttribute as CFString, from: element) ?? "unknown"
        let subrole = copyStringAttribute(kAXSubroleAttribute as CFString, from: element) ?? "none"
        let app = targetApp?.localizedName ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"

        let before = snapshot(of: element)
        let selectedTextStatus = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        if selectedTextStatus == .success {
            switch verifyInsertion(of: text, in: element, before: before) {
            case .confirmed:
                return "Direct AX insertion succeeded: app=\(app), role=\(role), subrole=\(subrole), path=selectedText, textLength=\(text.count)"
            case .unverifiable:
                return "Direct AX insertion succeeded (unverified): app=\(app), role=\(role), subrole=\(subrole), path=selectedText, textLength=\(text.count)"
            case .rejected:
                throw TextInsertionError.directInsertionFailed("selected-text write reported success but the element did not change, role=\(role), subrole=\(subrole)")
            }
        }

        if shouldUseValueReplacement(role: role),
           var currentValue = copyStringAttribute(kAXValueAttribute as CFString, from: element) {
            guard let nsRange = selectedRange(in: element) else {
                throw TextInsertionError.directInsertionFailed("selected range unavailable for value replacement, role=\(role), subrole=\(subrole)")
            }
            guard let swiftRange = Range(nsRange, in: currentValue) else {
                throw TextInsertionError.directInsertionFailed("invalid selected range for value replacement, role=\(role), subrole=\(subrole)")
            }

            currentValue.replaceSubrange(swiftRange, with: text)
            let setStatus = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, currentValue as CFTypeRef)
            guard setStatus == .success else {
                throw TextInsertionError.directInsertionFailed("set value status=\(setStatus.rawValue), role=\(role), subrole=\(subrole)")
            }
            guard copyStringAttribute(kAXValueAttribute as CFString, from: element) == currentValue else {
                throw TextInsertionError.directInsertionFailed("value write reported success but the element did not change, role=\(role), subrole=\(subrole)")
            }

            let newLocation = nsRange.location + text.utf16.count
            setSelectedRange(location: newLocation, in: element)
            return "Direct AX insertion succeeded: app=\(app), role=\(role), subrole=\(subrole), path=value, textLength=\(text.count)"
        }
        throw TextInsertionError.directInsertionFailed("selected-text set status=\(selectedTextStatus.rawValue), role=\(role), subrole=\(subrole)")
    }

    /// Focus resolved through the target process rather than the system-wide element, because
    /// transcription runs for a few seconds and the frontmost app may have changed meanwhile.
    private func focusedElement(for targetApp: NSRunningApplication?) throws -> AXUIElement {
        if let processIdentifier = targetApp?.processIdentifier {
            let appElement = AXUIElementCreateApplication(processIdentifier)
            if let focused = copyElementAttribute(kAXFocusedUIElementAttribute as CFString, from: appElement) {
                return focused
            }
        }

        guard let focused = copyElementAttribute(kAXFocusedUIElementAttribute as CFString,
                                                 from: AXUIElementCreateSystemWide()) else {
            throw TextInsertionError.focusedElementUnavailable
        }

        return focused
    }

    private enum InsertionVerification {
        case confirmed
        case rejected
        case unverifiable
    }

    private struct ElementTextSnapshot {
        let value: String?
        let selectionLocation: Int?
    }

    private func snapshot(of element: AXUIElement) -> ElementTextSnapshot {
        ElementTextSnapshot(
            value: copyStringAttribute(kAXValueAttribute as CFString, from: element),
            selectionLocation: selectedRange(in: element)?.location
        )
    }

    /// A successful `AXError` only means the accessibility server accepted the write. Elements that
    /// expose a container instead of the real text control, and rich-text views with a no-op setter,
    /// report success and drop the text, so the write is confirmed against the element's own state.
    private func verifyInsertion(of text: String, in element: AXUIElement, before: ElementTextSnapshot) -> InsertionVerification {
        let after = snapshot(of: element)

        if let beforeValue = before.value, let afterValue = after.value {
            return beforeValue == afterValue ? .rejected : .confirmed
        }

        if let beforeLocation = before.selectionLocation, let afterLocation = after.selectionLocation {
            return afterLocation == beforeLocation + text.utf16.count ? .confirmed : .rejected
        }

        return .unverifiable
    }

    private func selectedRange(in element: AXUIElement) -> NSRange? {
        var rangeObject: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeObject)
        guard status == .success, let rangeObject, CFGetTypeID(rangeObject) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeDowncast(rangeObject, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }

        return NSRange(location: range.location, length: range.length)
    }

    private func setSelectedRange(location: Int, in element: AXUIElement) {
        var range = CFRange(location: location, length: 0)
        guard let value = AXValueCreate(.cfRange, &range) else { return }
        _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
    }

    private func copyStringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var object: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &object)
        guard status == .success else { return nil }
        return object as? String
    }

    private func copyElementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        var object: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &object)
        guard status == .success, let object, CFGetTypeID(object) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(object, to: AXUIElement.self)
    }

    private func shouldUseValueReplacement(role: String) -> Bool {
        role == kAXTextFieldRole as String || role == "AXSearchField" || role == kAXComboBoxRole as String
    }

    private func paste(_ text: String) async throws -> String {
        guard !IsSecureEventInputEnabled() else {
            throw TextInsertionError.secureInputEnabled
        }

        let pasteboard = NSPasteboard.general
        let frontmostAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Give the pasteboard server time to propagate before the target app reads it.
        try? await Task.sleep(for: .milliseconds(40))

        let eventSourceState = CGEventSourceStateID.combinedSessionState
        guard let source = CGEventSource(stateID: eventSourceState) else {
            throw TextInsertionError.eventSourceUnavailable
        }

        guard let commandDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: false) else {
            throw TextInsertionError.keyEventUnavailable
        }

        commandDown.flags = CGEventFlags.maskCommand
        vDown.flags = CGEventFlags.maskCommand
        vUp.flags = CGEventFlags.maskCommand

        try postPasteShortcut(commandDown: commandDown, vDown: vDown, vUp: vUp, commandUp: commandUp, tap: .cghidEventTap)

        try? await Task.sleep(for: .seconds(2))

        return "Paste path executed: app=\(frontmostAppName), pasteboard set to transcript, Cmd+V posted via hID tap, pasteboard retained"
    }

    private func typeText(_ text: String, targetApp: NSRunningApplication?) async throws -> String {
        guard !IsSecureEventInputEnabled() else {
            throw TextInsertionError.secureInputEnabled
        }

        let frontmostAppName = targetApp?.localizedName ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        let eventSourceState = CGEventSourceStateID.combinedSessionState
        guard let source = CGEventSource(stateID: eventSourceState) else {
            throw TextInsertionError.eventSourceUnavailable
        }

        for scalar in text.unicodeScalars {
            var value = UInt16(scalar.value)
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw TextInsertionError.keyEventUnavailable
            }

            keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
            keyUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            usleep(2500)
        }

        try? await Task.sleep(for: .milliseconds(80))
        return "Terminal typing path executed: app=\(frontmostAppName), unicode keystrokes posted, textLength=\(text.count)"
    }

    private func postPasteShortcut(commandDown: CGEvent, vDown: CGEvent, vUp: CGEvent, commandUp: CGEvent, tap: CGEventTapLocation) throws {
        commandDown.post(tap: tap)
        usleep(12000)
        vDown.post(tap: tap)
        usleep(12000)
        vUp.post(tap: tap)
        usleep(12000)
        commandUp.post(tap: tap)
    }

    /// `activate` is asynchronous, so the activation is polled instead of assumed after a fixed wait.
    private func activateTargetAppIfNeeded(_ targetApp: NSRunningApplication?) async {
        guard let targetApp, !targetApp.isActive else { return }

        targetApp.activate()

        for _ in 0 ..< 24 {
            try? await Task.sleep(for: .milliseconds(25))
            if targetApp.isActive { return }
        }
    }

    private func isTerminalApp(_ targetApp: NSRunningApplication?) -> Bool {
        guard let bundleIdentifier = targetApp?.bundleIdentifier else { return false }
        return bundleIdentifier == "com.apple.Terminal" || bundleIdentifier == "com.googlecode.iterm2"
    }

    private func shouldPreferPasteInsertion(_ targetApp: NSRunningApplication?) -> Bool {
        guard let bundleIdentifier = targetApp?.bundleIdentifier else { return false }
        return bundleIdentifier == "com.google.Chrome" || bundleIdentifier == "md.obsidian"
    }
}
