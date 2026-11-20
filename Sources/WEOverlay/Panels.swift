import AppKit
import WEAnnotate
import WECore

/// One button of the two toolbars.
enum ToolbarItem: Hashable {
    case tool(Tool)
    case color
    case undo
    case action(ScreenshotAction)
    case close

    static let toolsPanel: [ToolbarItem?] = [
        .tool(.pencil), .tool(.line), .tool(.arrow), .tool(.rectangle), .tool(.marker), .tool(.text),
        nil, .color, .undo,
    ]
    static let actionsPanel: [ToolbarItem?] = [
        .action(.upload), .action(.searchSimilar), .action(.print), .action(.copy), .action(.save),
        nil, .close,
    ]

    /// Short name used by the harness.
    var identifier: String {
        switch self {
        case .tool(let tool): return tool.rawValue
        case .color: return "color"
        case .undo: return "undo"
        case .action(let action): return action.rawValue
        case .close: return "close"
        }
    }

    var symbolName: String? {
        switch self {
        case .tool(.pencil): return "pencil"
        case .tool(.line): return "line.diagonal"
        case .tool(.arrow): return "arrow.up.right"
        case .tool(.rectangle): return "rectangle"
        case .tool(.marker): return "highlighter"
        case .tool(.text): return "textformat"
        case .color: return nil
        case .undo: return "arrow.uturn.backward"
        case .action(.upload): return "icloud.and.arrow.up"
        case .action(.searchSimilar): return "magnifyingglass"
        case .action(.print): return "printer"
        case .action(.copy): return "doc.on.doc"
        case .action(.save), .action(.quickSave): return "square.and.arrow.down"
        case .close: return "xmark"
        }
    }

    var toolTip: String {
        switch self {
        case .tool(.pencil): return L("Pencil")
        case .tool(.line): return L("Line")
        case .tool(.arrow): return L("Arrow")
        case .tool(.rectangle): return L("Rectangle")
        case .tool(.marker): return L("Marker")
        case .tool(.text): return L("Text")
        case .color: return L("Color")
        case .undo: return L("Undo (⌘Z)")
        case .action(.upload): return L("Upload to Google Drive (⌘D)")
        case .action(.searchSimilar): return L("Search similar images")
        case .action(.print): return L("Print (⌘P)")
        case .action(.copy): return L("Copy (⌘C)")
        case .action(.save): return L("Save as…")
        case .action(.quickSave): return L("Save (⌘S)")
        case .close: return L("Close (Esc)")
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .tool(.pencil): return L("Pencil")
        case .tool(.line): return L("Line")
        case .tool(.arrow): return L("Arrow")
        case .tool(.rectangle): return L("Rectangle")
        case .tool(.marker): return L("Marker")
        case .tool(.text): return L("Text")
        case .color: return L("Color")
        case .undo: return L("Undo")
        case .action(.upload): return L("Upload to Google Drive")
        case .action(.searchSimilar): return L("Search similar images")
        case .action(.print): return L("Print")
        case .action(.copy): return L("Copy")
        case .action(.save): return L("Save as…")
        case .action(.quickSave): return L("Save")
        case .close: return L("Close")
        }
    }
}

/// A rounded dark panel holding a row or a column of buttons.
@MainActor
final class PanelView: NSView {
    enum Axis { case horizontal, vertical }

    static let buttonSize: CGFloat = 30
    static let inset: CGFloat = 4
    static let spacing: CGFloat = 2
    static let separatorSpace: CGFloat = 9

    private(set) var buttons: [ToolbarItem: PanelButton] = [:]

    init(items: [ToolbarItem?], axis: Axis, onPress: @escaping (ToolbarItem) -> Void) {
        let size = PanelView.size(for: items, axis: axis)
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = OverlayStyle.panelBackground.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = OverlayStyle.panelBorder.cgColor

        var offset = PanelView.inset
        for (index, item) in items.enumerated() {
            if let item {
                let frame = axis == .vertical
                    ? CGRect(x: PanelView.inset, y: offset, width: PanelView.buttonSize, height: PanelView.buttonSize)
                    : CGRect(x: offset, y: PanelView.inset, width: PanelView.buttonSize, height: PanelView.buttonSize)
                let button = PanelButton(item: item, frame: frame, onPress: onPress)
                addSubview(button)
                buttons[item] = button
                offset += PanelView.buttonSize
                if index < items.count - 1, items[index + 1] != nil { offset += PanelView.spacing }
            } else {
                let middle = offset + (PanelView.separatorSpace - 1) / 2
                let frame = axis == .vertical
                    ? CGRect(x: PanelView.inset + 4, y: middle, width: PanelView.buttonSize - 8, height: 1)
                    : CGRect(x: middle, y: PanelView.inset + 4, width: 1, height: PanelView.buttonSize - 8)
                let line = NSView(frame: frame)
                line.wantsLayer = true
                line.layer?.backgroundColor = NSColor(white: 1, alpha: 0.22).cgColor
                addSubview(line)
                offset += PanelView.separatorSpace
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    static func size(for items: [ToolbarItem?], axis: Axis) -> CGSize {
        var length = inset * 2
        for (index, item) in items.enumerated() {
            if item != nil {
                length += buttonSize
                if index < items.count - 1, items[index + 1] != nil { length += spacing }
            } else {
                length += separatorSpace
            }
        }
        let thickness = buttonSize + inset * 2
        return axis == .vertical ? CGSize(width: thickness, height: length) : CGSize(width: length, height: thickness)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Clicks on the padding must not reach the overlay (they would start a selection).
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    func update(tool: Tool?, color: RGBAColor, canUndo: Bool) {
        for (item, button) in buttons {
            switch item {
            case .tool(let t): button.isActive = (t == tool)
            case .color: button.swatch = color
            case .undo: button.isEnabled = canUndo
            default: break
            }
        }
    }
}

/// A 30 x 30 point button with an SF Symbol (or the colour swatch), hover
/// highlight and an accent background when active.
@MainActor
final class PanelButton: NSView {
    let item: ToolbarItem
    private let onPress: (ToolbarItem) -> Void
    private var trackingArea: NSTrackingArea?
    private var isPressed = false

    var isActive = false { didSet { if isActive != oldValue { needsDisplay = true } } }
    var isEnabled = true { didSet { if isEnabled != oldValue { needsDisplay = true } } }
    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    var swatch: RGBAColor = .red { didSet { if swatch != oldValue { needsDisplay = true } } }

    private static var symbolCache: [String: NSImage] = [:]

    init(item: ToolbarItem, frame: CGRect, onPress: @escaping (ToolbarItem) -> Void) {
        self.item = item
        self.onPress = onPress
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        toolTip = item.toolTip
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if inside != isPressed {
            isPressed = inside
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        needsDisplay = true
        if inside { press() }
    }

    func press() {
        guard isEnabled else { return }
        onPress(item)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 1, dy: 1)
        let background = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        if isActive {
            OverlayStyle.accent.setFill()
            background.fill()
        } else if isEnabled && (isPressed || isHovered) {
            NSColor(white: 1, alpha: isPressed ? 0.24 : 0.14).setFill()
            background.fill()
        }

        if item == .color {
            let circle = NSRect(x: bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16)
            let path = NSBezierPath(ovalIn: circle)
            swatch.nsColor.setFill()
            path.fill()
            path.lineWidth = 1.5
            NSColor.white.setStroke()
            path.stroke()
            return
        }

        guard let name = item.symbolName, let image = PanelButton.symbol(name) else { return }
        let size = image.size
        let rect = NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(),
                          width: size.width, height: size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.35,
                   respectFlipped: true, hints: nil)
    }

    /// The symbol rendered white once, so drawing does not depend on template tinting.
    private static func symbol(_ name: String) -> NSImage? {
        if let cached = symbolCache[name] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let size = base.size
        let tinted = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        symbolCache[name] = tinted
        return tinted
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { item.accessibilityLabel }
    override func accessibilityHelp() -> String? { item.toolTip }
    override func isAccessibilityEnabled() -> Bool { isEnabled }
    override func isAccessibilitySelected() -> Bool { isActive }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        press()
        return true
    }
}

/// The small dark label with the pixel size of the selection.
@MainActor
final class BadgeView: NSView {
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: BadgeView.font, .foregroundColor: NSColor.white]
    }

    func fittingSize(for text: String) -> CGSize {
        let size = (text as NSString).size(withAttributes: attributes)
        return CGSize(width: ceil(size.width) + 12, height: ceil(size.height) + 6)
    }

    override func draw(_ dirtyRect: NSRect) {
        OverlayStyle.badgeBackground.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
}
