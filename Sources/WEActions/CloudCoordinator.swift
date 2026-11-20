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
    /// The running Google sign-in (the browser is open), if any.
    private var signInTask: Task<Result<OAuthTokens, Error>, Never>?
    /// Bumped by setClient and signOut: a sign-in started before is stale.
    private var authEpoch = 0
    /// Identifies the operation that owns isBusy; cancelling releases it.
    private var busyToken = 0

    public init(settings: SettingsStore, notifier: Notifier) {
        self.settings = settings
        self.notifier = notifier
    }

    /// Called on the main thread whenever sign-in state or activity changes.
    public var onStateChange: (() -> Void)?

    /// Called when the user asks for an upload but no OAuth client is set up
    /// yet and agrees to open the settings; the app shows its Settings window.
    public var onNeedsSetup: (() -> Void)?

    /// True when the app bundle carries its own Google OAuth client (the
    /// Info.plist keys WEGoogleClientID and WEGoogleClientSecret, both set).
    public var hasBuiltInClient: Bool { Self.builtInClient != nil }

    /// True when the user has stored their own client ID and secret.
    public var usesOwnClient: Bool { ownClient != nil }

    /// True when a client is available: the user's own or the built-in one.
    public var isConfigured: Bool { effectiveClient != nil }

    private static var builtInClient: (id: String, secret: String)? {
        let id = Bundle.main.object(forInfoDictionaryKey: "WEGoogleClientID") as? String
        let secret = Bundle.main.object(forInfoDictionaryKey: "WEGoogleClientSecret") as? String
        guard let id = ActionRules.normalized(id), let secret = ActionRules.normalized(secret) else { return nil }
        return (id, secret)
    }

    private var ownClient: (id: String, secret: String)? {
        guard let id = ActionRules.normalized(settings.googleClientID),
              let secret = ActionRules.normalized(clientSecret) else { return nil }
        return (id, secret)
    }

    /// The client used for sign-in and uploads: the user's own, else the built-in one.
    private var effectiveClient: (id: String, secret: String)? { ownClient ?? Self.builtInClient }

    /// The stored client secret (kept in the keychain); nil when not set.
    public var clientSecret: String? {
        if let cached = secretCache { return cached }
        // Only a definite answer is cached (a secret or "no item"); on an
        // error the next access tries again.
        guard let stored = try? keychain.string(for: Self.secretAccount) else {
            return nil
        }
        let value = ActionRules.normalized(stored)
        secretCache = .some(value)
        return value
    }

    /// Stores the user's own OAuth client: the ID in the settings, the secret in
    /// the keychain. Empty values remove it, which switches back to the built-in
    /// client. A change of the client in use signs the user out.
    public func setClient(id: String?, secret: String?) {
        let newID = ActionRules.normalized(id)
        let newSecret = ActionRules.normalized(secret)
        let changed = ActionRules.clientChanged(oldID: settings.googleClientID, newID: newID,
                                                oldSecret: clientSecret, newSecret: newSecret)
        guard changed else { return }
        let oldEffective = effectiveClient
        // The secret goes first, while a failure still changes nothing else.
        do {
            try keychain.set(newSecret, for: Self.secretAccount)
        } catch {
            Alerts.inform(L("The client secret could not be saved to the keychain."), error.localizedDescription)
            return
        }
        settings.googleClientID = newID
        secretCache = .some(newSecret)
        let newEffective = effectiveClient
        if oldEffective?.id != newEffective?.id || oldEffective?.secret != newEffective?.secret {
            // A pending sign-in belongs to the old client.
            authEpoch += 1
            cancelSignIn()
            // Tokens belong to the old client: forget them.
            try? KeychainTokenStore().clear()
            settings.googleAccountLabel = nil
            settings.driveFolderID = nil
            stack = nil
        }
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

    /// Cancels a sign-in that waits for the browser; isBusy falls back to
    /// false at once. Does nothing when no sign-in is running.
    public func cancelSignIn() {
        guard let task = signInTask else { return }
        signInTask = nil
        task.cancel()
        busyToken += 1
        isBusy = false
    }

    private func beginBusy() -> Int {
        busyToken += 1
        isBusy = true
        return busyToken
    }

    private func endBusy(_ token: Int) {
        if busyToken == token { isBusy = false }
    }

    private func currentStack() -> Stack? {
        guard let (id, secret) = effectiveClient else { return nil }
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
        let token = beginBusy()
        defer { endBusy(token) }
        return await performSignIn()
    }

    /// Revokes the tokens at Google and forgets them.
    public func signOut() async {
        authEpoch += 1
        cancelSignIn()
        guard !isBusy else { return }
        let token = beginBusy()
        defer { endBusy(token) }
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
        let epoch = authEpoch
        let task = Task { () -> Result<OAuthTokens, Error> in
            do { return .success(try await stack.authorizer.signIn()) } catch { return .failure(error) }
        }
        signInTask = task
        let result = await task.value
        if signInTask == task { signInTask = nil }
        // The client changed or the user signed out meanwhile: whatever this
        // attempt stored belongs to a client that is no longer in use.
        if epoch != authEpoch {
            if signInTask == nil {
                try? KeychainTokenStore().clear()
                settings.googleAccountLabel = nil
            }
            return false
        }
        switch result {
        case .success:
            break
        case .failure(let error):
            if error is CancellationError { return false }
            if case CloudError.signInCancelled = error { return false }
            Alerts.inform(L("Google sign-in did not work."), error.localizedDescription)
            return false
        }
        settings.googleAccountLabel = nil
        // The label is only for display; a failure here is not an error.
        if let label = try? await stack.uploader.accountLabel(), epoch == authEpoch {
            settings.googleAccountLabel = label
        }
        onStateChange?()
        return true
    }

    private func askToSetUp() {
        AppFocus.activate()
        let alert = NSAlert()
        alert.messageText = L("Google Drive is not set up yet.")
        alert.informativeText = L("This build has no Google sign-in set up. You can enter a Google OAuth client in Settings.")
        alert.addButton(withTitle: L("Open Settings"))
        alert.addButton(withTitle: L("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { onNeedsSetup?() }
    }

    private func performUpload(_ screenshot: FinishedScreenshot) async -> UploadResult? {
        guard !isBusy else { return nil }
        let token = beginBusy()
        defer { endBusy(token) }

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
