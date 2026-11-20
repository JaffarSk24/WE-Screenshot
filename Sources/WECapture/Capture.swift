import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import WECore

public enum CaptureError: Error, Equatable {
    /// The app has no Screen Recording permission.
    case permissionDenied
    case noDisplays
    /// The system capture service did not answer in time.
    case notResponding
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
        // Without the permission ScreenCaptureKit would either fail late or
        // return wallpaper only frames, so refuse early with a clear error.
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }
        do {
            let screens = await MainActor.run { currentScreens() }
            // The system capture service (replayd) can stop answering after
            // days of uptime; without a limit the app would wait forever.
            let content = try await withTimeout(seconds: 6) {
                try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            }
            let targets = matchDisplays(content.displays, to: screens)
            guard !targets.isEmpty else { throw CaptureError.noDisplays }

            let snapshots = try await withThrowingTaskGroup(of: DisplaySnapshot.self) { group -> [DisplaySnapshot] in
                for target in targets {
                    group.addTask {
                        let image = try await captureDisplay(target.display, info: target.info)
                        return DisplaySnapshot(display: target.info, image: image)
                    }
                }
                var result: [DisplaySnapshot] = []
                for try await snapshot in group {
                    result.append(snapshot)
                }
                return result
            }
            let order = orderedDisplayIDs(snapshots.map { $0.display.id }, primary: CGMainDisplayID())
            return order.compactMap { id in snapshots.first { $0.display.id == id } }
        } catch {
            throw mapCaptureError(error)
        }
    }
}

/// The Screen Recording permission (System Settings > Privacy & Security).
public enum ScreenRecordingPermission {
    /// True when the app may capture the screen. Does not show any prompt.
    public static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Asks macOS to show its permission prompt (shown once per app); returns
    /// the state right after the call.
    @discardableResult
    public static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Opens the Screen Recording page of System Settings.
    public static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
