import AppKit
import ServiceManagement
import WECloud
import WECore
import WEActions

/// A button that records a keyboard shortcut: click it, then press the keys.
@MainActor
final class ShortcutRecorderButton: NSButton {
    var combo = KeyCombo.defaultCapture { didSet { updateTitle() } }
    /// Called with a valid new shortcut.
    var onCombo: ((KeyCombo) -> Void)?
    /// Called with true when recording starts and false when it ends.
    var onRecordingChange: ((Bool) -> Void)?

    private(set) var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(clicked)
        updateTitle()
    }

    required init?(coder: NSCoder) { nil }

    private func updateTitle() {
        title = isRecording ? L("Type a shortcut…") : combo.displayString
    }

    @objc private func clicked() {
        guard !isRecording else { return }
        isRecording = true
        updateTitle()
        onRecordingChange?(true)
        window?.makeFirstResponder(self)
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        updateTitle()
        onRecordingChange?(false)
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    // Shortcuts with Command would otherwise be taken by the menu bar first.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        handle(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        handle(event)
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isDisjoint(with: [.command, .control, .option]) {
            stopRecording()
            return
        }
        let flags = event.modifierFlags
        var modifiers: KeyCombo.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        let candidate = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        guard candidate.isValidGlobalHotKey else {
            NSSound.beep()
            return
        }
        stopRecording()
        onCombo?(candidate)
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settings: SettingsStore
    private let cloud: CloudCoordinator
    private let updater: Updater
    /// Tries to make the combination the active hotkey; false when it is taken.
    private let applyHotKey: (KeyCombo) -> Bool
    private let pauseHotKey: () -> Void
    private let resumeHotKey: () -> Void

    private let window: NSWindow
    private let recorder = ShortcutRecorderButton(frame: .zero)
    private let resetButton = NSButton(title: L("Reset"), target: nil, action: nil)
    private let shortcutNote = NSTextField(labelWithString: "")
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let retinaCheck = NSButton(checkboxWithTitle: L("Save Retina screenshots at half size"), target: nil, action: nil)
    private let openLinkCheck = NSButton(checkboxWithTitle: L("Open the link after upload"), target: nil, action: nil)
    private let loginCheck = NSButton(checkboxWithTitle: L("Open at login"), target: nil, action: nil)
    private let updatesCheck = NSButton(checkboxWithTitle: L("Check for updates automatically"), target: nil, action: nil)
    private let clientIDField = NSTextField()
    private let clientSecretField = NSSecureTextField()
    private let driveStatus = NSTextField(labelWithString: "")
    private let signButton = NSButton(title: L("Sign In…"), target: nil, action: nil)

    init(settings: SettingsStore, cloud: CloudCoordinator, updater: Updater,
         applyHotKey: @escaping (KeyCombo) -> Bool,
         pauseHotKey: @escaping () -> Void, resumeHotKey: @escaping () -> Void) {
        self.settings = settings
        self.cloud = cloud
        self.updater = updater
        self.applyHotKey = applyHotKey
        self.pauseHotKey = pauseHotKey
        self.resumeHotKey = resumeHotKey
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = L("Settings")
        window.isReleasedWhenClosed = false
        window.delegate = self
        build()
        NotificationCenter.default.addObserver(forName: SettingsStore.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    /// Shows the window (the single instance) and brings the app forward.
    func show() {
        refresh()
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Called by the app when the Google state changes.
    func cloudStateChanged() { refresh() }

    func windowWillClose(_ notification: Notification) {
        // Closing while recording ends the recording through the responder chain,
        // but make sure the hotkey is back in any case.
        if recorder.isRecording { window.makeFirstResponder(nil) }
    }

    // MARK: Layout

    private func build() {
        recorder.onRecordingChange = { [weak self] recording in
            guard let self else { return }
            if recording {
                self.shortcutNote.stringValue = ""
                self.pauseHotKey()
            } else {
                self.resumeHotKey()
            }
        }
        recorder.onCombo = { [weak self] combo in self?.changeShortcut(to: combo) }
        recorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.target = self
        resetButton.action = #selector(resetShortcut)
        shortcutNote.textColor = .systemRed
        shortcutNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        formatPopup.addItems(withTitles: ["PNG", "JPEG"])
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)
        for check in [retinaCheck, openLinkCheck, loginCheck, updatesCheck] {
            check.target = self
        }
        retinaCheck.action = #selector(retinaChanged)
        openLinkCheck.action = #selector(openLinkChanged)
        loginCheck.action = #selector(loginChanged)
        updatesCheck.action = #selector(updatesChanged)

        let shortcutRow = NSStackView(views: [recorder, resetButton])
        shortcutRow.orientation = .horizontal
        shortcutRow.spacing = 8
        let shortcutCell = NSStackView(views: [shortcutRow, shortcutNote])
        shortcutCell.orientation = .vertical
        shortcutCell.alignment = .leading
        shortcutCell.spacing = 4

        let general = NSGridView(views: [
            [rightLabel(L("Shortcut:")), shortcutCell],
            [rightLabel(L("Image format:")), formatPopup],
            [NSGridCell.emptyContentView, retinaCheck],
            [NSGridCell.emptyContentView, openLinkCheck],
            [NSGridCell.emptyContentView, loginCheck],
            [NSGridCell.emptyContentView, updatesCheck],
        ])
        general.column(at: 0).xPlacement = .trailing
        general.rowSpacing = 10
        general.columnSpacing = 10
        general.row(at: 0).yPlacement = .center

        let drive = driveBox()
        let root = NSStackView(views: [general, drive])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            // Fixed width gives the explanation text a size to wrap against.
            drive.widthAnchor.constraint(equalToConstant: 480),
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)
    }

    private func driveBox() -> NSBox {
        let box = NSBox()
        box.title = "Google Drive"
        box.titlePosition = .atTop

        let explanation = NSTextField(wrappingLabelWithString:
            L("Uploads go to the folder “WE Screenshot” in your own Google Drive. Google requires every user of an open-source app to create a personal OAuth client once."))
        explanation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        explanation.textColor = .secondaryLabelColor
        explanation.preferredMaxLayoutWidth = 440

        clientIDField.placeholderString = "xxxx.apps.googleusercontent.com"
        clientSecretField.placeholderString = "GOCSPX-…"
        for field in [clientIDField, clientSecretField] {
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        }
        let fields = NSGridView(views: [
            [rightLabel("Client ID:"), clientIDField],
            [rightLabel("Client secret:"), clientSecretField],
        ])
        fields.column(at: 0).xPlacement = .trailing
        fields.rowSpacing = 8
        fields.columnSpacing = 10

        let help = NSButton(title: L("How to get these…"), target: self, action: #selector(openHelp))
        let save = NSButton(title: L("Save"), target: self, action: #selector(saveClient))
        let buttons = NSStackView(views: [help, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        signButton.target = self
        signButton.action = #selector(signClicked)
        driveStatus.lineBreakMode = .byTruncatingTail
        driveStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let statusRow = NSStackView(views: [driveStatus, signButton])
        statusRow.orientation = .horizontal
        statusRow.spacing = 10

        let stack = NSStackView(views: [explanation, fields, buttons, statusRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView = NSView()
        box.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: box.contentView!.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: box.contentView!.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: box.contentView!.bottomAnchor, constant: -12),
        ])
        return box
    }

    private func rightLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }

    // MARK: State

    private func isEditing(_ field: NSTextField) -> Bool {
        field.currentEditor() != nil
    }

    func refresh() {
        if !recorder.isRecording { recorder.combo = settings.captureHotKey }
        formatPopup.selectItem(at: settings.imageFormat == .png ? 0 : 1)
        retinaCheck.state = settings.downscaleRetina ? .on : .off
        openLinkCheck.state = settings.openLinkAfterUpload ? .on : .off
        loginCheck.state = SMAppService.mainApp.status == .enabled ? .on : .off
        updatesCheck.state = settings.autoCheckUpdates ? .on : .off
        if !isEditing(clientIDField) { clientIDField.stringValue = settings.googleClientID ?? "" }
        if !isEditing(clientSecretField) { clientSecretField.stringValue = cloud.clientSecret ?? "" }
        if cloud.isSignedIn {
            driveStatus.stringValue = String(format: L("Signed in as %@"), settings.googleAccountLabel ?? L("your Google account"))
            signButton.title = L("Sign Out")
            signButton.isEnabled = !cloud.isBusy
        } else {
            driveStatus.stringValue = cloud.isConfigured ? L("Signed out") : L("Not set up")
            signButton.title = L("Sign In…")
            signButton.isEnabled = cloud.isConfigured && !cloud.isBusy
        }
    }

    // MARK: Actions

    private func changeShortcut(to combo: KeyCombo) {
        let previous = settings.captureHotKey
        if combo == previous {
            recorder.combo = previous
            return
        }
        if applyHotKey(combo) {
            recorder.combo = combo
            shortcutNote.stringValue = ""
        } else {
            recorder.combo = previous
            shortcutNote.stringValue = String(format: L("The shortcut %@ is taken by another app"), combo.displayString)
        }
    }

    @objc private func resetShortcut() {
        if recorder.isRecording { window.makeFirstResponder(nil) }
        changeShortcut(to: .defaultCapture)
    }

    @objc private func formatChanged() { settings.imageFormat = formatPopup.indexOfSelectedItem == 0 ? .png : .jpeg }
    @objc private func retinaChanged() { settings.downscaleRetina = retinaCheck.state == .on }
    @objc private func openLinkChanged() { settings.openLinkAfterUpload = openLinkCheck.state == .on }

    @objc private func loginChanged() {
        do {
            if loginCheck.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("WE Screenshot: login item error %@", "\(error)")
        }
        refresh()
    }

    @objc private func updatesChanged() {
        settings.autoCheckUpdates = updatesCheck.state == .on
        updater.start()
    }

    @objc private func openHelp() {
        if let url = URL(string: "https://github.com/JaffarSk24/WE-Screenshot#google-drive-setup") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func saveClient() {
        let id = clientIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecretField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        cloud.setClient(id: id.isEmpty ? nil : id, secret: secret.isEmpty ? nil : secret)
        window.makeFirstResponder(nil)
        refresh()
    }

    @objc private func signClicked() {
        let cloud = self.cloud
        if cloud.isSignedIn {
            Task { @MainActor [weak self] in
                await cloud.signOut()
                self?.refresh()
            }
        } else {
            Task { @MainActor [weak self] in
                await cloud.signIn()
                self?.refresh()
            }
        }
    }
}
