import AppKit

@MainActor
final class ApplicationInstaller {
    private static let suppressionKey = "dismissApplicationsInstallPrompt"

    static func offerIfNeeded() {
        let source = Bundle.main.bundleURL
        let environment = ProcessInfo.processInfo.environment
        guard source.pathExtension == "app",
              !UserDefaults.standard.bool(forKey: suppressionKey),
              environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil,
              environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1",
              environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] == nil,
              shouldOffer(for: source, home: FileManager.default.homeDirectoryForCurrentUser) else { return }

        let alert = NSAlert()
        alert.messageText = "Install Flow2 in Applications?"
        alert.informativeText = "A permanent location helps with launch at login and macOS permissions. Flow2 will copy itself to Applications and relaunch. The original copy will be kept."
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Don't Ask Again")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            install(from: source)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(true, forKey: suppressionKey)
        default:
            break
        }
    }

    static func shouldOffer(for source: URL, home: URL) -> Bool {
        let path = source.resolvingSymlinksInPath().standardizedFileURL.path
        let applications = ["/Applications", home.appendingPathComponent("Applications").path]
        guard !applications.contains(where: { path.hasPrefix($0 + "/") }) else { return false }
        let components = source.pathComponents.map { $0.lowercased() }
        return !components.contains(where: { $0 == ".deriveddata" || $0 == "deriveddata" })
            && !path.contains("/Build/Products/")
    }

    private static func install(from source: URL) {
        let files = FileManager.default
        let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let directory = files.isWritableFile(atPath: systemApplications.path)
            ? systemApplications
            : files.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        let destination = directory.appendingPathComponent("Flow2.app", isDirectory: true)

        guard !NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleURL?.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath()
        }) else {
            showError("Quit the copy of Flow2 in Applications, then relaunch this copy to try again.")
            return
        }

        if files.fileExists(atPath: destination.path) {
            guard Bundle(url: destination)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                showError("The destination already contains a different application. Nothing was replaced.")
                return
            }
            let alert = NSAlert()
            alert.messageText = "Replace the installed Flow2?"
            alert.informativeText = "Replace \(destination.path) with this copy? Your settings and history will be kept."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Replace and Relaunch")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }

        let staging = directory.appendingPathComponent(".Flow2-install-\(UUID().uuidString).app")
        let backup = directory.appendingPathComponent(".Flow2-backup-\(UUID().uuidString).app")
        var backedUp = false
        var installed = false
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            try files.copyItem(at: source, to: staging)
            if files.fileExists(atPath: destination.path) {
                try files.moveItem(at: destination, to: backup)
                backedUp = true
            }
            try files.moveItem(at: staging, to: destination)
            installed = true
        } catch {
            let recovery = restoreInstallation(at: destination, backup: backedUp ? backup : nil, installed: installed)
            try? files.removeItem(at: staging)
            showError(error.localizedDescription + recovery)
            return
        }

        let hasBackup = backedUp
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { app, error in
            Task { @MainActor in
                guard app != nil, error == nil else {
                    // Keep the original process and the previous installation usable on failure.
                    let recovery = restoreInstallation(at: destination, backup: hasBackup ? backup : nil, installed: true)
                    showError((error?.localizedDescription ?? "The installed copy could not be launched.") + recovery)
                    return
                }
                if hasBackup { try? FileManager.default.removeItem(at: backup) }
                NSApp.terminate(nil)
            }
        }
    }

    private static func restoreInstallation(at destination: URL, backup: URL?, installed: Bool) -> String {
        do {
            if installed { try FileManager.default.removeItem(at: destination) }
            if let backup { try FileManager.default.moveItem(at: backup, to: destination) }
            return ""
        } catch {
            let backupNote = backup.map { " The previous installation is kept at \($0.path)." } ?? ""
            return "\n\nCould not restore the destination: \(error.localizedDescription)." + backupNote
        }
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not install Flow2"
        alert.informativeText = message
        alert.runModal()
    }
}
