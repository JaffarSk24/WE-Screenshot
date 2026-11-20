import AppKit
import WEAnnotate
import WECloud
import WECore

/// Google account state and uploads, with all the user interface around them.
@MainActor
public final class CloudCoordinator {
    private let settings: SettingsStore
    private let notifier: Notifier
    private let keychain = KeychainStore()
    private static let secretAccount = "client-secret"

    private struct Stack {
        let clientID: String
        let secret: String
        let authorizer: GoogleAuthorizer
        let uploader: GoogleDriveUploader
    }

    private var stack: Stack?
    /// nil outer value: not read from the keychain yet.
    private var secretCache: String??

    public init(settings: SettingsStore, notifier: Notifier) {
        self.settings = settings
        self.notifier = notifier
    }

    /// Called on the main thread whenever sign-in state or activity changes.
    public var onStateChange: (() -> Void)?

    /// Called when the user asks for an upload but no OAuth client is set up
    /// yet and agrees to open the settings; the app shows its Settings window.
    public var onNeedsSetup: (() -> Void)?

    /// True when the user has entered the client ID and secret of a Google
    /// OAuth client (the app ships without one).
    public var isConfigured: Bool {
        ActionRules.normalized(settings.googleClientID) != nil && ActionRules.normalized(clientSecret) != nil
    }

    /// The stored client secret (kept in the keychain); nil when not set.
    public var clientSecret: String? {
        if let cached = secretCache { return cached }
        let value = ActionRules.normalized((try? keychain.string(for: Self.secretAccount)) ?? nil)
        secretCache = .some(value)
        return value
    }

    /// Stores the user's OAuth client: the ID in the settings, the secret in
    /// the keychain. Changing either one signs the user out.
    public func setClient(id: String?, secret: String?) {
        let newID = ActionRules.normalized(id)
        let newSecret = ActionRules.normalized(secret)
        let changed = ActionRules.clientChanged(oldID: settings.googleClientID, newID: newID,
                                                oldSecret: clientSecret, newSecret: newSecret)
        guard changed else { return }
        // Tokens belong to the old client: forget them before the new one is in place.
        try? KeychainTokenStore().clear()
        settings.googleAccountLabel = nil
        settings.driveFolderID = nil
        settings.googleClientID = newID
        try? keychain.set(newSecret, for: Self.secretAccount)
        secretCache = .some(newSecret)
        stack = nil
        onStateChange?()
    }

    public var isSignedIn: Bool {
        guard let stack = currentStack() else { return false }
        return stack.authorizer.isSignedIn
    }

    /// True while an upload or a sign-in is running.
    public private(set) var isBusy = false {
        didSet { if isBusy != oldValue { onStateChange?() } }
    }

    private func currentStack() -> Stack? {
        guard let id = ActionRules.normalized(settings.googleClientID), let secret = clientSecret else { return nil }
        if let stack, stack.clientID == id, stack.secret == secret { return stack }
        let transport = URLSessionTransport()
        let authorizer = GoogleAuthorizer(config: .google(clientID: id, clientSecret: secret),
                                          transport: transport, store: KeychainTokenStore(),
                                          openURL: { NSWorkspace.shared.open($0) })
        let settings = self.settings
        let uploader = GoogleDriveUploader(tokens: authorizer, transport: transport,
                                           cachedFolderID: { settings.driveFolderID },
                                           storeFolderID: { settings.driveFolderID = $0 })
        let built = Stack(clientID: id, secret: secret, authorizer: authorizer, uploader: uploader)
        stack = built
        return built
    }

    /// Opens the browser for Google sign-in and waits for the answer. Errors
    /// are shown to the user here; returns whether the user is signed in now.
    @discardableResult
    public func signIn() async -> Bool {
        guard !isBusy else { return isSignedIn }
        isBusy = true
        defer { isBusy = false }
        return await performSignIn()
    }

    /// Revokes the tokens at Google and forgets them.
    public func signOut() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await currentStack()?.authorizer.signOut()
        // Also covers the case without a client: nothing stays behind.
        try? KeychainTokenStore().clear()
        settings.googleAccountLabel = nil
        settings.driveFolderID = nil
        onStateChange?()
    }

    /// Uploads the screenshot (signing in first when needed), makes it viewable
    /// by link, copies the link to the clipboard and shows a notification.
    /// Returns the link, or nil after an error (which was shown to the user).
    @discardableResult
    public func upload(_ screenshot: FinishedScreenshot) async -> URL? {
        guard let result = await performUpload(screenshot) else { return nil }
        let link = result.viewURL
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(link.absoluteString, forType: .string)
        notifier.show(title: L("Link copied"), body: link.absoluteString, url: link)
        if settings.openLinkAfterUpload { NSWorkspace.shared.open(link) }
        return link
    }

    /// Uploads the screenshot and returns a URL of the image itself that an
    /// image search service can fetch; nil after an error (shown to the user).
    public func uploadForSearch(_ screenshot: FinishedScreenshot) async -> URL? {
        await performUpload(screenshot)?.directImageURL
    }

    // MARK: Internals

    private func performSignIn() async -> Bool {
        guard let stack = currentStack() else {
            askToSetUp()
            return false
        }
        do {
            _ = try await stack.authorizer.signIn()
        } catch CloudError.signInCancelled {
            return false
        } catch {
            Alerts.inform(L("Google sign-in did not work."), error.localizedDescription)
            return false
        }
        // The label is only for display; a failure here is not an error.
        if let label = try? await stack.uploader.accountLabel() {
            settings.googleAccountLabel = label
        }
        onStateChange?()
        return true
    }

    private func askToSetUp() {
        AppFocus.activate()
        let alert = NSAlert()
        alert.messageText = L("Google Drive is not set up yet.")
        alert.informativeText = L("Enter the ID and secret of your own Google OAuth client in Settings first.")
        alert.addButton(withTitle: L("Open Settings"))
        alert.addButton(withTitle: L("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { onNeedsSetup?() }
    }

    private func performUpload(_ screenshot: FinishedScreenshot) async -> UploadResult? {
        guard !isBusy else { return nil }
        isBusy = true
        defer { isBusy = false }

        if !isConfigured || !isSignedIn {
            guard await performSignIn() else { return nil }
        }
        guard let stack = currentStack() else { return nil }

        let file: (data: Data, fileName: String)
        do {
            file = try ScreenshotEncoding.fileData(for: screenshot, settings: settings)
        } catch {
            Alerts.inform(L("The screenshot was not uploaded."), error.localizedDescription)
            return nil
        }
        let mime = settings.imageFormat.mimeType

        var retried = false
        while true {
            do {
                return try await stack.uploader.upload(data: file.data, fileName: file.fileName, mimeType: mime)
            } catch CloudError.notSignedIn where !retried {
                // Tokens were revoked: sign in once more and try once more.
                retried = true
                guard await performSignIn() else { return nil }
            } catch let error as CloudError {
                if case .sharingForbidden = error {
                    Alerts.inform(L("Uploaded, but not shared."), error.localizedDescription)
                } else {
                    Alerts.inform(L("The screenshot was not uploaded."), error.localizedDescription)
                }
                return nil
            } catch {
                Alerts.inform(L("The screenshot was not uploaded."), error.localizedDescription)
                return nil
            }
        }
    }
}
