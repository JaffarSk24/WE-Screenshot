import Foundation
import XCTest
@testable import WECloud

/// Set once the background wait has finished, to prove it was still running.
final class DoneFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }
    func set() { lock.lock(); done = true; lock.unlock() }
}

final class ListenerTests: XCTestCase {
    private func get(_ url: URL, method: String = "GET") async throws -> (Int, String, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        let (data, response) = try await browserSession().data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return (http.statusCode, String(decoding: data, as: UTF8.self), http)
    }

    func testRedirectIsAnsweredAndParametersDecoded() async throws {
        let listener = LoopbackRedirectListener()
        defer { listener.stop() }
        let uri = try await listener.start()
        XCTAssertEqual(uri.scheme, "http")
        XCTAssertEqual(uri.host, "127.0.0.1")
        XCTAssertNotNil(uri.port)
        XCTAssertNotEqual(uri.port, 0)
        XCTAssertEqual(uri.path, "")

        let flag = DoneFlag()
        let wait = Task { () throws -> [String: String] in
            defer { flag.set() }
            return try await listener.waitForRedirect(timeout: 10)
        }

        let (faviconStatus, _, _) = try await get(URL(string: "\(uri.absoluteString)/favicon.ico")!)
        XCTAssertEqual(faviconStatus, 404)
        let (postStatus, _, _) = try await get(URL(string: "\(uri.absoluteString)/?code=x&state=y")!, method: "POST")
        XCTAssertEqual(postStatus, 405)
        let (bareStatus, _, _) = try await get(URL(string: "\(uri.absoluteString)/")!)
        XCTAssertEqual(bareStatus, 404)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(flag.isDone, "a request for another path must not end the wait")

        let target = URL(string: "\(uri.absoluteString)/?code=abc&state=xyz&scope=a+b%2Fc")!
        let (status, body, response) = try await get(target)
        XCTAssertEqual(status, 200)
        XCTAssertTrue(response.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/html") ?? false)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Connection")?.lowercased(), "close")
        XCTAssertTrue(body.contains("You can close this window and return to WE Screenshot."))
        XCTAssertFalse(body.contains("http://"), "the page must not load anything")
        XCTAssertFalse(body.contains("https://"), "the page must not load anything")

        let parameters = try await wait.value
        XCTAssertEqual(parameters["code"], "abc")
        XCTAssertEqual(parameters["state"], "xyz")
        XCTAssertEqual(parameters["scope"], "a b/c")
    }

    func testErrorRedirectGetsErrorPage() async throws {
        let listener = LoopbackRedirectListener()
        defer { listener.stop() }
        let uri = try await listener.start()
        let wait = Task { try await listener.waitForRedirect(timeout: 10) }
        let (status, body, _) = try await get(URL(string: "\(uri.absoluteString)/?error=access_denied&state=s")!)
        XCTAssertEqual(status, 200)
        XCTAssertTrue(body.contains("Sign-in was not completed. You can close this window."))
        let parameters = try await wait.value
        XCTAssertEqual(parameters["error"], "access_denied")
    }

    func testTimeoutThrowsSignInCancelled() async throws {
        let listener = LoopbackRedirectListener()
        defer { listener.stop() }
        _ = try await listener.start()
        let started = Date()
        do {
            _ = try await listener.waitForRedirect(timeout: 0.3)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? CloudError, .signInCancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testTaskCancellationEndsTheWait() async throws {
        let listener = LoopbackRedirectListener()
        defer { listener.stop() }
        _ = try await listener.start()
        let wait = Task { try await listener.waitForRedirect(timeout: 30) }
        try await Task.sleep(nanoseconds: 100_000_000)
        wait.cancel()
        do {
            _ = try await wait.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? CloudError, .signInCancelled)
        }
    }

    func testStopEndsTheWaitAndCloses() async throws {
        let listener = LoopbackRedirectListener()
        let uri = try await listener.start()
        let wait = Task { try await listener.waitForRedirect(timeout: 30) }
        try await Task.sleep(nanoseconds: 100_000_000)
        listener.stop()
        listener.stop()
        do {
            _ = try await wait.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? CloudError, .signInCancelled)
        }

        // The port must stop accepting connections; closing is asynchronous,
        // so allow it a moment.
        var reachable = true
        for _ in 0..<20 {
            do {
                _ = try await get(URL(string: "\(uri.absoluteString)/?code=a&state=b")!)
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                reachable = false
                break
            }
        }
        XCTAssertFalse(reachable, "the listener must not answer after stop")
    }

    func testNotReachableOverIPv6Loopback() async throws {
        let listener = LoopbackRedirectListener()
        defer { listener.stop() }
        let uri = try await listener.start()
        let port = try XCTUnwrap(uri.port)
        do {
            _ = try await get(URL(string: "http://[::1]:\(port)/?code=a&state=b")!)
            XCTFail("the listener must be bound to 127.0.0.1 only")
        } catch {
            // Expected: nothing listens on ::1.
        }
    }

    func testStopBeforeStartIsHarmless() {
        let listener = LoopbackRedirectListener()
        listener.stop()
        listener.stop()
    }
}

final class SignInTests: XCTestCase {
    /// Plays the browser: reads redirect_uri and state from the consent URL
    /// and requests the redirect with the given query.
    private func browser(query: @escaping @Sendable (_ state: String) -> String,
                         seen: SeenURL) -> @Sendable (URL) -> Void {
        return { url in
            seen.set(url)
            let fields = queryFields(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
            guard let redirect = fields["redirect_uri"], let state = fields["state"] else { return }
            Task.detached {
                let target = URL(string: "\(redirect)/?\(query(state))")!
                _ = try? await browserSession().data(from: target)
            }
        }
    }

    func testFullSignInSucceeds() async throws {
        let transport = MockTransport()
        transport.enqueue(200, #"{"access_token":"at-1","expires_in":3600,"refresh_token":"rt-1"}"#)
        let store = InMemoryTokenStore()
        let clock = TestClock()
        let seen = SeenURL()
        let authorizer = GoogleAuthorizer(config: testConfig, transport: transport, store: store,
                                          openURL: browser(query: { "code=4%2Fabc&state=\($0)" }, seen: seen),
                                          now: { clock.now })
        let tokens = try await authorizer.signIn(timeout: 10)
        XCTAssertEqual(tokens.accessToken, "at-1")
        XCTAssertEqual(try store.load(), tokens)

        let consent = try XCTUnwrap(seen.url)
        let consentFields = queryFields(URLComponents(url: consent, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        let state = try XCTUnwrap(consentFields["state"])
        XCTAssertGreaterThanOrEqual(state.count, 22, "at least 128 bits")

        XCTAssertEqual(transport.requests.count, 1)
        let body = formFields(transport.requests.first?.httpBody)
        XCTAssertEqual(body["code"], "4/abc")
        XCTAssertEqual(body["redirect_uri"], consentFields["redirect_uri"])
        let verifier = try XCTUnwrap(body["code_verifier"])
        XCTAssertEqual(PKCE.challenge(for: verifier), consentFields["code_challenge"])
    }

    func testWrongStateIsRejectedWithoutTokenRequest() async throws {
        let transport = MockTransport()
        transport.enqueue(200, #"{"access_token":"at-1","expires_in":3600}"#)
        let store = InMemoryTokenStore()
        let authorizer = GoogleAuthorizer(config: testConfig, transport: transport, store: store,
                                          openURL: browser(query: { _ in "code=abc&state=forged" }, seen: SeenURL()))
        do {
            try await authorizer.signIn(timeout: 10)
            XCTFail("expected signInRejected")
        } catch {
            guard case .signInRejected = error as? CloudError else { return XCTFail("got \(error)") }
        }
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertNil(try store.load())
    }

    func testMissingStateIsRejected() async throws {
        let transport = MockTransport()
        let authorizer = GoogleAuthorizer(config: testConfig, transport: transport, store: InMemoryTokenStore(),
                                          openURL: browser(query: { _ in "code=abc" }, seen: SeenURL()))
        do {
            try await authorizer.signIn(timeout: 10)
            XCTFail("expected signInRejected")
        } catch {
            guard case .signInRejected = error as? CloudError else { return XCTFail("got \(error)") }
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testAccessDeniedIsCancelled() async throws {
        let transport = MockTransport()
        let authorizer = GoogleAuthorizer(config: testConfig, transport: transport, store: InMemoryTokenStore(),
                                          openURL: browser(query: { "error=access_denied&state=\($0)" }, seen: SeenURL()))
        do {
            try await authorizer.signIn(timeout: 10)
            XCTFail("expected signInCancelled")
        } catch {
            XCTAssertEqual(error as? CloudError, .signInCancelled)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testNoAnswerTimesOut() async throws {
        let authorizer = GoogleAuthorizer(config: testConfig, transport: MockTransport(), store: InMemoryTokenStore(),
                                          openURL: { _ in })
        do {
            try await authorizer.signIn(timeout: 0.3)
            XCTFail("expected signInCancelled")
        } catch {
            XCTAssertEqual(error as? CloudError, .signInCancelled)
        }
    }

    func testEmptyClientIDIsNotConfigured() async {
        let authorizer = GoogleAuthorizer(config: .google(clientID: "", clientSecret: nil), transport: MockTransport(),
                                          store: InMemoryTokenStore(), openURL: { _ in XCTFail("no browser") })
        do {
            try await authorizer.signIn(timeout: 1)
            XCTFail("expected notConfigured")
        } catch {
            XCTAssertEqual(error as? CloudError, .notConfigured)
        }
    }

    func testEveryAttemptUsesNewStateAndVerifier() async throws {
        let seen = SeenURL()
        let authorizer = GoogleAuthorizer(config: testConfig, transport: MockTransport(), store: InMemoryTokenStore(),
                                          openURL: { seen.set($0) })
        _ = try? await authorizer.signIn(timeout: 0.1)
        let first = try XCTUnwrap(seen.url)
        _ = try? await authorizer.signIn(timeout: 0.1)
        let second = try XCTUnwrap(seen.url)
        let a = queryFields(URLComponents(url: first, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        let b = queryFields(URLComponents(url: second, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        XCTAssertNotEqual(a["state"], b["state"])
        XCTAssertNotEqual(a["code_challenge"], b["code_challenge"])
    }
}

final class SeenURL: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URL?
    var url: URL? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ url: URL) { lock.lock(); value = url; lock.unlock() }
}
