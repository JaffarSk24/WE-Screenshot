import AppKit
import WEAnnotate
import WECore

/// What the overlay ends with when the user picks an action.
public struct OverlayResult {
    public let action: ScreenshotAction
    public let screenshot: FinishedScreenshot

    public init(action: ScreenshotAction, screenshot: FinishedScreenshot) {
        self.action = action
        self.screenshot = screenshot
    }
}

/// The screenshot mode: frozen pictures of all displays shown full screen and
/// dimmed, a selection the user draws with the mouse, the drawing tools and
/// the action buttons.
@MainActor
public final class OverlayController {
    private let settings: SettingsStore
    private var session: OverlaySession?
    private var windows: [OverlayWindow] = []
    private var completion: ((OverlayResult?) -> Void)?
    private var previousApp: NSRunningApplication?
    private var screenTarget: SelectorTarget?
    private var colorTarget: SelectorTarget?
    private var savedColorPanel: (level: NSWindow.Level, behavior: NSWindow.CollectionBehavior)?

    public init(settings: SettingsStore) {
        self.settings = settings
    }

    /// True while the overlay is on screen.
    public var isActive: Bool {
        session != nil
    }

    /// Shows the overlay on every display. `completion` is called exactly once
    /// on the main thread, after the overlay windows are gone: with the result
    /// when the user picked an action, with nil when the user cancelled.
    /// Calling begin while active does nothing.
    public func begin(snapshots: [DisplaySnapshot], completion: @escaping (OverlayResult?) -> Void) {
        guard session == nil else { return }
        guard !snapshots.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        self.completion = completion
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front

        let session = OverlaySession(settings: settings, snapshots: snapshots)
        session.onFinish = { [weak self] action in self?.finish(action) }
        session.onColorButton = { [weak self] in self?.showColorPanel() }
        self.session = session

        windows = session.views.map { view in
            let window = OverlayWindow(frame: view.snapshot.display.frame)
            window.contentView = view
            return window
        }

        let target = SelectorTarget { [weak self] _ in self?.cancel() }
        NotificationCenter.default.addObserver(target, selector: #selector(SelectorTarget.fire(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
        screenTarget = target

        (NSApp as LegacyActivation).activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        let keyIndex = snapshots.firstIndex { $0.display.frame.contains(mouse) } ?? 0
        session.mouseIndex = keyIndex
        for (index, window) in windows.enumerated() where index != keyIndex {
            window.orderFrontRegardless()
        }
        let keyWindow = windows[keyIndex]
        keyWindow.makeKeyAndOrderFront(nil)
        keyWindow.orderFrontRegardless()
        keyWindow.makeFirstResponder(session.views[keyIndex])
        session.views[keyIndex].updateCursorFromMouse()
    }

    /// Closes the overlay as if the user pressed Escape.
    public func cancel() {
        guard let session else { return }
        if session.isFinished {
            finish(nil)
        } else {
            session.finish(nil)
        }
    }

    // MARK: Closing

    private func finish(_ action: ScreenshotAction?) {
        guard let session, let completion else { return }
        // Compose before anything is released; a failure ends like a cancel.
        let result = action.flatMap { session.makeResult(action: $0) }
        self.completion = nil
        tearDown()
        DispatchQueue.main.async { completion(result) }
    }

    private func tearDown() {
        if let screenTarget { NotificationCenter.default.removeObserver(screenTarget) }
        screenTarget = nil
        restoreColorPanel()
        session?.invalidate()
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        windows = []
        session = nil
        NSCursor.arrow.set()
        if let app = previousApp, !app.isTerminated {
            app.activate(options: [])
        }
        previousApp = nil
    }

    // MARK: Colour panel

    private func showColorPanel() {
        guard let session else { return }
        let panel = NSColorPanel.shared
        if savedColorPanel == nil {
            savedColorPanel = (panel.level, panel.collectionBehavior)
        }
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = session.color.nsColor
        let target = SelectorTarget { [weak self] sender in
            guard let panel = sender as? NSColorPanel else { return }
            self?.session?.setColor(RGBAColor(nsColor: panel.color).withAlpha(1))
        }
        colorTarget = target
        panel.setTarget(target)
        panel.setAction(#selector(SelectorTarget.fire(_:)))
        panel.level = NSWindow.Level(rawValue: OverlayWindow.overlayLevel.rawValue + 1)
        panel.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
        panel.orderFrontRegardless()
    }

    private func restoreColorPanel() {
        guard let saved = savedColorPanel else { return }
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.orderOut(nil)
        panel.level = saved.level
        panel.collectionBehavior = saved.behavior
        savedColorPanel = nil
        colorTarget = nil
    }
}

/// Calling through this protocol keeps the activation that steals focus
/// (needed: the overlay must take the keyboard from the app in front)
/// without a deprecation warning on the macOS 14 SDK.
@MainActor
private protocol LegacyActivation {
    func activate(ignoringOtherApps flag: Bool)
}

extension NSApplication: LegacyActivation {}

/// A borderless window that covers one display exactly, above everything.
@MainActor
final class OverlayWindow: NSWindow {
    static let overlayLevel = NSWindow.Level.screenSaver

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = OverlayWindow.overlayLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        isMovable = false
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // The window must cover the menu bar and the Dock too.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
