import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import WECore

/// What AppKit knows about one screen, read on the main thread.
struct ScreenDescription: Equatable {
    let id: UInt32
    let frame: CGRect
    let scale: CGFloat
}

struct CaptureTarget {
    let display: SCDisplay
    let info: DisplayInfo
}

/// Must run on the main thread: NSScreen is not safe to read elsewhere.
@MainActor
func currentScreens() -> [ScreenDescription] {
    let key = NSDeviceDescriptionKey("NSScreenNumber")
    return NSScreen.screens.compactMap { screen in
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
        return ScreenDescription(id: number.uint32Value, frame: screen.frame, scale: screen.backingScaleFactor)
    }
}

/// Pairs every ScreenCaptureKit display with its NSScreen; displays AppKit
/// does not know about are skipped.
func matchDisplays(_ displays: [SCDisplay], to screens: [ScreenDescription]) -> [CaptureTarget] {
    displays.compactMap { display in
        guard let info = displayInfo(for: display.displayID, screens: screens) else { return nil }
        return CaptureTarget(display: display, info: info)
    }
}

func displayInfo(for id: UInt32, screens: [ScreenDescription]) -> DisplayInfo? {
    guard let screen = screens.first(where: { $0.id == id }) else { return nil }
    return DisplayInfo(id: id, frame: screen.frame, scale: screen.scale)
}

/// Primary display first, the rest by ascending display ID.
func orderedDisplayIDs(_ ids: [UInt32], primary: UInt32) -> [UInt32] {
    ids.sorted { lhs, rhs in
        if lhs == primary { return rhs != primary }
        if rhs == primary { return false }
        return lhs < rhs
    }
}

/// Pixel dimensions for a display of `points` size at `scale`, at least 1x1.
func pixelSize(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
    let safeScale = scale > 0 ? scale : 1
    let width = Int((points.width * safeScale).rounded())
    let height = Int((points.height * safeScale).rounded())
    return (max(width, 1), max(height, 1))
}

/// The ScreenCaptureKit code for "the user declined" (SCStreamErrorUserDeclined).
let userDeclinedErrorCode = -3801

func mapCaptureError(_ error: Error) -> CaptureError {
    if let captureError = error as? CaptureError {
        return captureError
    }
    let nsError = error as NSError
    if nsError.domain == SCStreamErrorDomain && nsError.code == userDeclinedErrorCode {
        return .permissionDenied
    }
    return .failed(nsError.localizedDescription)
}

func makeConfiguration(width: Int, height: Int) -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    configuration.width = width
    configuration.height = height
    configuration.showsCursor = false
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.scalesToFit = false
    // Only the first frame is used; a short queue keeps memory low.
    configuration.queueDepth = 3
    if #available(macOS 14.0, *) {
        configuration.captureResolution = .best
    }
    return configuration
}

func captureDisplay(_ display: SCDisplay, info: DisplayInfo) async throws -> CGImage {
    let filter = SCContentFilter(display: display, excludingWindows: [])
    if #available(macOS 14.0, *) {
        let scale = CGFloat(filter.pointPixelScale)
        let size = pixelSize(points: filter.contentRect.size, scale: scale > 0 ? scale : info.scale)
        let configuration = makeConfiguration(width: size.width, height: size.height)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
    let size = pixelSize(points: info.frame.size, scale: info.scale)
    let configuration = makeConfiguration(width: size.width, height: size.height)
    let grabber = SingleFrameGrabber(filter: filter, configuration: configuration, displayID: info.id)
    return try await grabber.grab(timeout: 5)
}
