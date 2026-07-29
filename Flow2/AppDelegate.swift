import AppKit
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKeyManagers: [GlobalHotKeyManager] = []
    private weak var viewModel: AppViewModel?
    private var configurationObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func installHotKeyIfNeeded(using viewModel: AppViewModel) {
        self.viewModel = viewModel
        installConfigurationObserverIfNeeded()
        updateHotKeyRegistration()
    }

    private func installConfigurationObserverIfNeeded() {
        guard configurationObserver == nil else { return }
        configurationObserver = NotificationCenter.default.addObserver(forName: .flow2ConfigurationDidChange,
                                                                       object: nil,
                                                                       queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateHotKeyRegistration()
            }
        }
    }

    private func updateHotKeyRegistration() {
        guard let viewModel else { return }

        hotKeyManagers = []

        let configuration = viewModel.configuration
        var requests: [(id: UInt32, shortcut: HotKeyShortcut, behavior: TranslationBehavior)] = [
            (1, configuration.hotKey, .followSettings)
        ]

        if configuration.enableNoTranslateHotKey, configuration.noTranslateHotKey != configuration.hotKey {
            requests.append((2, configuration.noTranslateHotKey, .keepOriginalLanguage))
        }

        var statusParts: [String] = []
        var didFail = false

        for request in requests {
            let manager = GlobalHotKeyManager(shortcut: request.shortcut, hotKeyID: request.id)
            manager.onHotKeyPressed = { [weak viewModel] in
                guard let viewModel else { return }
                Task { @MainActor in
                    await viewModel.startRecordingFromHotKey(translationBehavior: request.behavior)
                }
            }
            manager.onHotKeyReleased = { [weak viewModel] in
                guard let viewModel else { return }
                Task { @MainActor in
                    await viewModel.stopRecordingFromHotKey()
                }
            }

            do {
                try manager.register()
                hotKeyManagers.append(manager)
                statusParts.append("\(request.shortcut.displayName) (\(request.behavior.shortDescription))")
            } catch {
                didFail = true
                statusParts.append("\(request.shortcut.displayName) failed: \(error.localizedDescription)")
            }
        }

        viewModel.updateHotKeyStatus(statusParts.joined(separator: " · "), didFail: didFail)
    }
}

enum GlobalHotKeyError: LocalizedError {
    case eventHandlerInstallFailed(OSStatus)
    case registrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .eventHandlerInstallFailed(let status):
            return "Could not install hotkey event handler (\(status))."
        case .registrationFailed(let status):
            return "Could not register global hotkey (\(status))."
        }
    }
}

final class GlobalHotKeyManager {
    var onHotKeyPressed: (() -> Void)?
    var onHotKeyReleased: (() -> Void)?

    private let shortcut: HotKeyShortcut
    private let hotKeyID: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var isPressed = false

    init(shortcut: HotKeyShortcut, hotKeyID: UInt32) {
        self.shortcut = shortcut
        self.hotKeyID = hotKeyID
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    func register() throws {
        guard hotKeyRef == nil else { return }

        var eventSpecs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

        // Every manager installs its own handler on the shared application target, and Carbon stops
        // walking the handler chain as soon as one returns noErr. Events for other hotkey IDs must
        // report eventNotHandledErr, otherwise the last installed handler swallows them all.
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            return manager.handleHotKeyEvent(event) ? noErr : OSStatus(eventNotHandledErr)
        }, eventSpecs.count, &eventSpecs, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()), &eventHandler)

        guard installStatus == noErr else {
            throw GlobalHotKeyError.eventHandlerInstallFailed(installStatus)
        }

        let eventHotKeyID = EventHotKeyID(signature: OSType(0x464C4F57), id: hotKeyID)
        let registerStatus = RegisterEventHotKey(shortcut.keyCode,
                                                 UInt32(carbonModifiers(for: shortcut.modifiers)),
                                                 eventHotKeyID,
                                                 GetApplicationEventTarget(),
                                                 0,
                                                 &hotKeyRef)

        guard registerStatus == noErr else {
            throw GlobalHotKeyError.registrationFailed(registerStatus)
        }
    }

    /// Returns whether this manager owns the event, so the caller can pass unclaimed events along
    /// the Carbon handler chain to the manager that does own them.
    private func handleHotKeyEvent(_ event: EventRef?) -> Bool {
        guard let event else { return false }

        var receivedHotKeyID = EventHotKeyID()
        let status = GetEventParameter(event,
                                       EventParamName(kEventParamDirectObject),
                                       EventParamType(typeEventHotKeyID),
                                       nil,
                                       MemoryLayout<EventHotKeyID>.size,
                                       nil,
                                       &receivedHotKeyID)

        guard status == noErr, receivedHotKeyID.id == hotKeyID else { return false }

        let kind = GetEventKind(event)
        switch kind {
        case UInt32(kEventHotKeyPressed):
            guard !isPressed else { return true }
            isPressed = true
            onHotKeyPressed?()
            return true
        case UInt32(kEventHotKeyReleased):
            guard isPressed else { return true }
            isPressed = false
            onHotKeyReleased?()
            return true
        default:
            return false
        }
    }

    private func carbonModifiers(for modifiers: HotKeyModifiers) -> Int {
        var result = 0
        if modifiers.contains(.command) {
            result |= cmdKey
        }
        if modifiers.contains(.option) {
            result |= optionKey
        }
        if modifiers.contains(.control) {
            result |= controlKey
        }
        if modifiers.contains(.shift) {
            result |= shiftKey
        }
        return result
    }
}
