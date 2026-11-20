import AppKit
import WEAnnotate
import WECloud
import WECore

// CONTRACT STUB. The public declarations are fixed; the bodies are placeholders.

/// User notifications (UNUserNotificationCenter).
public final class Notifier: NSObject {
    public override init() {
        super.init()
    }

    /// Asks for the permission to show notifications (once) and becomes the
    /// notification centre delegate so banners show while the app is active.
    public func start() {
        fatalError("stub")
    }

    /// Shows a banner. When `url` is given, clicking the banner opens it.
    public func show(title: String, body: String, url: URL?) {
        fatalError("stub")
    }
}

/// Google account state and uploads, with all the user interface around them.
@MainActor
public final class CloudCoordinator {
    public init(settings: SettingsStore, notifier: Notifier) {
        fatalError("stub")
    }

    /// Called on the main thread whenever sign-in state or activity changes.
    public var onStateChange: (() -> Void)?

    /// Called when the user asks for an upload but no OAuth client is set up
    /// yet and agrees to open the settings; the app shows its Settings window.
    public var onNeedsSetup: (() -> Void)?

    /// True when the user has entered the client ID and secret of a Google
    /// OAuth client (the app ships without one).
    public var isConfigured: Bool { fatalError("stub") }

    /// The stored client secret (kept in the keychain); nil when not set.
    public var clientSecret: String? { fatalError("stub") }

    /// Stores the user's OAuth client: the ID in the settings, the secret in
    /// the keychain. Changing either one signs the user out.
    public func setClient(id: String?, secret: String?) {
        fatalError("stub")
    }

    public var isSignedIn: Bool { fatalError("stub") }

    /// True while an upload or a sign-in is running.
    public var isBusy: Bool { fatalError("stub") }

    /// Opens the browser for Google sign-in and waits for the answer. Errors
    /// are shown to the user here; returns whether the user is signed in now.
    @discardableResult
    public func signIn() async -> Bool {
        fatalError("stub")
    }

    /// Revokes the tokens at Google and forgets them.
    public func signOut() async {
        fatalError("stub")
    }

    /// Uploads the screenshot (signing in first when needed), makes it viewable
    /// by link, copies the link to the clipboard and shows a notification.
    /// Returns the link, or nil after an error (which was shown to the user).
    @discardableResult
    public func upload(_ screenshot: FinishedScreenshot) async -> URL? {
        fatalError("stub")
    }

    /// Uploads the screenshot and returns a URL of the image itself that an
    /// image search service can fetch; nil after an error (shown to the user).
    public func uploadForSearch(_ screenshot: FinishedScreenshot) async -> URL? {
        fatalError("stub")
    }
}

/// Carries out the action the user picked in the overlay.
@MainActor
public final class ScreenshotActions {
    public init(settings: SettingsStore, cloud: CloudCoordinator, notifier: Notifier) {
        fatalError("stub")
    }

    public func perform(_ action: ScreenshotAction, on screenshot: FinishedScreenshot) {
        fatalError("stub")
    }
}

/// Self-update from GitHub Releases.
@MainActor
public final class Updater {
    public init(settings: SettingsStore) {
        fatalError("stub")
    }

    /// Text for the menu while an update is being downloaded; nil otherwise.
    public private(set) var status: String?
    public var onStatusChange: (() -> Void)?

    /// CFBundleShortVersionString of the running app.
    public static var currentVersion: String { fatalError("stub") }

    /// Starts (or restarts, after the setting changed) the automatic checks:
    /// a minute after start, then every 24 hours, when the setting is on.
    public func start() {
        fatalError("stub")
    }

    /// Checks now. With userInitiated the result is always shown, including
    /// "you have the latest version" and errors.
    public func check(userInitiated: Bool) async {
        fatalError("stub")
    }
}
