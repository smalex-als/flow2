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
        var requests: [(id: UInt32, preset: HotKeyPreset, behavior: TranslationBehavior)] = [
            (1, configuration.hotKeyPreset, .followSettings)
        ]

        if configuration.enableNoTranslateHotKey, configuration.noTranslateHotKeyPreset != configuration.hotKeyPreset {
            requests.append((2, configuration.noTranslateHotKeyPreset, .keepOriginalLanguage))
        }

        var statusParts: [String] = []

        for request in requests {
            let manager = GlobalHotKeyManager(preset: request.preset, hotKeyID: request.id)
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
                statusParts.append("\(request.preset.displayName) (\(request.behavior.shortDescription))")
            } catch {
                statusParts.append("\(request.preset.displayName) failed: \(error.localizedDescription)")
            }
        }

        viewModel.updateHotKeyStatus(statusParts.joined(separator: " · "))
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

    private let preset: HotKeyPreset
    private let hotKeyID: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var isPressed = false

    init(preset: HotKeyPreset, hotKeyID: UInt32) {
        self.preset = preset
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

        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            manager.handleHotKeyEvent(event)
            return noErr
        }, eventSpecs.count, &eventSpecs, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()), &eventHandler)

        guard installStatus == noErr else {
            throw GlobalHotKeyError.eventHandlerInstallFailed(installStatus)
        }

        let eventHotKeyID = EventHotKeyID(signature: OSType(0x464C4F57), id: hotKeyID)
        let registerStatus = RegisterEventHotKey(UInt32(kVK_Space),
                                                 UInt32(carbonModifiers(for: preset)),
                                                 eventHotKeyID,
                                                 GetApplicationEventTarget(),
                                                 0,
                                                 &hotKeyRef)

        guard registerStatus == noErr else {
            throw GlobalHotKeyError.registrationFailed(registerStatus)
        }
    }

    private func handleHotKeyEvent(_ event: EventRef?) {
        guard let event else { return }

        var receivedHotKeyID = EventHotKeyID()
        let status = GetEventParameter(event,
                                       EventParamName(kEventParamDirectObject),
                                       EventParamType(typeEventHotKeyID),
                                       nil,
                                       MemoryLayout<EventHotKeyID>.size,
                                       nil,
                                       &receivedHotKeyID)

        guard status == noErr, receivedHotKeyID.id == hotKeyID else { return }

        let kind = GetEventKind(event)
        switch kind {
        case UInt32(kEventHotKeyPressed):
            guard !isPressed else { return }
            isPressed = true
            onHotKeyPressed?()
        case UInt32(kEventHotKeyReleased):
            guard isPressed else { return }
            isPressed = false
            onHotKeyReleased?()
        default:
            break
        }
    }

    private func carbonModifiers(for preset: HotKeyPreset) -> Int {
        switch preset {
        case .controlSpace:
            return controlKey
        case .shiftCommandSpace:
            return cmdKey | shiftKey
        case .optionCommandSpace:
            return cmdKey | optionKey
        }
    }
}
