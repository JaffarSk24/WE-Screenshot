import AppKit
import ServiceManagement
@_spi(Harness) import WEActions
import WEAnnotate
import WECapture
import WECloud
import WEOverlay
import WECore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let captureTestFlag = "--capture-test"
    private static let overlayTestFlag = "--overlay-test"
    private static let uploadPanelTestFlag = "--upload-panel-test"

    // The services are created at launch, not in property initialisers, so the
    // command line modes (--version, --capture-test) never build any of them.
    private var settings = SettingsStore.shared
    private var notifier: Notifier!
    private var cloud: CloudCoordinator!
    private var actions: ScreenshotActions!
    private var updater: Updater!
    private var overlay: OverlayController!
    private let capture = ScreenCaptureService()
    private let hotKeys = HotKeyCenter()
    private var settingsWindow: SettingsWindowController?
    private var statusItem: NSStatusItem!

    private var skipNormalLaunch = false
    private var captureTestPrefix: String?
    private var overlayTestPrefix: String?
    private var uploadPanelTestPrefix: String?
    private var isPreparingCapture = false
    /// Set while one of the shell's own alerts runs, so repeated presses of the
    /// hotkey cannot stack alerts.
    private var isShowingAlert = false
    private var didRequestPermission = false

    /// The wanted shortcut is not registered; always the result of the last attempt.
    private var hotKeyTaken: Bool { !hotKeys.isActive }

    // MARK: Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if arguments.contains("--version") {
            print(AppDelegate.appVersion())
            fflush(stdout)
            exit(0)
        }
        if let index = arguments.firstIndex(of: AppDelegate.uploadPanelTestFlag) {
            skipNormalLaunch = true
            guard index + 1 < arguments.count else {
                FileHandle.standardError.write(Data("usage: --upload-panel-test <path prefix>\n".utf8))
                exit(1)
            }
            uploadPanelTestPrefix = arguments[index + 1]
            return
        }
        if let index = arguments.firstIndex(of: AppDelegate.overlayTestFlag) {
            skipNormalLaunch = true
            guard index + 1 < arguments.count else {
                FileHandle.standardError.write(Data("usage: --overlay-test <path prefix>\n".utf8))
                exit(1)
            }
            overlayTestPrefix = arguments[index + 1]
            return
        }
        if let index = arguments.firstIndex(of: AppDelegate.captureTestFlag) {
            skipNormalLaunch = true
            guard index + 1 < arguments.count else {
                FileHandle.standardError.write(Data("usage: --capture-test <path prefix>\n".utf8))
                exit(1)
            }
            // The capture itself starts once the app has finished launching:
            // ScreenCaptureKit does not answer before that.
            captureTestPrefix = arguments[index + 1]
            return
        }
        if AppDelegate.anotherInstanceRunning() {
            skipNormalLaunch = true
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let prefix = captureTestPrefix {
            runCaptureTest(prefix: prefix)
            return
        }
        if let prefix = overlayTestPrefix {
            runOverlayTest(prefix: prefix)
            return
        }
        if let prefix = uploadPanelTestPrefix {
            runUploadPanelTest(prefix: prefix)
            return
        }
        guard !skipNormalLaunch else { return }

        notifier = Notifier()
        cloud = CloudCoordinator(settings: settings, notifier: notifier)
        actions = ScreenshotActions(settings: settings, cloud: cloud, notifier: notifier)
        updater = Updater(settings: settings)
        overlay = OverlayController(settings: settings)
        // The update alert must not come up under the frozen overlay or on top
        // of another modal session.
        updater.canPresent = { [weak self] in !(self?.overlay.isActive ?? false) && NSApp.modalWindow == nil }

        NSApp.mainMenu = AppDelegate.buildMainMenu(target: self)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "WE Screenshot")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "WE Screenshot"
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        notifier.start()
        hotKeys.onPress = { [weak self] in self?.startCapture() }
        // A refused shortcut stays in the settings; it is retried when the
        // menu opens and when the app becomes active.
        hotKeys.register(settings.captureHotKey)

        cloud.onNeedsSetup = { [weak self] in self?.showSettings() }
        cloud.onStateChange = { [weak self] in self?.settingsWindow?.cloudStateChanged() }
        updater.onStatusChange = nil

        NotificationCenter.default.addObserver(forName: SettingsStore.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.settingsDidChange() }
        }

        updater.start()

        if !settings.didFirstLaunch {
            do { try SMAppService.mainApp.register() } catch { NSLog("WE Screenshot: login item error %@", "\(error)") }
            settings.didFirstLaunch = true
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !skipNormalLaunch, notifier != nil else { return }
        hotKeys.retry()
        settingsWindow?.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeys.unregister()
    }

    /// The menu bar of an accessory app is never visible, but key equivalents
    /// (Cmd+V in a text field, Cmd+W, Cmd+Q) only work through a main menu.
    private static func buildMainMenu(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        let prefs = NSMenuItem(title: L("Settings…"), action: #selector(showSettingsAction), keyEquivalent: ",")
        prefs.target = target
        appMenu.addItem(prefs)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: L("Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Nil targets: the actions travel the responder chain to the field editor.
        let edit = NSMenu(title: L("Edit"))
        edit.addItem(NSMenuItem(title: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: L("Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)

        let window = NSMenu(title: L("Window"))
        window.addItem(NSMenuItem(title: L("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let windowItem = NSMenuItem()
        windowItem.submenu = window
        main.addItem(windowItem)
        return main
    }

    private static func anotherInstanceRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { $0.processIdentifier != me }
    }

    static func appVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    // MARK: Capture test (command line)

    /// Renders both states of the upload pop-up to PNG files, off screen.
    private func runUploadPanelTest(prefix: String) {
        let link = URL(string: "https://drive.google.com/file/d/1AbCdEfGhIjKlMnOpQrStUvWxYz012345/view")!
        let jobs = [(false, "uploading"), (true, "done")]
        for (done, name) in jobs {
            let path = "\(prefix)-\(name).png"
            guard let data = UploadPanelPreview.pngData(done: done, link: link),
                  (try? data.write(to: URL(fileURLWithPath: path))) != nil else {
                FileHandle.standardError.write(Data("upload panel test failed: \(name)\n".utf8))
                exit(1)
            }
            print(path)
        }
        let line = UploadPanelPreview.simulateCopyClick()
        print(line)
        fflush(stdout)
        exit(line.contains("action=yes") && line.contains("pasteboard=ok") ? 0 : 1)
    }

    /// Shows the real overlay for a moment and photographs the screen with it
    /// on, to check on a real Mac that the overlay covers every display.
    private func runOverlayTest(prefix: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            FileHandle.standardError.write(Data("overlay test failed: no answer within 30 seconds\n".utf8))
            exit(2)
        }
        let overlay = OverlayController(settings: settings)
        self.overlay = overlay
        Task { @MainActor in
            do {
                let shots = try await capture.captureAllDisplays()
                var finished = false
                overlay.begin(snapshots: shots) { _ in finished = true }
                print("overlay active: \(overlay.isActive)")
                for screen in NSScreen.screens {
                    print("screen frame \(screen.frame) visible \(screen.visibleFrame)")
                }
                for window in NSApp.windows where window.isVisible {
                    print("window \(type(of: window)) frame \(window.frame) level \(window.level.rawValue) key \(window.isKeyWindow)")
                }
                try await Task.sleep(nanoseconds: 1_500_000_000)
                if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
                    for info in list {
                        let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
                        let layer = info[kCGWindowLayer as String] as? Int ?? 0
                        guard (info[kCGWindowOwnerPID as String] as? Int32) == getpid() || layer == 24 || layer == 20 else { continue }
                        print("onscreen \(owner) layer \(layer) bounds \(info[kCGWindowBounds as String] ?? "") alpha \(info[kCGWindowAlpha as String] ?? "")")
                    }
                }
                let live = try await capture.captureAllDisplays()
                for (index, shot) in live.enumerated() {
                    let data = try ImageEncoder.data(for: shot.image, format: .png, scale: shot.display.scale, jpegQuality: 1)
                    try data.write(to: URL(fileURLWithPath: "\(prefix)-live-\(index).png"))
                }
                overlay.cancel()
                try await Task.sleep(nanoseconds: 500_000_000)
                print("overlay active after cancel: \(overlay.isActive), completion called: \(finished)")
                fflush(stdout)
                exit(finished && !overlay.isActive ? 0 : 3)
            } catch {
                FileHandle.standardError.write(Data("overlay test failed: \(error)\n".utf8))
                exit(1)
            }
        }
    }

    private func runCaptureTest(prefix: String) {
        // A capture that never answers must not leave a hidden process behind.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            FileHandle.standardError.write(Data("capture failed: no answer within 20 seconds\n".utf8))
            exit(2)
        }
        Task { @MainActor in
            do {
                let shots = try await capture.captureAllDisplays()
                for (index, shot) in shots.enumerated() {
                    let data = try ImageEncoder.data(for: shot.image, format: .png, scale: shot.display.scale, jpegQuality: 1)
                    try data.write(to: URL(fileURLWithPath: "\(prefix)-\(index).png"))
                    let f = shot.display.frame
                    print("display \(shot.display.id) frame \(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height)) scale \(shot.display.scale) pixels \(shot.image.width)x\(shot.image.height)")
                }
                fflush(stdout)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
                exit(1)
            }
        }
    }

    // MARK: Hotkey

    private func settingsDidChange() {
        let wanted = settings.captureHotKey
        if hotKeys.current != wanted {
            hotKeys.register(wanted)
        }
        settingsWindow?.refresh()
    }

    /// Used by the settings window: makes the combination the active hotkey, or
    /// keeps the old one and returns false when it is taken.
    private func applyHotKey(_ combo: KeyCombo) -> Bool {
        let previous = settings.captureHotKey
        if hotKeys.register(combo) {
            settings.captureHotKey = combo
            return true
        }
        // If the previous one fails too, isActive says so and it is retried later.
        hotKeys.register(previous)
        return false
    }

    // MARK: Capture flow

    @objc private func startCapture() {
        guard !overlay.isActive, !isPreparingCapture, !isShowingAlert else { return }
        // During a modal session (an alert, a save or print panel) the overlay
        // windows would get no events and hide the panel under a frozen screen.
        if let modal = NSApp.modalWindow {
            NSSound.beep()
            modal.orderFrontRegardless()
            return
        }
        guard ScreenRecordingPermission.isGranted else {
            if !didRequestPermission {
                didRequestPermission = true
                ScreenRecordingPermission.request()
            }
            showPermissionAlert()
            return
        }
        isPreparingCapture = true
        Task { @MainActor in
            defer { isPreparingCapture = false }
            do {
                let shots = try await capture.captureAllDisplays()
                // A modal session may have started while the capture ran.
                guard NSApp.modalWindow == nil else { NSSound.beep(); return }
                overlay.begin(snapshots: shots) { [weak self] result in
                    if let result { self?.actions.perform(result.action, on: result.screenshot) }
                }
            } catch CaptureError.permissionDenied {
                showPermissionAlert()
            } catch {
                showErrorAlert(error)
            }
        }
    }

    private func showPermissionAlert() {
        guard !isShowingAlert else { return }
        isShowingAlert = true
        defer { isShowingAlert = false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("WE Screenshot needs the Screen Recording permission")
        alert.informativeText = L("Turn it on for WE Screenshot in System Settings > Privacy & Security > Screen Recording. macOS may ask you to quit and reopen the app afterwards.")
        alert.addButton(withTitle: L("Open System Settings"))
        alert.addButton(withTitle: L("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            ScreenRecordingPermission.openSystemSettings()
        }
    }

    private func showErrorAlert(_ error: Error) {
        guard !isShowingAlert else { return }
        isShowingAlert = true
        defer { isShowingAlert = false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("The screenshot could not be taken")
        switch error {
        case CaptureError.noDisplays:
            alert.informativeText = L("No display was found.")
        case CaptureError.notResponding:
            alert.informativeText = L("The screen capture service of macOS is not answering. Restart the Mac and try again.")
        case CaptureError.failed(let text):
            alert.informativeText = text
        default:
            alert.informativeText = error.localizedDescription
        }
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let combo = settings.captureHotKey
        hotKeys.retry()

        let shot = captureItem(combo)
        shot.isEnabled = !overlay.isActive
        menu.addItem(shot)
        if hotKeyTaken {
            menu.addItem(disabled(String(format: L("The shortcut %@ is taken by another app"), combo.displayString)))
        }
        if !ScreenRecordingPermission.isGranted {
            menu.addItem(disabled(L("No access to screen recording:")))
            menu.addItem(item(L("Open System Settings…"), #selector(openScreenRecordingSettings)))
        }

        menu.addItem(.separator())
        if cloud.isBusy {
            menu.addItem(disabled(L("Working…")))
        } else if cloud.isSignedIn {
            menu.addItem(disabled(String(format: L("Google Drive: %@"), settings.googleAccountLabel ?? L("signed in"))))
            menu.addItem(item(L("Sign Out of Google Drive"), #selector(signOut)))
        } else {
            menu.addItem(item(L("Sign In to Google Drive…"), #selector(signIn)))
        }

        menu.addItem(.separator())
        let prefs = item(L("Settings…"), #selector(showSettingsAction))
        prefs.keyEquivalent = ","
        prefs.keyEquivalentModifierMask = .command
        menu.addItem(prefs)
        menu.addItem(toggle(L("Open at login"), SMAppService.mainApp.status == .enabled, #selector(toggleLogin)))
        if let status = updater.status {
            menu.addItem(disabled(status))
        } else {
            menu.addItem(item(L("Check for Updates…"), #selector(checkForUpdates)))
        }
        menu.addItem(toggle(L("Check for updates automatically"), settings.autoCheckUpdates, #selector(toggleAutoUpdates)))

        menu.addItem(.separator())
        menu.addItem(disabled("WE Screenshot \(AppDelegate.appVersion())"))
        let quit = item(L("Quit"), #selector(quitApp))
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = .command
        menu.addItem(quit)
    }

    /// "Take Screenshot" with the hotkey at the right: as a real key equivalent
    /// when the key is a plain character, otherwise as text in the title.
    private func captureItem(_ combo: KeyCombo) -> NSMenuItem {
        let title = L("Take Screenshot")
        let it = item(title, #selector(startCaptureFromMenu))
        let key = String(combo.displayString.drop { "\u{2303}\u{2325}\u{21E7}\u{2318}".contains($0) })
        if key.count == 1, key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) {
            it.keyEquivalent = key.lowercased()
            var mask: NSEvent.ModifierFlags = []
            if combo.modifiers.contains(.command) { mask.insert(.command) }
            if combo.modifiers.contains(.shift) { mask.insert(.shift) }
            if combo.modifiers.contains(.option) { mask.insert(.option) }
            if combo.modifiers.contains(.control) { mask.insert(.control) }
            it.keyEquivalentModifierMask = mask
        } else {
            it.title = "\(title)   \(combo.displayString)"
        }
        return it
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        return it
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let it = item(title, action)
        it.state = on ? .on : .off
        return it
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    @objc private func startCaptureFromMenu() {
        // Let the menu finish closing so it is not part of the frozen picture.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self?.startCapture()
        }
    }

    @objc private func openScreenRecordingSettings() { ScreenRecordingPermission.openSystemSettings() }

    @objc private func signIn() {
        let cloud = self.cloud!
        Task { @MainActor in await SignInProgress.run(cloud) }
    }

    @objc private func signOut() {
        let cloud = self.cloud!
        Task { @MainActor in await cloud.signOut() }
    }

    @objc private func showSettingsAction() { showSettings() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("WE Screenshot: login item error %@", "\(error)")
        }
        settingsWindow?.refresh()
    }

    @objc private func checkForUpdates() {
        let updater = self.updater!
        Task { @MainActor in await updater.check(userInitiated: true) }
    }

    @objc private func toggleAutoUpdates() {
        settings.autoCheckUpdates.toggle()
        updater.start()
        settingsWindow?.refresh()
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    // MARK: Settings window

    private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                settings: settings, cloud: cloud, updater: updater,
                applyHotKey: { [weak self] combo in self?.applyHotKey(combo) ?? false },
                pauseHotKey: { [weak self] in self?.hotKeys.pause() },
                resumeHotKey: { [weak self] in self?.hotKeys.resume() },
                isHotKeyActive: { [weak self] in self?.hotKeys.isActive ?? true })
        }
        settingsWindow?.show()
    }
}
