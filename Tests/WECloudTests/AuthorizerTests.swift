import Foundation
import XCTest
@testable import WECloud

final class PKCETests: XCTestCase {
    func testRFC7636AppendixBVector() {
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testVerifierLengthAndAlphabet() {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        for _ in 0..<20 {
            let verifier = PKCE.makeVerifier()
            XCTAssertTrue((43...128).contains(verifier.count), "length \(verifier.count)")
            XCTAssertTrue(verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
        }
    }

    func testVerifiersDiffer() {
        XCTAssertNotEqual(PKCE.makeVerifier(), PKCE.makeVerifier())
    }
}

final class AuthorizerTests: XCTestCase {
    private func makeAuthorizer(_ transport: MockTransport, _ store: TokenStore, _ clock: TestClock,
                                config: OAuthClientConfig = testConfig) -> GoogleAuthorizer {
        GoogleAuthorizer(config: config, transport: transport, store: store,
                         openURL: { _ in }, now: { clock.now })
    }

    func testGoogleConfig() {
        let config = OAuthClientConfig.google(clientID: "id", clientSecret: nil)
        XCTAssertEqual(config.scopes, ["https://www.googleapis.com/auth/drive.file"])
        XCTAssertEqual(config.authorizationEndpoint.absoluteString, "https://accounts.google.com/o/oauth2/v2/auth")
        XCTAssertEqual(config.tokenEndpoint.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertEqual(config.revocationEndpoint.absoluteString, "https://oauth2.googleapis.com/revoke")
    }

    func testAuthorizationURLParametersAndEncoding() throws {
        var config = testConfig
        config.clientID = "id+1 &x"
        config.scopes = ["https://www.googleapis.com/auth/drive.file", "openid"]
        let authorizer = makeAuthorizer(MockTransport(), InMemoryTokenStore(), TestClock(), config: config)
        let url = authorizer.authorizationURL(redirectURI: URL(string: "http://127.0.0.1:49152")!,
                                              state: "st/ate=1", codeChallenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "accounts.google.com")
        XCTAssertEqual(components.path, "/o/oauth2/v2/auth")

        let query = try XCTUnwrap(components.percentEncodedQuery)
        let fields = queryFields(query)
        XCTAssertEqual(fields["client_id"], "id+1 &x")
        XCTAssertEqual(fields["redirect_uri"], "http://127.0.0.1:49152")
        XCTAssertEqual(fields["response_type"], "code")
        XCTAssertEqual(fields["scope"], "https://www.googleapis.com/auth/drive.file openid")
        XCTAssertEqual(fields["state"], "st/ate=1")
        XCTAssertEqual(fields["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(fields["code_challenge_method"], "S256")
        XCTAssertEqual(fields["access_type"], "offline")
        XCTAssertEqual(fields["prompt"], "consent")
        XCTAssertEqual(fields.count, 9)

        // Reserved characters are encoded, so no value can spill into another.
        XCTAssertTrue(query.contains("client_id=id%2B1%20%26x"))
        XCTAssertTrue(query.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A49152"))
        XCTAssertTrue(query.contains("scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdrive.file%20openid"))
        XCTAssertTrue(query.contains("state=st%2Fate%3D1"))
    }

    func testExchangeSendsFormAndStoresTokens() async throws {
        let transport = MockTransport()
        transport.enqueue(200, #"{"access_token":"at-1","expires_in":3599,"refresh_token":"rt-1","token_type":"Bearer"}"#)
        let store = InMemoryTokenStore()
        let clock = TestClock()
        let authorizer = makeAuthorizer(transport, store, clock)

        let tokens = try await authorizer.exchange(code: "4/code+x", codeVerifier: "verifier-1",
                                                   redirectURI: URL(string: "http://127.0.0.1:50000")!)
        let expected = OAuthTokens(accessToken: "at-1", refreshToken: "rt-1",
                                   expiresAt: clock.now.addingTimeInterval(3599))
        XCTAssertEqual(tokens, expected)
        XCTAssertEqual(try store.load(), expected)
        XCTAssertTrue(authorizer.isSignedIn)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(request.url?.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(formFields(request.httpBody), [
            "grant_type": "authorization_code",
            "code": "4/code+x",
            "code_verifier": "verifier-1",
            "redirect_uri": "http://127.0.0.1:50000",
            "client_id": "client-123.apps.googleusercontent.com",
            "client_secret": "test-client-secret",
        ])
    }

    func testExchangeWithoutSecretLeavesItOut() async throws {
        let transport = MockTransport()
        transport.enqueue(200, #"{"access_token":"at-1","expires_in":3600,"refresh_token":"rt-1"}"#)
        var config = testConfig
        config.clientSecret = nil
        let authorizer = makeAuthorizer(transport, InMemoryTokenStore(), TestClock(), config: config)
        try await authorizer.exchange(code: "c", codeVerifier: "v", redirectURI: URL(string: "http://127.0.0.1:1")!)
        XCTAssertNil(formFields(transport.requests.first?.httpBody)["client_secret"])
    }

    func testExchangeErrorIsServerError() async {
        let transport = MockTransport()
        transport.enqueue(400, #"{"error":"invalid_grant","error_description":"Bad Request"}"#)
        let store = InMemoryTokenStore()
        let authorizer = makeAuthorizer(transport, store, TestClock())
        do {
            try await authorizer.exchange(code: "c", codeVerifier: "v", redirectURI: URL(string: "http://127.0.0.1:1")!)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CloudError, .server(status: 400, message: "Bad Request"))
        }
        XCTAssertNil(try store.load())
    }

    func testFreshTokenIsNotRefreshed() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore(OAuthTokens(accessToken: "at-old", refreshToken: "rt-1",
                                                   expiresAt: clock.now.addingTimeInterval(600)))
        let transport = MockTransport()
        let authorizer = makeAuthorizer(transport, store, clock)
        let token = try await authorizer.validAccessToken()
        XCTAssertEqual(token, "at-old")
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testRefreshNearExpiryKeepsOldRefreshToken() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore(OAuthTokens(accessToken: "at-old", refreshToken: "rt-1",
                                                   expiresAt: clock.now.addingTimeInterval(30)))
        let transport = MockTransport()
        transport.enqueue(200, #"{"access_token":"at-new","expires_in":3599,"token_type":"Bearer"}"#)
        let authorizer = makeAuthorizer(transport, store, clock)

        let token = try await authorizer.validAccessToken()
        XCTAssertEqual(token, "at-new")
        XCTAssertEqual(try store.load(), OAuthTokens(accessToken: "at-new", refreshToken: "rt-1",
                                                     expiresAt: clock.now.addingTimeInterval(3599)))
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertEqual(formFields(request.httpBody), [
            "grant_type": "refresh_token",
            "refresh_token": "rt-1",
            "client_id": "client-123.apps.googleusercontent.com",
            "client_secret": "test-client-secret",
        ])

        // Now fresh: no second request.
        _ = try await authorizer.validAccessToken()
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testRefreshTakesNewRefreshTokenWhenGiven() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore(OAuthTokens(accessToken: "a", refreshToken: "rt-1", expiresAt: clock.now))
        let transport = MockTransport()
        transport.enqueue(200, #"{"access_token":"b","expires_in":100,"refresh_token":"rt-2"}"#)
        _ = try await makeAuthorizer(transport, store, clock).validAccessToken()
        XCTAssertEqual(try store.load()?.refreshToken, "rt-2")
    }

    func testTenConcurrentCallersCauseOneRefresh() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore(OAuthTokens(accessToken: "at-old", refreshToken: "rt-1",
                                                   expiresAt: clock.now.addingTimeInterval(-10)))
        let transport = MockTransport(delay: 0.2)
        transport.enqueue(200, #"{"access_token":"at-new","expires_in":3599}"#)
        transport.enqueue(200, #"{"access_token":"at-second","expires_in":3599}"#)
        let authorizer = makeAuthorizer(transport, store, clock)

        let tokens = try await withThrowingTaskGroup(of: String.self) { group -> [String] in
            for _ in 0..<10 { group.addTask { try await authorizer.validAccessToken() } }
            var all: [String] = []
            for try await token in group { all.append(token) }
            return all
        }
        XCTAssertEqual(tokens.count, 10)
        XCTAssertEqual(Set(tokens), ["at-new"])
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testInvalidGrantClearsStoreAndThrowsNotSignedIn() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore(OAuthTokens(accessToken: "a", refreshToken: "rt-1", expiresAt: clock.now))
        let transport = MockTransport()
        transport.enqueue(400, #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#)
        let authorizer = makeAuthorizer(transport, store, clock)
        do {
            _ = try await authorizer.validAccessToken()
            XCTFail("expected notSignedIn")
        } catch {
            XCTAssertEqual(error as? CloudError, .notSignedIn)
        }
        XCTAssertNil(try store.load())
        XCTAssertFalse(authorizer.isSignedIn)
    }

    func testServerErrorOnRefreshKeepsStore() async throws {
        let clock = TestClock()
        let original = OAuthTokens(accessToken: "a", refreshToken: "rt-1", expiresAt: clock.now)
        let store = InMemoryTokenStore(original)
        let transport = MockTransport()
        transport.enqueue(500, #"{"error":"internal_failure","error_description":"Backend Error"}"#)
        let authorizer = makeAuthorizer(transport, store, clock)
        do {
            _ = try await authorizer.validAccessToken()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CloudError, .server(status: 500, message: "Backend Error"))
        }
        XCTAssertEqual(try store.load(), original)
    }

    func testNetworkFailureOnRefreshKeepsStore() async throws {
        let clock = TestClock()
        let original = OAuthTokens(accessToken: "a", refreshToken: "rt-1", expiresAt: clock.now)
        let store = InMemoryTokenStore(original)
        let transport = MockTransport()
        transport.enqueue(.fail(URLError(.notConnectedToInternet)))
        do {
            _ = try await makeAuthorizer(transport, store, clock).validAccessToken()
            XCTFail("expected an error")
        } catch {
            guard case .network = error as? CloudError else { return XCTFail("got \(error)") }
        }
        XCTAssertEqual(try store.load(), original)
    }

    func testNoTokensThrowsNotSignedIn() async {
        let authorizer = makeAuthorizer(MockTransport(), InMemoryTokenStore(), TestClock())
        XCTAssertFalse(authorizer.isSignedIn)
        do {
            _ = try await authorizer.validAccessToken()
            XCTFail("expected notSignedIn")
        } catch {
            XCTAssertEqual(error as? CloudError, .notSignedIn)
        }
    }

    func testSignOutRevokesAndClears() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore(OAuthTokens(accessToken: "at-1", refreshToken: "rt-1", expiresAt: clock.now))
        let transport = MockTransport()
        transport.enqueue(200, "{}")
        let authorizer = makeAuthorizer(transport, store, clock)
        await authorizer.signOut()
        XCTAssertNil(try store.load())
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://oauth2.googleapis.com/revoke")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(formFields(request.httpBody), ["token": "rt-1"])
    }

    func testSignOutClearsEvenWhenRevokeFails() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore(OAuthTokens(accessToken: "at-1", refreshToken: nil, expiresAt: clock.now))
        let transport = MockTransport()
        transport.enqueue(.fail(URLError(.timedOut)))
        await makeAuthorizer(transport, store, clock).signOut()
        XCTAssertNil(try store.load())
        XCTAssertEqual(formFields(transport.requests.first?.httpBody), ["token": "at-1"])
    }
}
