import AppKit
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKeyManager: GlobalHotKeyManager?
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

        hotKeyManager = nil

        let manager = GlobalHotKeyManager(preset: viewModel.configuration.hotKeyPreset)
        manager.onHotKeyPressed = { [weak viewModel] in
            guard let viewModel else { return }
            Task { @MainActor in
                await viewModel.startRecordingFromHotKey()
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
            viewModel.updateHotKeyStatus("Hotkey ready: \(viewModel.configuration.hotKeyPreset.displayName)")
            hotKeyManager = manager
        } catch {
            viewModel.updateHotKeyStatus("Hotkey registration failed: \(error.localizedDescription)")
        }
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
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var isPressed = false

    init(preset: HotKeyPreset) {
        self.preset = preset
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

        let hotKeyID = EventHotKeyID(signature: OSType(0x464C4F57), id: UInt32(1))
        let registerStatus = RegisterEventHotKey(UInt32(kVK_Space),
                                                 UInt32(carbonModifiers(for: preset)),
                                                 hotKeyID,
                                                 GetApplicationEventTarget(),
                                                 0,
                                                 &hotKeyRef)

        guard registerStatus == noErr else {
            throw GlobalHotKeyError.registrationFailed(registerStatus)
        }
    }

    private func handleHotKeyEvent(_ event: EventRef?) {
        guard let event else { return }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(event,
                                       EventParamName(kEventParamDirectObject),
                                       EventParamType(typeEventHotKeyID),
                                       nil,
                                       MemoryLayout<EventHotKeyID>.size,
                                       nil,
                                       &hotKeyID)

        guard status == noErr, hotKeyID.id == 1 else { return }

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
