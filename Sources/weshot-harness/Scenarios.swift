import AppKit
import ImageIO
@_spi(Harness) import WEOverlay
import WEAnnotate
import WECore

// The scenarios and checks of the harness; main.swift only parses the
// arguments and starts them on the main actor.

var outputFolder = URL(fileURLWithPath: "/dev/null")
var failures = 0

@MainActor
func check(_ condition: Bool, _ message: String) {
    print((condition ? "ok   " : "FAIL ") + message)
    if !condition { failures += 1 }
}

/// A made up desktop: gradient, grid, a few windows and labels in the
/// corners, so dimming, cropping and orientation are easy to judge.
func makeDesktop(width: CGFloat, height: CGFloat, scale: CGFloat) -> CGImage {
    let pw = Int(width * scale), ph = Int(height * scale)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    // Work in points with the origin at the top left, like the overlay.
    ctx.translateBy(x: 0, y: CGFloat(ph))
    ctx.scaleBy(x: scale, y: -scale)
    let colors = [CGColor(srgbRed: 0.16, green: 0.30, blue: 0.52, alpha: 1),
                  CGColor(srgbRed: 0.78, green: 0.62, blue: 0.80, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width * 0.3, y: height),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.15))
    ctx.setLineWidth(1)
    var x: CGFloat = 0
    while x <= width { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: height)); x += 100 }
    var y: CGFloat = 0
    while y <= height { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: width, y: y)); y += 100 }
    ctx.strokePath()

    func window(_ rect: CGRect, _ title: String, _ tint: CGColor) {
        ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1))
        ctx.fill(rect)
        ctx.setFillColor(tint)
        ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 26))
        ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.86, blue: 0.9, alpha: 1))
        for row in 0..<6 {
            ctx.fill(CGRect(x: rect.minX + 16, y: rect.minY + 44 + CGFloat(row) * 22,
                            width: rect.width * (row % 2 == 0 ? 0.7 : 0.5), height: 10))
        }
        text(title, at: CGPoint(x: rect.minX + 10, y: rect.minY + 5), size: 13, color: .white)
    }

    let nsContext = NSGraphicsContext(cgContext: ctx, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsContext
    func text(_ string: String, at point: CGPoint, size: CGFloat, color: NSColor) {
        (string as NSString).draw(at: point, withAttributes: [.font: NSFont.boldSystemFont(ofSize: size),
                                                              .foregroundColor: color])
    }
    window(CGRect(x: width * 0.18, y: height * 0.2, width: width * 0.36, height: height * 0.4), "Notes",
           CGColor(srgbRed: 0.22, green: 0.25, blue: 0.38, alpha: 1))
    window(CGRect(x: width * 0.5, y: height * 0.42, width: width * 0.3, height: height * 0.36), "Browser",
           CGColor(srgbRed: 0.98, green: 0.45, blue: 0.09, alpha: 1))
    ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.75, blue: 0.4, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: width * 0.08, y: height * 0.68, width: 120, height: 120))
    text("TOP LEFT", at: CGPoint(x: 12, y: 8), size: 20, color: .white)
    text("BOTTOM RIGHT", at: CGPoint(x: width - 170, y: height - 36), size: 20, color: .white)
    text("WE Screenshot harness desktop", at: CGPoint(x: width * 0.3, y: height * 0.08), size: 28, color: .white)
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}

@MainActor
func write(_ image: CGImage?, _ name: String) {
    guard let image else {
        check(false, "render \(name)")
        return
    }
    let url = outputFolder.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        check(false, "write \(name)")
        return
    }
    CGImageDestinationAddImage(destination, image, nil)
    check(CGImageDestinationFinalize(destination), "wrote \(name) (\(image.width)x\(image.height))")
}

/// Pixels of `a` and `b` inside `rect` (points) whose colours differ clearly.
func differingPixels(_ a: CGImage, _ b: CGImage, in rect: CGRect, scale: CGFloat) -> (differ: Int, inked: Int) {
    func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }
    let pa = pixels(a), pb = pixels(b)
    var differ = 0, inked = 0
    let x0 = max(0, Int(rect.minX * scale)), x1 = min(a.width, Int(rect.maxX * scale))
    let y0 = max(0, Int(rect.minY * scale)), y1 = min(a.height, Int(rect.maxY * scale))
    guard x0 < x1, y0 < y1 else { return (0, 0) }
    for y in y0..<y1 {
        for x in x0..<x1 {
            let i = (y * a.width + x) * 4
            var delta = 0
            for c in 0..<3 { delta = max(delta, abs(Int(pa[i + c]) - Int(pb[i + c]))) }
            if delta > 60 { differ += 1 }
            // Red text ink in the committed picture.
            if Int(pb[i]) > 180 && Int(pb[i + 1]) < 90 { inked += 1 }
        }
    }
    return (differ, inked)
}

let red = RGBAColor.red

func makeSettings() -> SettingsStore {
    let suite = "weshot-harness-\(ProcessInfo.processInfo.processIdentifier)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return SettingsStore(defaults: defaults)
}

func cleanUp(_ settings: SettingsStore) {
    let suite = "weshot-harness-\(ProcessInfo.processInfo.processIdentifier)"
    UserDefaults().removePersistentDomain(forName: suite)
    // The suite leaves an empty plist behind; the harness must not litter Preferences.
    let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
    if let file = library?.appendingPathComponent("Preferences/\(suite).plist") {
        try? FileManager.default.removeItem(at: file)
    }
}

/// Draws one of each tool inside `sel` and leaves the pencil active.
/// Returns the editor frame and the renders with and without the editor.
@MainActor
func drawEverything(_ h: OverlayHarness, in sel: CGRect, prefix: String) -> (editing: CGImage?, committed: CGImage?, editor: CGRect?) {
    // Positions are fractions of the selection, so the same drawing fits any display.
    func at(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        CGPoint(x: (sel.minX + fx * sel.width).rounded(), y: (sel.minY + fy * sel.height).rounded())
    }
    h.press("pencil")
    var squiggle: [CGPoint] = []
    for i in 0...40 {
        let t = CGFloat(i) / 40
        squiggle.append(CGPoint(x: at(0.05 + t * 0.3, 0).x, y: at(0, 0.15).y + sin(t * .pi * 4) * sel.height * 0.06))
    }
    h.drag(display: 0, through: squiggle)
    h.press("line")
    h.drag(display: 0, through: [at(0.05, 0.32), at(0.35, 0.42)])
    h.press("arrow")
    h.drag(display: 0, through: [at(0.42, 0.5), at(0.66, 0.2)])
    h.press("rectangle")
    h.drag(display: 0, through: [at(0.7, 0.1), at(0.94, 0.36)])
    h.press("marker")
    h.drag(display: 0, through: [at(0.06, 0.6), at(0.3, 0.61), at(0.5, 0.6)])
    h.press("text")
    let click = at(0.1, 0.8)
    h.mouseDown(display: 0, at: click)
    h.mouseUp(at: click)
    h.type("Look here")
    h.editorLineBreak()
    h.type("second line, 42%")
    let editor = h.editorFrame
    let editing = h.render(display: 0)
    h.editorReturn()
    let committed = h.render(display: 0)
    h.press("pencil")
    return (editing, committed, editor)
}

@MainActor
func runMain(width: CGFloat, height: CGFloat, scale: CGFloat, prefix: String, full: Bool) {
    let settings = makeSettings()
    defer { cleanUp(settings) }
    let image = makeDesktop(width: width, height: height, scale: scale)
    let display = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: width, height: height), scale: scale)
    let snapshot = DisplaySnapshot(display: display, image: image)
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)

    func noOverlap(_ h: OverlayHarness, _ label: String) {
        guard let frames = h.panelFrames(display: 0) else {
            check(false, "\(label): panels visible")
            return
        }
        check(!frames.tools.insetBy(dx: -3, dy: -3).intersects(frames.actions), "\(label): panels do not overlap")
        check(bounds.contains(frames.tools) && bounds.contains(frames.actions), "\(label): panels inside the display")
    }

    // 1. Nothing selected.
    let h1 = OverlayHarness(settings: settings, snapshots: [snapshot])
    if full {
        write(h1.render(display: 0), "\(prefix)01-empty.png")
        check(!h1.key(code: 8, characters: "c", modifiers: .command) || h1.finishCount == 0,
              "copy without a selection does nothing")
        check(h1.finishCount == 0, "no decision without a selection")
    }

    // 2. A selection with both panels.
    let h2 = OverlayHarness(settings: settings, snapshots: [snapshot])
    let s2 = CGRect(x: (width * 0.25).rounded(), y: (height * 0.24).rounded(),
                    width: (width * 0.45).rounded(), height: (height * 0.47).rounded())
    h2.drag(display: 0, through: [s2.origin, CGPoint(x: s2.midX, y: s2.midY), CGPoint(x: s2.maxX, y: s2.maxY)])
    check(h2.selection(display: 0) == s2, "\(prefix)selection is \(s2)")
    noOverlap(h2, "\(prefix)02")
    write(h2.render(display: 0), "\(prefix)02-selection.png")
    if full {
        check(h2.cursorName(display: 0, at: CGPoint(x: s2.midX, y: s2.midY)) == "openHand", "open hand inside")
        check(h2.cursorName(display: 0, at: s2.origin) == "resize-topLeft", "resize cursor on a handle")
        check(h2.cursorName(display: 0, at: CGPoint(x: 5, y: 5)) == "crosshair", "crosshair outside")
        if let frames = h2.panelFrames(display: 0) {
            check(h2.cursorName(display: 0, at: CGPoint(x: frames.tools.midX, y: frames.tools.midY)) == "arrow",
                  "arrow over the panels")
        }
        check(!h2.isEnabled("undo"), "undo disabled with nothing to undo")
        // During a selection drag the panels hide.
        h2.mouseDown(display: 0, at: CGPoint(x: s2.midX, y: s2.midY))
        h2.mouseDragged(to: CGPoint(x: s2.midX + 10, y: s2.midY + 10))
        check(h2.panelFrames(display: 0) == nil, "panels hidden while moving")
        h2.mouseUp(at: CGPoint(x: s2.midX, y: s2.midY))
        check(h2.selection(display: 0) == s2, "move back to the same place")
        // Arrow keys.
        h2.key(code: 124, characters: "", modifiers: [.option])
        check(h2.selection(display: 0)?.minX == s2.minX + 10, "option+right moves by 10")
        h2.key(code: 123, characters: "", modifiers: [.shift])
        check(h2.selection(display: 0)?.width == s2.width - 1, "shift+left shrinks by 1")
    }

    // 3. One of each tool, then 6. the composed result.
    let h3 = OverlayHarness(settings: settings, snapshots: [snapshot])
    h3.drag(display: 0, through: [s2.origin, CGPoint(x: s2.maxX, y: s2.maxY)])
    let drawn = drawEverything(h3, in: s2, prefix: prefix)
    check(h3.annotations.count == 6, "\(prefix)six annotations (got \(h3.annotations.count))")
    check(h3.tool == .pencil, "pencil active")
    check(h3.isEnabled("undo"), "undo enabled after drawing")
    write(h3.render(display: 0), "\(prefix)03-annotations.png")
    if full, let editing = drawn.editing, let committed = drawn.committed, let editor = drawn.editor {
        write(editing, "\(prefix)03b-text-editing.png")
        let area = editor.insetBy(dx: -6, dy: -6)
        let diff = differingPixels(editing, committed, in: area, scale: scale)
        print("     text editor vs render: \(diff.differ) differing pixels, \(diff.inked) inked pixels, editor \(editor)")
        check(diff.inked > 200 && diff.differ * 20 < diff.inked, "text lands where the editor showed it")
        if case .text(let string, let origin, _)? = h3.annotations.last(where: {
            if case .text = $0.shape { return true } else { return false }
        })?.shape {
            check(string == "Look here\nsecond line, 42%", "text content with a line break")
            check(origin == editor.origin, "text origin equals the editor origin")
        }
    }
    if let result = h3.result(action: .copy) {
        let px = ScreenGeometry.pixelRect(selection: s2, scale: scale, imageWidth: image.width, imageHeight: image.height)
        check(result.screenshot.image.width == Int(px.width) && result.screenshot.image.height == Int(px.height),
              "\(prefix)result is \(Int(px.width))x\(Int(px.height)) pixels")
        check(result.screenshot.scale == scale, "result scale")
        write(result.screenshot.image, "\(prefix)06-result.png")
    } else {
        check(false, "compose result")
    }
    if full {
        // Exactly one decision, whatever comes after it.
        check(h3.press("copy"), "copy button")
        h3.press("save")
        h3.key(code: 53, characters: "\u{1b}")
        check(h3.finishCount == 1 && h3.finishedAction == .some(.copy), "exactly one decision: copy")
    }

    // 4. A selection in the bottom right corner: panels fall back.
    let h4 = OverlayHarness(settings: settings, snapshots: [snapshot])
    let s4start = CGPoint(x: (width * 0.62).rounded(), y: (height * 0.55).rounded())
    h4.drag(display: 0, through: [s4start, CGPoint(x: width + 50, y: height + 50)])
    check(h4.selection(display: 0)?.maxX == width && h4.selection(display: 0)?.maxY == height,
          "\(prefix)selection touches the right and bottom edges")
    noOverlap(h4, "\(prefix)04")
    write(h4.render(display: 0), "\(prefix)04-edge.png")

    // 5. Whole display with Command-A.
    let h5 = OverlayHarness(settings: settings, snapshots: [snapshot])
    h5.key(code: 0, characters: "a", modifiers: .command)
    check(h5.selection(display: 0) == bounds, "\(prefix)command-A selects the display")
    noOverlap(h5, "\(prefix)05")
    write(h5.render(display: 0), "\(prefix)05-full.png")

    if !full {
        // A small selection in the corner, where the panels would collide.
        let h7 = OverlayHarness(settings: settings, snapshots: [snapshot])
        h7.drag(display: 0, through: [CGPoint(x: width - 160, y: height - 150), CGPoint(x: width, y: height)])
        noOverlap(h7, "\(prefix)07")
        write(h7.render(display: 0), "\(prefix)07-corner.png")
    }
}

@MainActor
func runLogicChecks() {
    let settings = makeSettings()
    defer { cleanUp(settings) }
    let scale: CGFloat = 2
    let a = DisplaySnapshot(display: DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 600, height: 400), scale: scale),
                            image: makeDesktop(width: 600, height: 400, scale: scale))
    let b = DisplaySnapshot(display: DisplayInfo(id: 2, frame: CGRect(x: 600, y: 0, width: 500, height: 300), scale: 1),
                            image: makeDesktop(width: 500, height: 300, scale: 1))
    let h = OverlayHarness(settings: settings, snapshots: [a, b])
    h.drag(display: 0, through: [CGPoint(x: 50, y: 50), CGPoint(x: 300, y: 250)])
    h.press("rectangle")
    h.drag(display: 0, through: [CGPoint(x: 80, y: 80), CGPoint(x: 200, y: 200)])
    check(h.annotations.count == 1, "rectangle drawn")
    // A plain click outside keeps the selection and the drawing.
    h.mouseDown(display: 0, at: CGPoint(x: 500, y: 350))
    h.mouseUp(at: CGPoint(x: 500, y: 350))
    check(h.selection(display: 0) == CGRect(x: 50, y: 50, width: 250, height: 200) && h.annotations.count == 1,
          "a click outside restores the selection and the drawings")
    // Handles still resize with a tool active.
    h.drag(display: 0, through: [CGPoint(x: 300, y: 250), CGPoint(x: 320, y: 270)])
    check(h.selection(display: 0) == CGRect(x: 50, y: 50, width: 270, height: 220), "handle resizes with a tool active")
    check(h.annotations.count == 1, "resizing keeps the drawings")
    // A selection on the other display replaces this one and the drawings.
    h.drag(display: 1, through: [CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 90)])
    check(h.selection(display: 0) == nil && h.selection(display: 1) != nil, "only one display has a selection")
    check(h.annotations.isEmpty && h.activeDisplay == 1, "new selection clears the drawings")
    // Clicking the active tool again turns it off.
    h.press("rectangle")
    check(h.tool == nil, "second click turns the tool off")
    // Text tool: Escape discards, empty text leaves nothing, shortcuts are off while editing.
    h.press("text")
    h.mouseDown(display: 1, at: CGPoint(x: 40, y: 40))
    h.mouseUp(at: CGPoint(x: 40, y: 40))
    check(h.isEditingText, "text editor opens")
    h.type("draft")
    check(!h.key(code: 8, characters: "c", modifiers: .command), "command-C is not taken while editing")
    h.editorEscape()
    check(!h.isEditingText && h.annotations.isEmpty, "escape discards the text being edited")
    h.mouseDown(display: 1, at: CGPoint(x: 40, y: 40))
    h.mouseUp(at: CGPoint(x: 40, y: 40))
    h.editorReturn()
    check(h.annotations.isEmpty, "empty text leaves nothing")
    h.mouseDown(display: 1, at: CGPoint(x: 40, y: 40))
    h.mouseUp(at: CGPoint(x: 40, y: 40))
    h.type("keep")
    h.mouseDown(display: 1, at: CGPoint(x: 70, y: 70)) // clicking elsewhere commits, and opens a new editor
    h.mouseUp(at: CGPoint(x: 70, y: 70))
    check(h.annotations.count == 1, "clicking elsewhere commits the text")
    h.editorEscape()
    // Colour goes to settings and to the next drawing.
    let blue = RGBAColor(red: 0, green: 0.4, blue: 1)
    h.setColor(blue)
    check(settings.drawingColor == blue, "colour stored in settings")
    h.press("line")
    h.drag(display: 1, through: [CGPoint(x: 20, y: 20), CGPoint(x: 80, y: 60)])
    check(h.annotations.last?.color == blue, "next drawing uses the new colour")
    check(h.key(code: 6, characters: "z", modifiers: .command) && h.annotations.count == 1, "command-Z undoes")
    // Actions and close.
    check(h.key(code: 1, characters: "s", modifiers: .command), "command-S taken")
    check(h.finishCount == 1 && h.finishedAction == .some(.quickSave), "command-S is quick save")
    let h2 = OverlayHarness(settings: settings, snapshots: [a, b])
    h2.key(code: 0, characters: "a", modifiers: .command, mouseDisplay: 1)
    check(h2.selection(display: 1) == CGRect(x: 0, y: 0, width: 500, height: 300), "command-A on the display under the mouse")
    if let result = h2.result(action: .print) {
        check(result.screenshot.image.width == 500 && result.screenshot.scale == 1, "result from the second display at scale 1")
    }
    h2.press("close")
    check(h2.finishCount == 1 && h2.finishedAction == .some(nil), "close cancels")

    // Key mapping.
    let cases: [(UInt16, String?, NSEvent.ModifierFlags, String)] = [
        (8, "c", .command, "copy"), (8, "\u{441}", .command, "copy"), (1, "s", .command, "quickSave"),
        (2, "d", .command, "upload"), (35, "p", .command, "print"), (6, "z", .command, "undo"),
        (7, "x", .command, "cancel"), (53, "\u{1b}", [], "cancel"), (0, "a", .command, "selectAll"),
        (124, "", [], "nudge(1,0)"), (126, "", [.option], "nudge(0,-10)"), (125, "", [.shift], "resize(0,1)"),
        (123, "", [.shift, .option], "resize(-10,0)"), (8, "c", [], "none"), (8, "c", [.command, .shift], "none"),
    ]
    for (code, chars, flags, expected) in cases {
        let got = OverlayHarness.keyCommandName(code: code, characters: chars, modifiers: flags)
        check(got == expected, "key \(code) \(flags.rawValue) -> \(expected) (got \(got))")
    }
}

