import Foundation
import WECore

/// Sign-in with Google for installed apps: the system browser, a loopback
/// redirect and PKCE. Keeps the tokens in the TokenStore and refreshes them.
public final class GoogleAuthorizer: AccessTokenProviding, @unchecked Sendable {
    /// Refresh when the access token has less than this left.
    static let refreshMargin: TimeInterval = 60
    /// Used when Google leaves out expires_in, which it does not normally do.
    static let defaultLifetime: TimeInterval = 3600

    private let config: OAuthClientConfig
    private let transport: HTTPTransport
    private let store: TokenStore
    private let openURL: @Sendable (URL) -> Void
    private let now: @Sendable () -> Date

    // Guards `refreshTask`. The store is read under it as well, so that the
    // decision "fresh enough or refresh" is never made on stale tokens.
    private let lock = NSLock()
    private var refreshTask: Task<OAuthTokens, Error>?

    /// `openURL` opens the consent page in the user's browser. `now` is the clock.
    public init(config: OAuthClientConfig, transport: HTTPTransport, store: TokenStore,
                openURL: @escaping @Sendable (URL) -> Void,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config
        self.transport = transport
        self.store = store
        self.openURL = openURL
        self.now = now
    }

    /// True when tokens are stored (they may still turn out to be revoked).
    public var isSignedIn: Bool {
        ((try? store.load()) ?? nil) != nil
    }

    /// The consent page URL for a redirect URI, state and PKCE challenge.
    /// Asks for offline access so that a refresh token is issued.
    public func authorizationURL(redirectURI: URL, state: String, codeChallenge: String) -> URL {
        let pairs: [(String, String)] = [
            ("client_id", config.clientID),
            ("redirect_uri", redirectURI.absoluteString),
            ("response_type", "code"),
            ("scope", config.scopes.joined(separator: " ")),
            ("state", state),
            ("code_challenge", codeChallenge),
            ("code_challenge_method", "S256"),
            ("access_type", "offline"),
            ("prompt", "consent"),
        ]
        var components = URLComponents(url: config.authorizationEndpoint, resolvingAgainstBaseURL: false)
            ?? URLComponents()
        let existing = components.percentEncodedQuery.map { $0.isEmpty ? "" : $0 + "&" } ?? ""
        components.percentEncodedQuery = existing + FormEncoding.encode(pairs)
        return components.url ?? config.authorizationEndpoint
    }

    /// The whole sign-in: starts the listener, opens the browser, waits for the
    /// redirect (at most `timeout` seconds), checks the state, exchanges the
    /// code for tokens and stores them.
    @discardableResult
    public func signIn(timeout: TimeInterval = 300) async throws -> OAuthTokens {
        guard !config.clientID.isEmpty else { throw CloudError.notConfigured }

        // Fresh secrets for every attempt, so an answer to an earlier attempt
        // can never complete this one.
        let state = SecureRandom.token(byteCount: 32)
        let verifier = PKCE.makeVerifier()
        let listener = LoopbackRedirectListener()

        let redirectURI: URL
        let parameters: [String: String]
        do {
            redirectURI = try await listener.start()
            try Task.checkCancellation()
            openURL(authorizationURL(redirectURI: redirectURI, state: state,
                                     codeChallenge: PKCE.challenge(for: verifier)))
            parameters = try await listener.waitForRedirect(timeout: timeout)
            listener.stop()
        } catch is CancellationError {
            listener.stop()
            throw CloudError.signInCancelled
        } catch {
            listener.stop()
            throw error
        }

        if parameters["error"] != nil {
            throw CloudError.signInCancelled
        }
        // The state is checked before anything else is done with the answer:
        // a redirect that does not carry our state was not caused by us.
        guard let returnedState = parameters["state"], constantTimeEquals(returnedState, state) else {
            throw CloudError.signInRejected("The sign-in answer did not match the request.")
        }
        guard let code = parameters["code"], !code.isEmpty else {
            throw CloudError.badResponse("No authorisation code in the answer")
        }
        return try await exchange(code: code, codeVerifier: verifier, redirectURI: redirectURI)
    }

    /// Exchanges an authorisation code for tokens and stores them.
    @discardableResult
    public func exchange(code: String, codeVerifier: String, redirectURI: URL) async throws -> OAuthTokens {
        var pairs: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("code_verifier", codeVerifier),
            ("redirect_uri", redirectURI.absoluteString),
            ("client_id", config.clientID),
        ]
        if let secret = config.clientSecret, !secret.isEmpty { pairs.append(("client_secret", secret)) }

        let (data, response) = try await postForm(config.tokenEndpoint, pairs)
        guard isSuccess(response) else {
            throw CloudError.server(status: response.statusCode,
                                    message: JSONBody.googleMessage(data, status: response.statusCode))
        }
        let tokens = try parseTokens(data, previousRefreshToken: nil)
        try store.save(tokens)
        return tokens
    }

    /// The stored access token, refreshed first when it expires within a
    /// minute. Throws CloudError.notSignedIn when there are no tokens or the
    /// refresh token was rejected (invalid_grant); the stored tokens are then
    /// cleared.
    public func validAccessToken() async throws -> String {
        switch try nextStep() {
        case let .fresh(token):
            return token
        case let .wait(task):
            return try await task.value.accessToken
        }
    }

    private enum Step {
        case fresh(String)
        case wait(Task<OAuthTokens, Error>)
    }

    /// Decides under the lock whether the stored token is good enough or a
    /// refresh is needed. Every caller that arrives while a refresh runs gets
    /// the same task, so there is only one refresh request at a time.
    private func nextStep() throws -> Step {
        lock.lock(); defer { lock.unlock() }
        if let running = refreshTask { return .wait(running) }
        guard let tokens = try store.load() else { throw CloudError.notSignedIn }
        if tokens.expiresAt.timeIntervalSince(now()) > GoogleAuthorizer.refreshMargin {
            return .fresh(tokens.accessToken)
        }
        let task = Task { [self] () async throws -> OAuthTokens in
            defer { refreshFinished() }
            return try await refresh(tokens)
        }
        refreshTask = task
        return .wait(task)
    }

    private func refreshFinished() {
        lock.lock(); defer { lock.unlock() }
        refreshTask = nil
    }

    /// Revokes the tokens at Google (best effort) and clears the store.
    public func signOut() async {
        let tokens = (try? store.load()) ?? nil
        if let token = tokens?.refreshToken ?? tokens?.accessToken, !token.isEmpty {
            // Revoking the refresh token also ends its access tokens. The
            // result does not matter: the local copy goes away either way.
            _ = try? await postForm(config.revocationEndpoint, [("token", token)])
        }
        try? store.clear()
    }

    /// Google rejected this access token with 401: mark it as expired so that
    /// the next validAccessToken refreshes it instead of handing it out again.
    public func invalidate(accessToken: String) {
        lock.lock(); defer { lock.unlock() }
        guard var tokens = (try? store.load()) ?? nil,
              constantTimeEquals(tokens.accessToken, accessToken) else { return }
        tokens.expiresAt = .distantPast
        try? store.save(tokens)
    }

    // MARK: - Private

    private func refresh(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        guard let refreshToken = tokens.refreshToken, !refreshToken.isEmpty else {
            try? store.clear()
            throw CloudError.notSignedIn
        }
        var pairs: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", config.clientID),
        ]
        if let secret = config.clientSecret, !secret.isEmpty { pairs.append(("client_secret", secret)) }

        let (data, response) = try await postForm(config.tokenEndpoint, pairs)
        guard isSuccess(response) else {
            let code = JSONBody.object(data)?["error"] as? String
            if code == "invalid_grant" {
                // The refresh token was revoked or expired: only a new
                // sign-in helps, so the useless tokens are removed.
                try? store.clear()
                throw CloudError.notSignedIn
            }
            throw CloudError.server(status: response.statusCode,
                                    message: JSONBody.googleMessage(data, status: response.statusCode))
        }
        let fresh = try parseTokens(data, previousRefreshToken: refreshToken)
        try store.save(fresh)
        return fresh
    }

    private func parseTokens(_ data: Data, previousRefreshToken: String?) throws -> OAuthTokens {
        guard let json = JSONBody.object(data),
              let access = json["access_token"] as? String, !access.isEmpty else {
            throw CloudError.badResponse("No access token in the answer")
        }
        let lifetime: TimeInterval
        if let seconds = json["expires_in"] as? NSNumber {
            lifetime = seconds.doubleValue
        } else if let text = json["expires_in"] as? String, let seconds = Double(text) {
            lifetime = seconds
        } else {
            lifetime = GoogleAuthorizer.defaultLifetime
        }
        let newRefresh = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return OAuthTokens(accessToken: access,
                           refreshToken: newRefresh ?? previousRefreshToken,
                           expiresAt: now().addingTimeInterval(lifetime))
    }

    private func postForm(_ url: URL, _ pairs: [(String, String)]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(FormEncoding.encode(pairs).utf8)
        do {
            return try await transport.send(request)
        } catch {
            throw networkError(error)
        }
    }
}
