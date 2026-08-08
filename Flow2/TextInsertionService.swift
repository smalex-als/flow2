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

/// Everything the general pasteboard held before Flow2 overwrote it, so the user's own clipboard
/// can be put back after the synthetic paste.
struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    var isEmpty: Bool { items.isEmpty }

    init(of pasteboard: NSPasteboard) {
        // Promised and lazily provided types return nil data and are dropped: they cannot be
        // reconstructed without the originating app, and a partial restore beats none.
        items = (pasteboard.pasteboardItems ?? [])
            .map { item in
                item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { contents, type in
                    contents[type] = item.data(forType: type)
                }
            }
            .filter { !$0.isEmpty }
    }

    func write(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !isEmpty else { return }

        pasteboard.writeObjects(items.map { contents in
            let item = NSPasteboardItem()
            for (type, data) in contents {
                item.setData(data, forType: type)
            }
            return item
        })
    }
}

@MainActor
final class TextInsertionService {
    /// How long the transcript stays on the pasteboard after Cmd+V is posted.
    private static let pasteSettleDelay = Duration.milliseconds(250)

    /// `keyboardSetUnicodeString` carries up to 20 UTF-16 units per event, so the terminal path
    /// sends the transcript in chunks instead of one event per character.
    nonisolated static let typingChunkLength = 20

    /// Paced so a terminal reading the events keeps up, and stated per chunk rather than per
    /// character: the same delay used to be paid ~20 times as often for the same text.
    private static let typingChunkDelay = Duration.milliseconds(4)

    /// Modifier and key events need to arrive as distinct steps for the target app to see a
    /// chord rather than a burst.
    private static let pasteKeyEventDelay = Duration.milliseconds(12)

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
            setSelectedRange(NSRange(location: newLocation, length: 0), in: element)
            return "Direct AX insertion succeeded: app=\(app), role=\(role), subrole=\(subrole), path=value, textLength=\(text.count)"
        }
        throw TextInsertionError.directInsertionFailed("selected-text set status=\(selectedTextStatus.rawValue), role=\(role), subrole=\(subrole)")
    }

    /// Where the text would go, in screen coordinates, so a panel can be put next to it.
    ///
    /// Read before anything is inserted and while the target app still has focus, which is the only
    /// moment the caret is knowable. Falls back to the bounds of the focused control, and then to
    /// nothing at all — plenty of apps answer neither.
    func caretScreenRect(for targetApp: NSRunningApplication?) -> CGRect? {
        guard AXIsProcessTrusted(), let element = try? focusedElement(for: targetApp) else { return nil }

        if let caret = selectedRange(in: element) {
            var range = CFRange(location: caret.location, length: 0)
            if let rangeValue = AXValueCreate(.cfRange, &range) {
                var result: CFTypeRef?
                let status = AXUIElementCopyParameterizedAttributeValue(
                    element,
                    kAXBoundsForRangeParameterizedAttribute as CFString,
                    rangeValue,
                    &result
                )
                if status == .success, let result, CFGetTypeID(result) == AXValueGetTypeID() {
                    let axValue = unsafeDowncast(result, to: AXValue.self)
                    var rect = CGRect.zero
                    if AXValueGetType(axValue) == .cgRect, AXValueGetValue(axValue, .cgRect, &rect), rect.width >= 0, rect.height > 0 {
                        return rect
                    }
                }
            }
        }

        guard let origin = copyAXValue(kAXPositionAttribute as CFString, from: element, type: .cgPoint, as: CGPoint.self),
              let size = copyAXValue(kAXSizeAttribute as CFString, from: element, type: .cgSize, as: CGSize.self),
              size.height > 0 else {
            return nil
        }

        return CGRect(origin: origin, size: size)
    }

    private func copyAXValue<T>(_ attribute: CFString, from element: AXUIElement, type: AXValueType, as: T.Type) -> T? {
        var object: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &object) == .success,
              let object, CFGetTypeID(object) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeDowncast(object, to: AXValue.self)
        guard AXValueGetType(axValue) == type else { return nil }

        var result = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { result.deallocate() }
        guard AXValueGetValue(axValue, type, result) else { return nil }
        return result.pointee
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

    private func setSelectedRange(_ nsRange: NSRange, in element: AXUIElement) {
        var range = CFRange(location: nsRange.location, length: nsRange.length)
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

        // The keystrokes are built before the pasteboard is touched, so no failure can leave the
        // transcript sitting on the user's clipboard in place of what they had copied.
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

        let snapshot = PasteboardSnapshot(of: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ownedChangeCount = pasteboard.changeCount

        // Give the pasteboard server time to propagate before the target app reads it.
        try? await Task.sleep(for: .milliseconds(40))

        await postPasteShortcut(commandDown: commandDown, vDown: vDown, vUp: vUp, commandUp: commandUp, tap: .cghidEventTap)

        // The target app reads the pasteboard while handling the synthetic Cmd+V, so the previous
        // contents can only go back once that read has had a chance to happen.
        try? await Task.sleep(for: Self.pasteSettleDelay)
        let restoration = restorePasteboard(snapshot, to: pasteboard, ifChangeCountIs: ownedChangeCount)

        return "Paste path executed: app=\(frontmostAppName), pasteboard set to transcript, Cmd+V posted via hID tap, settleDelay=\(Self.pasteSettleDelay), \(restoration)"
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

        let chunks = Self.typingChunks(of: text)
        for chunk in chunks {
            var units = chunk
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw TextInsertionError.keyEventUnavailable
            }

            keyDown.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            keyUp.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            try? await Task.sleep(for: Self.typingChunkDelay, tolerance: .milliseconds(1))
        }

        try? await Task.sleep(for: .milliseconds(80))
        return "Terminal typing path executed: app=\(frontmostAppName), unicode keystrokes posted, textLength=\(text.count), events=\(chunks.count)"
    }

    /// Splits the transcript into the UTF-16 runs a single key event can carry.
    ///
    /// UTF-16 is what `keyboardSetUnicodeString` takes, and it is also the only unit that can
    /// represent the whole transcript: a Unicode scalar above U+FFFF — an emoji, a CJK extension —
    /// does not fit the `UniChar` the API expects, and forcing one in traps. A surrogate pair is
    /// therefore kept whole rather than split across two events, which would deliver two
    /// meaningless halves instead of the character.
    nonisolated static func typingChunks(of text: String, maximumLength: Int = typingChunkLength) -> [[UInt16]] {
        let units = Array(text.utf16)
        var chunks: [[UInt16]] = []
        var index = 0

        while index < units.count {
            var end = min(index + maximumLength, units.count)
            let isHighSurrogate = (0xD800 ... 0xDBFF).contains(units[end - 1])
            if end < units.count, isHighSurrogate, end - 1 > index {
                end -= 1
            }

            chunks.append(Array(units[index ..< end]))
            index = end
        }

        return chunks
    }

    /// Restores the snapshot only while Flow2 still owns the pasteboard: a bumped change count means
    /// the user or another app copied something after the transcript, and that must win.
    private func restorePasteboard(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard, ifChangeCountIs ownedChangeCount: Int) -> String {
        guard pasteboard.changeCount == ownedChangeCount else {
            return "pasteboard left as-is (changed by another app during paste)"
        }

        guard !snapshot.isEmpty else {
            return "pasteboard cleared (nothing to restore)"
        }

        snapshot.write(to: pasteboard)
        return "previous pasteboard contents restored"
    }

    /// Cancellation cuts the waits short but never abandons the remaining events: stopping midway
    /// would leave Command posted as down with nothing to release it, and the modifier would stick
    /// for every keystroke the user typed afterwards.
    private func postPasteShortcut(commandDown: CGEvent, vDown: CGEvent, vUp: CGEvent, commandUp: CGEvent, tap: CGEventTapLocation) async {
        commandDown.post(tap: tap)
        await pauseBetweenPasteKeyEvents()
        vDown.post(tap: tap)
        await pauseBetweenPasteKeyEvents()
        vUp.post(tap: tap)
        await pauseBetweenPasteKeyEvents()
        commandUp.post(tap: tap)
    }

    private func pauseBetweenPasteKeyEvents() async {
        try? await Task.sleep(for: Self.pasteKeyEventDelay, tolerance: .milliseconds(1))
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
