import Foundation

/// Typed access to the app's preferences. One instance is shared by the whole
/// app; tests pass their own UserDefaults suite.
public final class SettingsStore: @unchecked Sendable {
    /// Posted on the main queue after any value changes.
    public static let didChangeNotification = Notification.Name("WEScreenshotSettingsDidChange")

    public static let shared = SettingsStore(defaults: .standard)

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private func changed() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
            }
        }
    }

    private func decoded<T: Decodable>(_ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func encode<T: Encodable>(_ value: T?, _ key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        changed()
    }

    private func bool(_ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    /// The global shortcut that starts a capture.
    public var captureHotKey: KeyCombo {
        get { decoded("captureHotKey") ?? .defaultCapture }
        set { encode(newValue, "captureHotKey") }
    }

    public var imageFormat: ImageFormat {
        get { ImageFormat(rawValue: defaults.string(forKey: "imageFormat") ?? "") ?? .png }
        set { defaults.set(newValue.rawValue, forKey: "imageFormat"); changed() }
    }

    /// 0.1...1, used for JPEG only.
    public var jpegQuality: Double {
        get {
            let value = defaults.object(forKey: "jpegQuality") == nil ? 0.9 : defaults.double(forKey: "jpegQuality")
            return min(1, max(0.1, value))
        }
        set { defaults.set(newValue, forKey: "jpegQuality"); changed() }
    }

    /// The colour the drawing tools start with; the last one the user picked.
    public var drawingColor: RGBAColor {
        get { decoded("drawingColor") ?? .red }
        set { encode(newValue, "drawingColor") }
    }

    /// The folder of the last save: the Save panel opens in it and quick save
    /// writes into it. nil means the Desktop.
    public var lastSaveDirectory: String? {
        get { defaults.string(forKey: "lastSaveDirectory") }
        set { defaults.set(newValue, forKey: "lastSaveDirectory"); changed() }
    }

    /// Open the link in the browser after an upload (the link is always copied).
    public var openLinkAfterUpload: Bool {
        get { bool("openLinkAfterUpload", default: false) }
        set { defaults.set(newValue, forKey: "openLinkAfterUpload"); changed() }
    }

    public var autoCheckUpdates: Bool {
        get { bool("autoCheckUpdates", default: true) }
        set { defaults.set(newValue, forKey: "autoCheckUpdates"); changed() }
    }

    public var skippedVersion: String? {
        get { defaults.string(forKey: "skippedVersion") }
        set { defaults.set(newValue, forKey: "skippedVersion"); changed() }
    }

    /// Set after the first start, when the login item was registered once.
    public var didFirstLaunch: Bool {
        get { bool("didFirstLaunch", default: false) }
        set { defaults.set(newValue, forKey: "didFirstLaunch"); changed() }
    }

    /// Save Retina screenshots at half size (one pixel per point).
    public var downscaleRetina: Bool {
        get { bool("downscaleRetina", default: false) }
        set { defaults.set(newValue, forKey: "downscaleRetina"); changed() }
    }

    /// Client ID of the user's own Google OAuth client (type "Desktop app"),
    /// typed in Settings. The app ships without one. The matching client
    /// secret is kept in a private file of the app, not here.
    public var googleClientID: String? {
        get { nonEmpty(defaults.string(forKey: "googleClientID")) }
        set { defaults.set(newValue, forKey: "googleClientID"); changed() }
    }

    /// ID of the "WE Screenshot" folder in the user's Google Drive, once known.
    public var driveFolderID: String? {
        get { nonEmpty(defaults.string(forKey: "driveFolderID")) }
        set { defaults.set(newValue, forKey: "driveFolderID"); changed() }
    }

    /// Name or e-mail of the signed-in Google account, for display only.
    public var googleAccountLabel: String? {
        get { nonEmpty(defaults.string(forKey: "googleAccountLabel")) }
        set { defaults.set(newValue, forKey: "googleAccountLabel"); changed() }
    }

    private func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
