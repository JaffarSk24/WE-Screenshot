import CoreGraphics
import Foundation
import WECore

// CONTRACT STUB. The public declarations are fixed; the bodies are placeholders.

public enum CaptureError: Error, Equatable {
    /// The app has no Screen Recording permission.
    case permissionDenied
    case noDisplays
    case failed(String)
}

public protocol ScreenCapturing {
    /// One snapshot per connected display, taken at the display's native pixel
    /// resolution, without the mouse cursor. The primary display comes first.
    func captureAllDisplays() async throws -> [DisplaySnapshot]
}

/// Captures with ScreenCaptureKit.
public final class ScreenCaptureService: ScreenCapturing {
    public init() {}

    public func captureAllDisplays() async throws -> [DisplaySnapshot] {
        fatalError("stub")
    }
}

/// The Screen Recording permission (System Settings > Privacy & Security).
public enum ScreenRecordingPermission {
    /// True when the app may capture the screen. Does not show any prompt.
    public static var isGranted: Bool {
        fatalError("stub")
    }

    /// Asks macOS to show its permission prompt (shown once per app); returns
    /// the state right after the call.
    @discardableResult
    public static func request() -> Bool {
        fatalError("stub")
    }

    /// Opens the Screen Recording page of System Settings.
    public static func openSystemSettings() {
        fatalError("stub")
    }
}
