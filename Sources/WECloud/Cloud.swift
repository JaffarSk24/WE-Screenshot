import Foundation
import WECore

// CONTRACT STUB. The public declarations are fixed; the bodies are placeholders.
//
// Nothing here touches the user interface. Everything that talks to the
// network goes through HTTPTransport, so tests replace the network.

/// The network, as far as this module is concerned.
public protocol HTTPTransport: Sendable {
    /// Sends the request (with its httpBody) and returns the body and the
    /// response, whatever the status code. Throws only when there is no
    /// HTTP response at all (no network, timeout).
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The real network: URLSession with an ephemeral configuration (no cookies,
/// no cache on disk).
public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        fatalError("stub")
    }
}

public enum CloudError: Error, Equatable, LocalizedError {
    /// No OAuth client ID is configured.
    case notConfigured
    /// There are no stored tokens, or Google no longer accepts the refresh token.
    case notSignedIn
    /// The user closed the consent page, denied access, or the answer did not
    /// arrive in time.
    case signInCancelled
    /// The answer to the sign-in did not match the request (wrong state).
    case signInRejected(String)
    /// Google answered with an error: HTTP status and its message.
    case server(status: Int, message: String)
    /// The answer could not be understood.
    case badResponse(String)
    /// The file was uploaded but could not be shared by link (for example a
    /// Google Workspace policy forbids public links).
    case sharingForbidden(String)
    case network(String)

    public var errorDescription: String? {
        fatalError("stub")
    }
}

/// An OAuth 2.0 client for installed apps.
public struct OAuthClientConfig: Equatable, Sendable {
    public var clientID: String
    /// Google issues a "secret" for desktop clients and expects it in token
    /// requests; it is not confidential in an installed app.
    public var clientSecret: String?
    public var scopes: [String]
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var revocationEndpoint: URL

    public init(clientID: String, clientSecret: String?, scopes: [String],
                authorizationEndpoint: URL, tokenEndpoint: URL, revocationEndpoint: URL) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scopes = scopes
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.revocationEndpoint = revocationEndpoint
    }

    /// Google's endpoints with the only scope the app uses:
    /// https://www.googleapis.com/auth/drive.file
    public static func google(clientID: String, clientSecret: String?) -> OAuthClientConfig {
        fatalError("stub")
    }
}

public struct OAuthTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    /// When the access token stops working.
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String?, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

/// Where the tokens are kept between launches.
public protocol TokenStore: Sendable {
    func load() throws -> OAuthTokens?
    func save(_ tokens: OAuthTokens) throws
    func clear() throws
}

/// Small secrets in the login keychain: generic password items of one service.
public final class KeychainStore: @unchecked Sendable {
    public static let defaultService = "sk.whiteeagles.screenshot.google"

    public init(service: String = KeychainStore.defaultService) {
        fatalError("stub")
    }

    /// The stored value, nil when there is none.
    public func string(for account: String) throws -> String? { fatalError("stub") }

    /// Stores the value; nil or an empty string removes the item.
    public func set(_ value: String?, for account: String) throws { fatalError("stub") }
}

/// Tokens in the login keychain, as one generic password item.
public final class KeychainTokenStore: TokenStore, @unchecked Sendable {
    public init(keychain: KeychainStore = KeychainStore(), account: String = "oauth-tokens") {
        fatalError("stub")
    }

    public func load() throws -> OAuthTokens? { fatalError("stub") }
    public func save(_ tokens: OAuthTokens) throws { fatalError("stub") }
    public func clear() throws { fatalError("stub") }
}

/// Tokens in memory, for tests.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    public init(_ tokens: OAuthTokens? = nil) {
        fatalError("stub")
    }

    public func load() throws -> OAuthTokens? { fatalError("stub") }
    public func save(_ tokens: OAuthTokens) throws { fatalError("stub") }
    public func clear() throws { fatalError("stub") }
}

/// Proof Key for Code Exchange (RFC 7636), method S256.
public enum PKCE {
    /// A new random code verifier: 43...128 characters of the unreserved set.
    public static func makeVerifier() -> String {
        fatalError("stub")
    }

    /// BASE64URL(SHA256(verifier)) without padding.
    public static func challenge(for verifier: String) -> String {
        fatalError("stub")
    }
}

/// A one-shot HTTP listener on 127.0.0.1 that receives the OAuth redirect.
public final class LoopbackRedirectListener: @unchecked Sendable {
    public init() {
        fatalError("stub")
    }

    /// Starts listening on a free port of the loopback interface only and
    /// returns the redirect URI to send to Google: "http://127.0.0.1:PORT".
    public func start() async throws -> URL {
        fatalError("stub")
    }

    /// Waits for the browser's request to the redirect URI and returns its
    /// query parameters ("code", "state", "error"...). The browser gets a small
    /// page saying the window can be closed. Requests for other paths (such as
    /// /favicon.ico) are answered with 404 and do not end the wait.
    /// Throws CloudError.signInCancelled after `timeout` seconds.
    public func waitForRedirect(timeout: TimeInterval) async throws -> [String: String] {
        fatalError("stub")
    }

    public func stop() {
        fatalError("stub")
    }
}

/// Gives out a valid access token.
public protocol AccessTokenProviding: Sendable {
    func validAccessToken() async throws -> String
}

/// Sign-in with Google for installed apps: the system browser, a loopback
/// redirect and PKCE. Keeps the tokens in the TokenStore and refreshes them.
public final class GoogleAuthorizer: AccessTokenProviding, @unchecked Sendable {
    /// `openURL` opens the consent page in the user's browser. `now` is the clock.
    public init(config: OAuthClientConfig, transport: HTTPTransport, store: TokenStore,
                openURL: @escaping @Sendable (URL) -> Void,
                now: @escaping @Sendable () -> Date = { Date() }) {
        fatalError("stub")
    }

    /// True when tokens are stored (they may still turn out to be revoked).
    public var isSignedIn: Bool { fatalError("stub") }

    /// The consent page URL for a redirect URI, state and PKCE challenge.
    /// Asks for offline access so that a refresh token is issued.
    public func authorizationURL(redirectURI: URL, state: String, codeChallenge: String) -> URL {
        fatalError("stub")
    }

    /// The whole sign-in: starts the listener, opens the browser, waits for the
    /// redirect (at most `timeout` seconds), checks the state, exchanges the
    /// code for tokens and stores them.
    @discardableResult
    public func signIn(timeout: TimeInterval = 300) async throws -> OAuthTokens {
        fatalError("stub")
    }

    /// Exchanges an authorisation code for tokens and stores them.
    @discardableResult
    public func exchange(code: String, codeVerifier: String, redirectURI: URL) async throws -> OAuthTokens {
        fatalError("stub")
    }

    /// The stored access token, refreshed first when it expires within a
    /// minute. Throws CloudError.notSignedIn when there are no tokens or the
    /// refresh token was rejected (invalid_grant); the stored tokens are then
    /// cleared.
    public func validAccessToken() async throws -> String {
        fatalError("stub")
    }

    /// Revokes the tokens at Google (best effort) and clears the store.
    public func signOut() async {
        fatalError("stub")
    }
}

public struct UploadResult: Equatable, Sendable {
    public let fileID: String
    /// The page to share: anyone with the link can view the image.
    public let viewURL: URL
    /// A URL that returns the image bytes themselves.
    public let directImageURL: URL

    public init(fileID: String, viewURL: URL, directImageURL: URL) {
        self.fileID = fileID
        self.viewURL = viewURL
        self.directImageURL = directImageURL
    }
}

public protocol ScreenshotUploading: Sendable {
    func upload(data: Data, fileName: String, mimeType: String) async throws -> UploadResult
}

/// Uploads into the folder "WE Screenshot" of the user's Google Drive and
/// opens the file to anyone with the link (reader).
public final class GoogleDriveUploader: ScreenshotUploading, @unchecked Sendable {
    /// `cachedFolderID` and `storeFolderID` read and write the remembered ID of
    /// the folder, so it is not searched for on every upload.
    public init(tokens: AccessTokenProviding, transport: HTTPTransport,
                folderName: String = "WE Screenshot",
                cachedFolderID: @escaping @Sendable () -> String?,
                storeFolderID: @escaping @Sendable (String?) -> Void) {
        fatalError("stub")
    }

    /// Steps: make sure the folder exists (the cached ID, else search among the
    /// files the app created, else create it; a cached folder that is gone or
    /// in the trash is created again), upload the file into it, add the
    /// permission "anyone with the link can view", return the links.
    /// A 401 answer makes one more attempt with a fresh token.
    public func upload(data: Data, fileName: String, mimeType: String) async throws -> UploadResult {
        fatalError("stub")
    }

    /// Name or e-mail of the account the tokens belong to, for display.
    public func accountLabel() async throws -> String {
        fatalError("stub")
    }
}
