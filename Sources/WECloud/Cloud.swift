import Foundation
import WECore

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

    // One session for the whole app: sessions are expensive and this one keeps
    // no state worth isolating (no cookies, no cache, no credentials).
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }()

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSessionTransport.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudError.badResponse("Not an HTTP response")
        }
        return (data, http)
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
        switch self {
        case .notConfigured:
            return L("Google Drive upload is not set up in this build.")
        case .notSignedIn:
            return L("Not signed in to Google Drive.")
        case .signInCancelled:
            return L("Google sign-in was cancelled.")
        case .signInRejected:
            // The detail is for developers; the user only needs to retry.
            return L("Google sign-in failed. Please try again.")
        case let .server(status, message):
            let detail = ErrorText.sanitized(message)
            if detail.isEmpty {
                return String(format: L("Google Drive answered with error %d."), status)
            }
            return String(format: L("Google Drive answered with error %d: %@"), status, detail)
        case let .badResponse(detail):
            let clean = ErrorText.sanitized(detail)
            if clean.isEmpty { return L("Google sent an answer that could not be read.") }
            return String(format: L("Unexpected answer: %@"), clean)
        case let .sharingForbidden(message):
            let detail = ErrorText.sanitized(message)
            if detail.isEmpty {
                return L("The screenshot was uploaded, but it cannot be shared by link.")
            }
            return String(format: L("The screenshot was uploaded, but it cannot be shared by link: %@"), detail)
        case let .network(message):
            let detail = ErrorText.sanitized(message)
            if detail.isEmpty { return L("Could not reach Google.") }
            return String(format: L("Could not reach Google: %@"), detail)
        }
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
        OAuthClientConfig(
            clientID: clientID,
            clientSecret: clientSecret,
            scopes: ["https://www.googleapis.com/auth/drive.file"],
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
            revocationEndpoint: URL(string: "https://oauth2.googleapis.com/revoke")!
        )
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

/// Tokens in the login keychain, as one generic password item.
public final class KeychainTokenStore: TokenStore, @unchecked Sendable {
    private let keychain: KeychainStore
    private let account: String

    public init(keychain: KeychainStore = KeychainStore(), account: String = "oauth-tokens") {
        self.keychain = keychain
        self.account = account
    }

    public func load() throws -> OAuthTokens? {
        guard let json = try keychain.string(for: account), let data = json.data(using: .utf8) else {
            return nil
        }
        // An unreadable item (an older or damaged format) means "signed out":
        // the user signs in again instead of being stuck with an error.
        return try? TokenCoding.decoder.decode(OAuthTokens.self, from: data)
    }

    public func save(_ tokens: OAuthTokens) throws {
        let data = try TokenCoding.encoder.encode(tokens)
        try keychain.set(String(decoding: data, as: UTF8.self), for: account)
    }

    public func clear() throws {
        try keychain.set(nil, for: account)
    }
}

/// Tokens in memory, for tests.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: OAuthTokens?

    public init(_ tokens: OAuthTokens? = nil) {
        self.tokens = tokens
    }

    public func load() throws -> OAuthTokens? {
        lock.lock(); defer { lock.unlock() }
        return tokens
    }

    public func save(_ tokens: OAuthTokens) throws {
        lock.lock(); defer { lock.unlock() }
        self.tokens = tokens
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        tokens = nil
    }
}

/// Proof Key for Code Exchange (RFC 7636), method S256.
public enum PKCE {
    /// A new random code verifier: 43...128 characters of the unreserved set.
    public static func makeVerifier() -> String {
        // 64 random bytes give 86 base64url characters, well inside 43...128.
        Base64URL.encode(SecureRandom.bytes(64))
    }

    /// BASE64URL(SHA256(verifier)) without padding.
    public static func challenge(for verifier: String) -> String {
        Base64URL.encode(SHA256Digest.hash(Data(verifier.utf8)))
    }
}

/// Gives out a valid access token.
public protocol AccessTokenProviding: Sendable {
    func validAccessToken() async throws -> String

    /// Tells the provider that the server rejected this access token (401),
    /// so that the next validAccessToken does not hand out the same one.
    func invalidate(accessToken: String)
}

public extension AccessTokenProviding {
    func invalidate(accessToken: String) {}
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
