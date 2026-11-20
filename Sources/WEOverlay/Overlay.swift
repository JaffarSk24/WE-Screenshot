import AppKit
import WEAnnotate
import WECore

// CONTRACT STUB. The public declarations are fixed; the bodies are placeholders.

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
    public init(settings: SettingsStore) {
        fatalError("stub")
    }

    /// True while the overlay is on screen.
    public var isActive: Bool {
        fatalError("stub")
    }

    /// Shows the overlay on every display. `completion` is called exactly once
    /// on the main thread, after the overlay windows are gone: with the result
    /// when the user picked an action, with nil when the user cancelled.
    /// Calling begin while active does nothing.
    public func begin(snapshots: [DisplaySnapshot], completion: @escaping (OverlayResult?) -> Void) {
        fatalError("stub")
    }

    /// Closes the overlay as if the user pressed Escape.
    public func cancel() {
        fatalError("stub")
    }
}
