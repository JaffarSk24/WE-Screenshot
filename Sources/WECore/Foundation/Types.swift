import CoreGraphics
import Foundation

// Shared value types. Every module depends on these, so their shape is fixed:
// add members in extensions elsewhere, do not change what is declared here.

/// Looks a string up in the app bundle's Localizable.strings. The key is the
/// English text itself.
public func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: .main, comment: "")
}

/// A colour that can be stored in settings and compared in tests.
/// Components are in the sRGB colour space, 0...1.
public struct RGBAColor: Codable, Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// "#RRGGBB" or "#RRGGBBAA"; nil when the text is not a hex colour.
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        if text.count == 6 {
            self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                      blue: Double(value & 0xFF) / 255, alpha: 1)
        } else {
            self.init(red: Double((value >> 24) & 0xFF) / 255, green: Double((value >> 16) & 0xFF) / 255,
                      blue: Double((value >> 8) & 0xFF) / 255, alpha: Double(value & 0xFF) / 255)
        }
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }

    public func withAlpha(_ value: Double) -> RGBAColor {
        RGBAColor(red: red, green: green, blue: blue, alpha: value)
    }

    /// The default drawing colour.
    public static let red = RGBAColor(red: 1, green: 0, blue: 0)
}

/// One connected display at the moment of capture.
public struct DisplayInfo: Equatable, Sendable {
    /// CGDirectDisplayID.
    public let id: UInt32
    /// The display's frame in global AppKit coordinates: points, origin at the
    /// bottom left corner of the primary display, y grows up (NSScreen.frame).
    public let frame: CGRect
    /// Pixels per point (NSScreen.backingScaleFactor): 2 on Retina displays.
    public let scale: CGFloat

    public init(id: UInt32, frame: CGRect, scale: CGFloat) {
        self.id = id
        self.frame = frame
        self.scale = scale
    }
}

/// A frozen picture of one display. The overlay shows it full screen and the
/// final screenshot is cropped out of it.
public struct DisplaySnapshot {
    public let display: DisplayInfo
    /// The whole display. Its pixel size is display.frame.size * display.scale
    /// (it may differ by a pixel after rounding; never assume exact equality).
    public let image: CGImage

    public init(display: DisplayInfo, image: CGImage) {
        self.display = display
        self.image = image
    }
}

/// File format of saved and uploaded screenshots.
public enum ImageFormat: String, Codable, CaseIterable, Sendable {
    case png
    case jpeg

    public var fileExtension: String { self == .png ? "png" : "jpg" }
    public var mimeType: String { self == .png ? "image/png" : "image/jpeg" }
}

/// What the user chose to do with the selected area.
public enum ScreenshotAction: String, CaseIterable, Sendable {
    case copy
    /// Save through the Save panel.
    case save
    /// Save without a panel into the folder used last (Desktop at first).
    case quickSave
    case upload
    case searchSimilar
    case print
}

/// The final picture: the selection with the drawings on it.
public struct FinishedScreenshot {
    public let image: CGImage
    /// Pixels per point of the display it was taken from.
    public let scale: CGFloat

    public init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
    }
}
