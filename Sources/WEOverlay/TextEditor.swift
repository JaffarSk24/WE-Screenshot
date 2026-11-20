import AppKit
import WEAnnotate
import WECore

/// The editable text box of the text tool. Borderless, transparent, no
/// padding or inset, so the top left corner of its frame is exactly the
/// `origin` of the text annotation it turns into.
@MainActor
final class AnnotationTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    static func make(origin: CGPoint, color: RGBAColor) -> AnnotationTextView {
        // An explicit TextKit 1 stack: its layout is what the metrics below assume.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 100_000, height: 100_000))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let height = ceil(TextMetrics.lineHeight)
        let view = AnnotationTextView(frame: CGRect(x: origin.x, y: origin.y, width: 4, height: height),
                                      textContainer: container)
        view.configure(color: color)
        return view
    }

    private func configure(color: RGBAColor) {
        textContainerInset = .zero
        drawsBackground = false
        backgroundColor = .clear
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isHorizontallyResizable = false
        isVerticallyResizable = false
        focusRingType = .none
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        font = TextMetrics.font
        defaultParagraphStyle = AnnotationTextView.paragraphStyle
        apply(color: color)
    }

    /// Fixed line height equal to the renderer's, so multi line text lands
    /// on the same baselines in the editor and in the final image.
    private static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = TextMetrics.lineHeight
        style.maximumLineHeight = TextMetrics.lineHeight
        return style
    }

    func apply(color: RGBAColor) {
        let ns = color.nsColor
        textColor = ns
        insertionPointColor = ns
        typingAttributes = [.font: TextMetrics.font, .foregroundColor: ns,
                            .paragraphStyle: AnnotationTextView.paragraphStyle]
        if let storage = textStorage, storage.length > 0 {
            storage.addAttribute(.foregroundColor, value: ns, range: NSRange(location: 0, length: storage.length))
        }
        needsDisplay = true
    }

    /// The text with every kind of line break turned into "\n", which is
    /// what AnnotationRenderer splits on.
    var normalizedText: String {
        string.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
    }

    override func didChangeText() {
        super.didChangeText()
        fitToText()
    }

    /// Grows (or shrinks) the frame to the laid out text, keeping the origin.
    func fitToText() {
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let width = ceil(max(used.maxX, 1)) + 2 // room for the caret
        let height = ceil(max(used.maxY, TextMetrics.lineHeight))
        if frame.size != CGSize(width: width, height: height) {
            setFrameSize(CGSize(width: width, height: height))
        }
    }

    func insertLineBreak() {
        insertText("\n", replacementRange: selectedRange())
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)):
            let flags = NSApp?.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                insertLineBreak()
            } else {
                onCommit?()
            }
        case #selector(insertNewlineIgnoringFieldEditor(_:)), #selector(insertLineBreak(_:)):
            insertLineBreak()
        case #selector(cancelOperation(_:)), #selector(complete(_:)):
            onCancel?()
        default:
            super.doCommand(by: selector)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    // The app has no Edit menu while the overlay is up, so the usual editing
    // shortcuts are handled here. They belong to the editor only.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == [.command] {
            switch key {
            case "c": copy(nil); return true
            case "v": pasteAsPlainText(nil); return true
            case "x": cut(nil); return true
            case "a": selectAll(nil); return true
            case "z": undoManager?.undo(); return true
            default: break
            }
        } else if flags == [.command, .shift], key == "z" {
            undoManager?.redo()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
