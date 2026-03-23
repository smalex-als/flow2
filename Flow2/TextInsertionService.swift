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
            return try insertDirectly(trimmed)
        } catch {
            let fallback = try await paste(trimmed)
            return "Direct insertion failed (\(error.localizedDescription)); \(fallback)"
        }
    }

    private func insertDirectly(_ text: String) throws -> String {
        guard AXIsProcessTrusted() else {
            throw TextInsertionError.accessibilityUnavailable
        }

        let system = AXUIElementCreateSystemWide()
        var focusedObject: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedObject)
        guard focusedStatus == .success, let focusedObject else {
            throw TextInsertionError.focusedElementUnavailable
        }

        let element = unsafeDowncast(focusedObject, to: AXUIElement.self)
        let role = copyStringAttribute(kAXRoleAttribute as CFString, from: element) ?? "unknown"
        let subrole = copyStringAttribute(kAXSubroleAttribute as CFString, from: element) ?? "none"
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"

        let selectedTextStatus = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        if selectedTextStatus == .success {
            return "Direct AX insertion succeeded: app=\(app), role=\(role), subrole=\(subrole), path=selectedText, textLength=\(text.count)"
        }

        if shouldUseValueReplacement(role: role),
           var currentValue = copyStringAttribute(kAXValueAttribute as CFString, from: element) {
            let nsRange = try selectedRange(in: element)
            guard let swiftRange = Range(nsRange, in: currentValue) else {
                throw TextInsertionError.directInsertionFailed("invalid selected range for value replacement, role=\(role), subrole=\(subrole)")
            }

            currentValue.replaceSubrange(swiftRange, with: text)
            let setStatus = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, currentValue as CFTypeRef)
            guard setStatus == .success else {
                throw TextInsertionError.directInsertionFailed("set value status=\(setStatus.rawValue), role=\(role), subrole=\(subrole)")
            }

            let newLocation = nsRange.location + text.utf16.count
            setSelectedRange(location: newLocation, in: element)
            return "Direct AX insertion succeeded: app=\(app), role=\(role), subrole=\(subrole), path=value, textLength=\(text.count)"
        }
        throw TextInsertionError.directInsertionFailed("selected-text set status=\(selectedTextStatus.rawValue), role=\(role), subrole=\(subrole)")
    }

    private func selectedRange(in element: AXUIElement) throws -> NSRange {
        var rangeObject: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeObject)
        guard status == .success, let rangeObject, CFGetTypeID(rangeObject) == AXValueGetTypeID() else {
            return NSRange(location: 0, length: 0)
        }

        let axValue = unsafeDowncast(rangeObject, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else {
            return NSRange(location: 0, length: 0)
        }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return NSRange(location: 0, length: 0)
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

    private func shouldUseValueReplacement(role: String) -> Bool {
        role == kAXTextFieldRole as String || role == "AXSearchField" || role == kAXComboBoxRole as String
    }

    private func paste(_ text: String) async throws -> String {
        let pasteboard = NSPasteboard.general
        let frontmostAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

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

        vDown.flags = CGEventFlags.maskCommand
        vUp.flags = CGEventFlags.maskCommand

        try postPasteShortcut(commandDown: commandDown, vDown: vDown, vUp: vUp, commandUp: commandUp, tap: .cghidEventTap)

        try? await Task.sleep(for: .seconds(2))

        return "Paste path executed: app=\(frontmostAppName), pasteboard set to transcript, Cmd+V posted via hID tap, pasteboard retained"
    }

    private func typeText(_ text: String, targetApp: NSRunningApplication?) async throws -> String {
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

    private func activateTargetAppIfNeeded(_ targetApp: NSRunningApplication?) async {
        guard let targetApp else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != targetApp.processIdentifier else { return }

        targetApp.activate(options: [.activateIgnoringOtherApps])
        try? await Task.sleep(for: .milliseconds(180))
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
