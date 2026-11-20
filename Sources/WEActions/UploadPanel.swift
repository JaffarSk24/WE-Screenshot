import AppKit
import WECore

/// The two looks of the upload pop-up.
enum UploadPanelState: Equatable {
    case uploading
    case done(URL)
}

private enum PanelStyle {
    static let background = NSColor(srgbRed: 0x37 / 255, green: 0x41 / 255, blue: 0x61 / 255, alpha: 0.97)
    static let field = NSColor(srgbRed: 0x45 / 255, green: 0x50 / 255, blue: 0x73 / 255, alpha: 1)
    static let accent = NSColor(srgbRed: 0xF9 / 255, green: 0x73 / 255, blue: 0x16 / 255, alpha: 1)
    static let width: CGFloat = 360
    static let uploadingHeight: CGFloat = 76
    static let doneHeight: CGFloat = 112
}

/// A flat button that reads well on the dark blue panel.
/// Measures button titles in the font the panel buttons use.
private enum PillButtonMetrics {
    static let font = NSFont.systemFont(ofSize: 12, weight: .semibold)

    static func width(of title: String) -> CGFloat {
        (title as NSString).size(withAttributes: [.font: font]).width
    }
}

private final class PanelButton: NSButton {
    var filled = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        focusRingType = .none
    }

    required init?(coder: NSCoder) { nil }

    func setLabel(_ text: String) {
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: PillButtonMetrics.font,
            .foregroundColor: NSColor.white,
        ])
        setAccessibilityLabel(text)
        layer?.backgroundColor = (filled ? PanelStyle.accent : PanelStyle.field).cgColor
    }
}

/// The rounded content of the pop-up. Flipped, so the layout reads top down.
private final class UploadPanelView: NSView {
    var onCopy: (() -> Void)?
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let linkField = NSTextField(string: "")
    /// Holds the field with some padding; the field itself has no inset.
    private let linkBox = NSView()
    private let copyButton = PanelButton(frame: .zero)
    private let openButton = PanelButton(frame: .zero)
    private let closeButton = NSButton()
    private(set) var state: UploadPanelState = .uploading

    override var isFlipped: Bool { true }

    var isEditingLink: Bool { linkField.currentEditor() != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = PanelStyle.background.cgColor
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        progress.style = .bar
        progress.isIndeterminate = true
        progress.controlSize = .small
        addSubview(progress)

        linkField.isEditable = false
        linkField.isSelectable = true
        linkField.isBezeled = false
        linkField.drawsBackground = false
        linkField.textColor = .white
        linkField.font = NSFont.systemFont(ofSize: 12)
        linkField.lineBreakMode = .byTruncatingMiddle
        linkField.usesSingleLineMode = true
        linkField.cell?.isScrollable = false
        linkField.focusRingType = .none
        linkField.setAccessibilityLabel(L("Link to the uploaded screenshot"))
        linkBox.wantsLayer = true
        linkBox.layer?.backgroundColor = PanelStyle.field.cgColor
        linkBox.layer?.cornerRadius = 6
        linkBox.addSubview(linkField)
        addSubview(linkBox)

        copyButton.filled = true
        copyButton.target = self
        copyButton.action = #selector(copyPressed)
        openButton.target = self
        openButton.action = #selector(openPressed)
        addSubview(copyButton)
        addSubview(openButton)

        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L("Close"))
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.7)
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.setAccessibilityLabel(L("Close"))
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.focusRingType = .none
        addSubview(closeButton)

        apply(.uploading)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func copyPressed() { onCopy?() }
    @objc private func openPressed() { onOpen?() }
    @objc private func closePressed() { onClose?() }

    func apply(_ newState: UploadPanelState) {
        state = newState
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        switch newState {
        case .uploading:
            titleLabel.stringValue = L("Uploading the screenshot…")
            icon.image = NSImage(systemSymbolName: "icloud.and.arrow.up", accessibilityDescription: nil)?
                .withSymbolConfiguration(symbolConfig)
            icon.contentTintColor = .white
            progress.isHidden = false
            progress.startAnimation(nil)
            linkBox.isHidden = true
            copyButton.isHidden = true
            openButton.isHidden = true
        case .done(let link):
            titleLabel.stringValue = L("The link is in the clipboard")
            icon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(symbolConfig)
            icon.contentTintColor = PanelStyle.accent
            progress.stopAnimation(nil)
            progress.isHidden = true
            linkField.stringValue = link.absoluteString
            linkBox.isHidden = false
            copyButton.setLabel(L("Copy"))
            openButton.setLabel(L("Open"))
            copyButton.isHidden = false
            openButton.isHidden = false
        }
        setFrameSize(NSSize(width: PanelStyle.width, height: Self.height(for: newState)))
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func showCopied() {
        copyButton.setLabel(L("Copied"))
    }

    func resetCopyLabel() {
        copyButton.setLabel(L("Copy"))
    }

    static func height(for state: UploadPanelState) -> CGFloat {
        if case .done = state { return PanelStyle.doneHeight }
        return PanelStyle.uploadingHeight
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        icon.frame = NSRect(x: 16, y: 14, width: 30, height: 30)
        closeButton.frame = NSRect(x: w - 30, y: 8, width: 20, height: 20)
        let textX: CGFloat = 58
        titleLabel.frame = NSRect(x: textX, y: 14, width: w - textX - 36, height: 18)
        switch state {
        case .uploading:
            progress.frame = NSRect(x: textX, y: 42, width: w - textX - 16, height: 12)
        case .done:
            linkBox.frame = NSRect(x: textX, y: 40, width: w - textX - 16, height: 24)
            linkField.frame = NSRect(x: 8, y: 4, width: linkBox.bounds.width - 16, height: 16)
            let buttonY: CGFloat = 74
            // The titles are translated, so the widths follow the text. The
            // Copy button is sized for its longer label so it does not jump.
            let openWidth = max(64, ceil(PillButtonMetrics.width(of: L("Open"))) + 24)
            let copyWidth = max(76, ceil(max(PillButtonMetrics.width(of: L("Copy")),
                                             PillButtonMetrics.width(of: L("Copied")))) + 24)
            openButton.frame = NSRect(x: w - 16 - openWidth, y: buttonY, width: openWidth, height: 26)
            copyButton.frame = NSRect(x: openButton.frame.minX - 8 - copyWidth, y: buttonY, width: copyWidth, height: 26)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

private final class FloatingPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

/// The small pop-up that follows an upload: progress, then the link.
@MainActor
final class UploadPanelController {
    private static let lingerSeconds: TimeInterval = 12
    private static let fadeSeconds: TimeInterval = 0.15

    private let panel: FloatingPanel
    private let content: UploadPanelView
    private var hovering = false
    private var closeTimer: Timer?
    private var copiedTimer: Timer?
    /// Bumped on every show and close, so a late fade-out cannot hide a newer panel.
    private var generation = 0

    init() {
        let size = NSSize(width: PanelStyle.width, height: PanelStyle.uploadingHeight)
        content = UploadPanelView(frame: NSRect(origin: .zero, size: size))
        panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: true)
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        panel.setAccessibilityLabel(L("Uploading the screenshot…"))

        panel.onEscape = { [weak self] in self?.close() }
        content.onClose = { [weak self] in self?.close() }
        content.onCopy = { [weak self] in self?.copyLink() }
        content.onOpen = { [weak self] in self?.openLink() }
        content.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.panel.makeFirstResponder(nil)
                if self.panel.isVisible, self.closeTimer == nil, !self.hovering { self.scheduleClose(after: 3) }
            }
        }
    }

    private var resignObserver: NSObjectProtocol?

    /// Shows the panel in the uploading state, on the screen under the pointer.
    func showUploading(on screen: NSScreen?) {
        generation += 1
        cancelTimers()
        content.apply(.uploading)
        present(on: screen ?? Self.screenUnderPointer())
    }

    /// Switches to the link state and starts the countdown to closing.
    func showDone(link: URL) {
        generation += 1
        cancelTimers()
        content.apply(.done(link))
        if !panel.isVisible { present(on: nil) } else { resizeKeepingCorner() }
        scheduleClose()
    }

    func close() {
        guard panel.isVisible else { return }
        cancelTimers()
        generation += 1
        let token = generation
        hovering = false
        panel.makeFirstResponder(nil)
        if Self.reduceMotion {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeSeconds
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == token else { return }
            self.panel.orderOut(nil)
        })
    }

    static func screenUnderPointer() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: Placement

    private func present(on screen: NSScreen?) {
        let target = screen ?? panel.screen ?? NSScreen.main
        if let target {
            let visible = target.visibleFrame
            let size = content.frame.size
            panel.setFrame(NSRect(x: visible.maxX - 12 - size.width, y: visible.maxY - 12 - size.height,
                                  width: size.width, height: size.height), display: false)
        }
        if !panel.isVisible {
            panel.alphaValue = Self.reduceMotion ? 1 : 0
            panel.orderFrontRegardless()
        }
        if Self.reduceMotion {
            panel.alphaValue = 1
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeSeconds
                panel.animator().alphaValue = 1
            }
        }
    }

    /// The height changes between states; the top right corner stays put.
    private func resizeKeepingCorner() {
        let old = panel.frame
        let size = content.frame.size
        panel.setFrame(NSRect(x: old.maxX - size.width, y: old.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }

    // MARK: Actions and timers

    private func copyLink() {
        guard case .done(let link) = content.state else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(link.absoluteString, forType: .string)
        content.showCopied()
        copiedTimer?.invalidate()
        copiedTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.content.resetCopyLabel() }
        }
    }

    private func openLink() {
        guard case .done(let link) = content.state else { return }
        NSWorkspace.shared.open(link)
        close()
    }

    private func hoverChanged(_ inside: Bool) {
        hovering = inside
        guard case .done = content.state else { return }
        if inside {
            closeTimer?.invalidate()
        } else {
            scheduleClose()
        }
    }

    private func scheduleClose(after seconds: TimeInterval = UploadPanelController.lingerSeconds) {
        closeTimer?.invalidate()
        closeTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.closeTimerFired() }
        }
    }

    private func closeTimerFired() {
        // Never close under the pointer or while the link is being selected.
        // The selection only counts while the panel is key: after the user goes
        // back to another app the field editor stays attached.
        let selecting = panel.isKeyWindow && content.isEditingLink
        if hovering || selecting {
            if selecting { scheduleClose(after: 3) }
            return
        }
        close()
    }

    private func cancelTimers() {
        closeTimer?.invalidate()
        closeTimer = nil
        copiedTimer?.invalidate()
        copiedTimer = nil
    }
}

/// Off screen rendering of the pop-up, for the command line check.
public enum UploadPanelPreview {
    /// Renders one state at 2x without creating a window. The result is a PNG.
    @MainActor
    @_spi(Harness)
    public static func pngData(done: Bool, link: URL) -> Data? {
        let state: UploadPanelState = done ? .done(link) : .uploading
        let size = NSSize(width: PanelStyle.width, height: UploadPanelView.height(for: state))
        let view = UploadPanelView(frame: NSRect(origin: .zero, size: size))
        view.apply(state)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                         pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
