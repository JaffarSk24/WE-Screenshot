import AppKit
import QuartzCore
import WEAnnotate
import WECore

/// Drives the overlay off screen for the developer harness. The views live
/// in windows that are never ordered in, so nothing appears on screen; the
/// harness sends plain points and commands, exactly like the real event
/// methods do, and renders the layer tree into bitmaps.
@_spi(Harness)
@MainActor
public final class OverlayHarness {
    private let session: OverlaySession
    private var windows: [NSWindow] = []

    /// How often the session reported a decision, and the last one.
    public private(set) var finishCount = 0
    public private(set) var finishedAction: ScreenshotAction??

    public init(settings: SettingsStore, snapshots: [DisplaySnapshot]) {
        session = OverlaySession(settings: settings, snapshots: snapshots)
        session.beep = {}
        session.onFinish = { [weak self] action in
            self?.finishCount += 1
            self?.finishedAction = .some(action)
        }
        for view in session.views {
            let frame = CGRect(origin: .zero, size: view.frame.size)
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            windows.append(window)
        }
    }

    // MARK: Input

    public func mouseDown(display: Int, at point: CGPoint) { session.mouseDown(display: display, at: point) }
    public func mouseDragged(to point: CGPoint) { session.mouseDragged(to: point) }
    public func mouseUp(at point: CGPoint) { session.mouseUp(at: point) }

    /// A drag through `points` (at least two) on one display.
    public func drag(display: Int, through points: [CGPoint]) {
        guard let first = points.first, let last = points.last else { return }
        mouseDown(display: display, at: first)
        for p in points.dropFirst() { mouseDragged(to: p) }
        mouseUp(at: last)
    }

    /// The cursor the overlay shows at the point, by name.
    public func cursorName(display: Int, at point: CGPoint) -> String {
        session.mouseIndex = display
        return session.cursor(display: display, at: point).name
    }

    /// Clicks a toolbar button by its identifier ("pencil", "copy", "close"...).
    /// False when there is no such button or it is disabled.
    @discardableResult
    public func press(_ identifier: String, display: Int = 0) -> Bool {
        let view = session.views[display]
        let all = ToolbarItem.toolsPanel.compactMap { $0 } + ToolbarItem.actionsPanel.compactMap { $0 }
        guard let item = all.first(where: { $0.identifier == identifier }), let button = view.button(item),
              button.isEnabled else { return false }
        button.press()
        return true
    }

    /// A key press through the real key mapping. False when the overlay did
    /// not take it.
    @discardableResult
    public func key(code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = [],
                    mouseDisplay: Int = 0) -> Bool {
        session.mouseIndex = mouseDisplay
        guard let command = KeyCommand.from(keyCode: code, characters: characters, modifiers: modifiers) else {
            return false
        }
        return session.perform(command)
    }

    public func setColor(_ color: RGBAColor) { session.setColor(color) }

    // MARK: Text editor

    public var isEditingText: Bool { session.editor != nil }
    public var editorFrame: CGRect? { session.editor?.frame }

    public func type(_ text: String) {
        session.editor?.insertText(text, replacementRange: session.editor?.selectedRange() ?? NSRange())
    }

    /// Return in the editor.
    public func editorReturn() { session.editor?.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
    /// Option+Return in the editor.
    public func editorLineBreak() {
        session.editor?.doCommand(by: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
    }
    /// Escape in the editor.
    public func editorEscape() { session.editor?.doCommand(by: #selector(NSResponder.cancelOperation(_:))) }

    /// A Command shortcut sent to the text editor as a real key event.
    /// False when there is no editor or it did not take the key.
    @discardableResult
    public func editorKey(code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let editor = session.editor, let window = editor.window,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                           timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                           characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: code) else { return false }
        return editor.performKeyEquivalent(with: event)
    }

    /// The selected range of the text editor, if one is open.
    public var editorSelection: NSRange? { session.editor?.selectedRange() }
    /// The text in the editor, if one is open.
    public var editorText: String? { session.editor?.string }

    // MARK: State

    /// Area (in points squared) that live drawing updates marked for redraw
    /// on the display since the last reset.
    public func invalidatedPreviewArea(display: Int) -> CGFloat { session.views[display].invalidatedPreviewArea }
    public func resetInvalidatedPreviewArea(display: Int) { session.views[display].invalidatedPreviewArea = 0 }

    /// The display the controller makes key for a mouse location.
    public static func keyDisplayIndex(mouse: CGPoint, frames: [CGRect]) -> Int {
        OverlayController.displayIndex(at: mouse, in: frames)
    }

    public var tool: Tool? { session.tool }
    public var annotations: [Annotation] { session.annotations.items }
    public var activeDisplay: Int? { session.activeIndex }
    public func selection(display: Int) -> CGRect? { session.views[display].selection.rect }

    public func panelFrames(display: Int) -> (tools: CGRect, actions: CGRect)? {
        let view = session.views[display]
        guard !view.toolsPanel.isHidden else { return nil }
        return (view.toolsPanel.frame, view.actionsPanel.frame)
    }

    public func isEnabled(_ identifier: String, display: Int = 0) -> Bool {
        let all = ToolbarItem.toolsPanel.compactMap { $0 } + ToolbarItem.actionsPanel.compactMap { $0 }
        guard let item = all.first(where: { $0.identifier == identifier }) else { return false }
        return session.views[display].button(item)?.isEnabled ?? false
    }

    /// The composed screenshot, through the same code the controller uses.
    public func result(action: ScreenshotAction) -> OverlayResult? { session.makeResult(action: action) }

    // MARK: Rendering

    /// What the display's window would show, at the display's scale.
    public func render(display: Int) -> CGImage? {
        let view = session.views[display]
        let scale = view.snapshot.display.scale
        view.layoutSubtreeIfNeeded()
        prepare(view, scale: scale)
        CATransaction.flush()
        guard let layer = view.layer else { return nil }
        let width = Int((view.bounds.width * scale).rounded())
        let height = Int((view.bounds.height * scale).rounded())
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            return nil
        }
        // The content view's layer is geometry flipped (the view is flipped);
        // the window server shows it top down, a bitmap context is bottom up.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        layer.render(in: ctx)
        return ctx.makeImage()
    }

    /// Makes every view draw into its layer at the display's scale; a
    /// window that is never shown does not run the display cycle by itself.
    private func prepare(_ view: NSView, scale: CGFloat) {
        if let layer = view.layer, view.wantsUpdateLayer == false {
            layer.contentsScale = scale
            if view.needsDisplay || layer.contents == nil { layer.setNeedsDisplay() }
            layer.displayIfNeeded()
        }
        for sub in view.subviews where !sub.isHidden { prepare(sub, scale: scale) }
    }

    /// Key mapping check for the harness, by name ("copy", "cancel", "nudge(1,0)"...).
    public static func keyCommandName(code: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> String {
        guard let command = KeyCommand.from(keyCode: code, characters: characters, modifiers: modifiers) else {
            return "none"
        }
        switch command {
        case .cancel: return "cancel"
        case .action(let action): return action.rawValue
        case .undo: return "undo"
        case .selectAll: return "selectAll"
        case .nudge(let dx, let dy): return "nudge(\(Int(dx)),\(Int(dy)))"
        case .resize(let dw, let dh): return "resize(\(Int(dw)),\(Int(dh)))"
        }
    }
}
