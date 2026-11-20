import Foundation
import Network
import XCTest
@testable import WECloud

struct TimedOut: Error {}

/// Runs `operation` but gives up after `seconds`, even when the operation
/// ignores cancellation (a task group would wait for it and hang the test).
func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                              _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let once = Once()
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        Task {
            do {
                let value = try await operation()
                if once.claim() { continuation.resume(returning: value) }
            } catch {
                if once.claim() { continuation.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if once.claim() { continuation.resume(throwing: TimedOut()) }
        }
    }
}

/// Polls `condition` until it holds or `seconds` pass.
func waitUntil(_ seconds: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
               _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline {
            XCTFail("condition not met in time", file: file, line: line)
            throw TimedOut()
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// Answers every request at once, except refresh requests, which are held
/// until the test releases them. That is how a slow refresh looks.
final class GatedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Void, Never>?
    private var released = false
    private var refreshArrived = false
    private let answer: @Sendable (_ grantType: String?, _ url: URL) -> (Int, String)

    init(answer: @escaping @Sendable (_ grantType: String?, _ url: URL) -> (Int, String)) {
        self.answer = answer
    }

    var refreshIsWaiting: Bool {
        lock.lock(); defer { lock.unlock() }
        return refreshArrived
    }

    func releaseRefresh() {
        lock.lock()
        released = true
        let pending = waiting
        waiting = nil
        lock.unlock()
        pending?.resume()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let grant = formFields(request.httpBody)["grant_type"]
        if grant == "refresh_token" {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                refreshArrived = true
                if released {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiting = continuation
                    lock.unlock()
                }
            }
        }
        let (status, body) = answer(grant, request.url!)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        return (Data(body.utf8), response)
    }
}

/// Answers the folder check at once and holds every other request for five
/// seconds, which a cancelled task cuts short.
final class SlowUploadTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false

    var uploadStarted: Bool {
        lock.lock(); defer { lock.unlock() }
        return started
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var body = #"{"id":"F1","trashed":false}"#
        if request.httpMethod != "GET" {
            lock.lock(); started = true; lock.unlock()
            try await Task.sleep(nanoseconds: 5_000_000_000)
            body = #"{"id":"FILE1"}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        return (Data(body.utf8), response)
    }
}

final class RefreshRaceTests: XCTestCase {
    private let redirect = URL(string: "http://127.0.0.1:1")!

    private func setUp(refreshAnswer: (Int, String)) -> (GatedTransport, InMemoryTokenStore, GoogleAuthorizer) {
        let clock = TestClock()
        let store = InMemoryTokenStore(OAuthTokens(accessToken: "at-A", refreshToken: "rt-A", expiresAt: clock.now))
        let transport = GatedTransport { grant, url in
            if url.absoluteString.hasSuffix("/revoke") { return (200, "{}") }
            if grant == "authorization_code" {
                return (200, #"{"access_token":"at-B","expires_in":3600,"refresh_token":"rt-B"}"#)
            }
            return refreshAnswer
        }
        let authorizer = GoogleAuthorizer(config: testConfig, transport: transport, store: store,
                                          openURL: { _ in }, now: { clock.now })
        return (transport, store, authorizer)
    }

    private let goodRefresh = (200, #"{"access_token":"at-A2","expires_in":3600,"refresh_token":"rt-A"}"#)

    func testSignOutDuringRefreshDiscardsTheRefresh() async throws {
        let (transport, store, authorizer) = setUp(refreshAnswer: goodRefresh)
        defer { transport.releaseRefresh() }
        let refresh = Task { try await authorizer.validAccessToken() }
        try await waitUntil { transport.refreshIsWaiting }

        await authorizer.signOut()
        transport.releaseRefresh()
        do {
            _ = try await withTimeout(5) { try await refresh.value }
            XCTFail("expected notSignedIn")
        } catch {
            XCTAssertEqual(error as? CloudError, .notSignedIn)
        }
        XCTAssertNil(try store.load())
        XCTAssertFalse(authorizer.isSignedIn)
    }

    func testNewSignInDuringRefreshKeepsTheNewTokens() async throws {
        let (transport, store, authorizer) = setUp(refreshAnswer: goodRefresh)
        defer { transport.releaseRefresh() }
        let refresh = Task { try await authorizer.validAccessToken() }
        try await waitUntil { transport.refreshIsWaiting }

        await authorizer.signOut()
        try await authorizer.exchange(code: "c", codeVerifier: "v", redirectURI: redirect)
        transport.releaseRefresh()
        let token = try await withTimeout(5) { try await refresh.value }
        XCTAssertEqual(token, "at-B")
        XCTAssertEqual(try store.load()?.refreshToken, "rt-B")
        XCTAssertEqual(try store.load()?.accessToken, "at-B")
    }

    func testInvalidGrantForAnOldRefreshDoesNotWipeTheNewSignIn() async throws {
        let (transport, store, authorizer) = setUp(
            refreshAnswer: (400, #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#))
        defer { transport.releaseRefresh() }
        let refresh = Task { try await authorizer.validAccessToken() }
        try await waitUntil { transport.refreshIsWaiting }

        await authorizer.signOut()
        try await authorizer.exchange(code: "c", codeVerifier: "v", redirectURI: redirect)
        transport.releaseRefresh()
        let token = try await withTimeout(5) { try await refresh.value }
        XCTAssertEqual(token, "at-B")
        XCTAssertEqual(try store.load()?.refreshToken, "rt-B")
    }

    func testCallerAfterNewSignInDoesNotJoinTheOldRefresh() async throws {
        let (transport, _, authorizer) = setUp(refreshAnswer: goodRefresh)
        defer { transport.releaseRefresh() }
        let refresh = Task { try await authorizer.validAccessToken() }
        try await waitUntil { transport.refreshIsWaiting }

        try await authorizer.exchange(code: "c", codeVerifier: "v", redirectURI: redirect)
        // The old refresh is still held: a new caller must not wait for it
        // or get account A's token from it.
        let token = try await withTimeout(2) { try await authorizer.validAccessToken() }
        XCTAssertEqual(token, "at-B")
        transport.releaseRefresh()
        _ = try? await withTimeout(5) { try await refresh.value }
    }
}

final class RedirectStateTests: XCTestCase {
    private func get(_ url: URL) async throws -> Int {
        let (_, response) = try await browserSession().data(from: url)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    func testRedirectWithWrongStateIsRefusedAndDoesNotEndTheWait() async throws {
        let listener = LoopbackRedirectListener()
        defer { listener.stop() }
        listener.expectedState = "good-state"
        let uri = try await withTimeout(5) { try await listener.start() }
        let flag = DoneFlag()
        let wait = Task { () throws -> [String: String] in
            defer { flag.set() }
            return try await listener.waitForRedirect(timeout: 10)
        }

        let forged = ["/?error=access_denied", "/?error=access_denied&state=bad",
                      "/?code=x&state=bad", "/?code=x", "/?code=x&state=good-stat"]
        for path in forged {
            let status = try await get(URL(string: uri.absoluteString + path)!)
            XCTAssertEqual(status, 400, path)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(flag.isDone, "a redirect with the wrong state must not end the wait")

        let status = try await get(URL(string: uri.absoluteString + "/?code=abc&state=good-state")!)
        XCTAssertEqual(status, 200)
        let parameters = try await withTimeout(5) { try await wait.value }
        XCTAssertEqual(parameters["code"], "abc")
        XCTAssertEqual(parameters["state"], "good-state")
    }

    func testErrorWithTheRightStateEndsTheWait() async throws {
        let listener = LoopbackRedirectListener()
        defer { listener.stop() }
        listener.expectedState = "s1"
        let uri = try await withTimeout(5) { try await listener.start() }
        let wait = Task { try await listener.waitForRedirect(timeout: 10) }
        let status = try await get(URL(string: uri.absoluteString + "/?error=access_denied&state=s1")!)
        XCTAssertEqual(status, 200)
        let parameters = try await withTimeout(5) { try await wait.value }
        XCTAssertEqual(parameters["error"], "access_denied")
    }

    func testForgedRedirectsBeforeTheRealOneDoNotAbortSignIn() async throws {
        let transport = MockTransport()
        transport.enqueue(200, #"{"access_token":"at-1","expires_in":3600,"refresh_token":"rt-1"}"#)
        let store = InMemoryTokenStore()
        let authorizer = GoogleAuthorizer(config: testConfig, transport: transport, store: store, openURL: { url in
            let fields = queryFields(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
            guard let redirect = fields["redirect_uri"], let state = fields["state"] else { return }
            Task.detached {
                for query in ["error=access_denied", "code=forged&state=guess", "code=4%2Freal&state=\(state)"] {
                    _ = try? await browserSession().data(from: URL(string: "\(redirect)/?\(query)")!)
                }
            }
        })
        let tokens = try await withTimeout(10) { try await authorizer.signIn(timeout: 8) }
        XCTAssertEqual(tokens.accessToken, "at-1")
        XCTAssertEqual(formFields(transport.requests.first?.httpBody)["code"], "4/real")
        XCTAssertEqual(transport.requests.count, 1)
    }

    /// The authorizer's own check, behind the listener's filter.
    func testAuthorizerChecksStateBeforeAnythingElse() throws {
        XCTAssertThrowsError(try GoogleAuthorizer.redirectCode(["error": "x", "state": "bad"], expectedState: "s")) {
            guard case .signInRejected = $0 as? CloudError else { return XCTFail("got \($0)") }
        }
        XCTAssertThrowsError(try GoogleAuthorizer.redirectCode(["error": "x"], expectedState: "s")) {
            guard case .signInRejected = $0 as? CloudError else { return XCTFail("got \($0)") }
        }
        XCTAssertThrowsError(try GoogleAuthorizer.redirectCode(["code": "c", "state": "bad"], expectedState: "s")) {
            guard case .signInRejected = $0 as? CloudError else { return XCTFail("got \($0)") }
        }
        XCTAssertThrowsError(try GoogleAuthorizer.redirectCode(["error": "x", "state": "s"], expectedState: "s")) {
            XCTAssertEqual($0 as? CloudError, .signInCancelled)
        }
        XCTAssertThrowsError(try GoogleAuthorizer.redirectCode(["state": "s"], expectedState: "s")) {
            guard case .badResponse = $0 as? CloudError else { return XCTFail("got \($0)") }
        }
        XCTAssertEqual(try GoogleAuthorizer.redirectCode(["code": "c", "state": "s"], expectedState: "s"), "c")
    }
}

final class CancellationTests: XCTestCase {
    func testCancelDuringCodeExchangeIsSignInCancelled() async throws {
        let transport = MockTransport(delay: 5)
        transport.enqueue(200, #"{"access_token":"at-1","expires_in":3600,"refresh_token":"rt-1"}"#)
        let store = InMemoryTokenStore()
        let authorizer = GoogleAuthorizer(config: testConfig, transport: transport, store: store, openURL: { url in
            let fields = queryFields(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
            guard let redirect = fields["redirect_uri"], let state = fields["state"] else { return }
            Task.detached { _ = try? await browserSession().data(from: URL(string: "\(redirect)/?code=c&state=\(state)")!) }
        })
        let signIn = Task { try await authorizer.signIn(timeout: 10) }
        try await waitUntil { transport.requests.count == 1 }
        signIn.cancel()
        do {
            _ = try await withTimeout(4) { try await signIn.value }
            XCTFail("expected signInCancelled")
        } catch {
            XCTAssertEqual(error as? CloudError, .signInCancelled)
        }
        XCTAssertNil(try store.load())
    }

    func testCancelledTokenRequestIsCancellationNotNetwork() async {
        for failure in [URLError(.cancelled) as Error, CancellationError()] {
            let transport = MockTransport()
            transport.enqueue(.fail(failure))
            let authorizer = GoogleAuthorizer(config: testConfig, transport: transport, store: InMemoryTokenStore(),
                                              openURL: { _ in })
            do {
                try await authorizer.exchange(code: "c", codeVerifier: "v", redirectURI: URL(string: "http://127.0.0.1:1")!)
                XCTFail("expected cancellation")
            } catch {
                XCTAssertTrue(error is CancellationError, "got \(error)")
            }
        }
    }

    private func uploader(_ transport: MockTransport) -> GoogleDriveUploader {
        GoogleDriveUploader(tokens: ScriptedTokens(["t"]), transport: transport,
                            cachedFolderID: { "F1" }, storeFolderID: { _ in })
    }

    func testCancelledUploadRequestIsCancellationNotNetwork() async {
        for failure in [URLError(.cancelled) as Error, CancellationError()] {
            let transport = MockTransport()
            transport.enqueue(.fail(failure))
            do {
                _ = try await uploader(transport).upload(data: Data([1, 2, 3]), fileName: "a.png", mimeType: "image/png")
                XCTFail("expected cancellation")
            } catch {
                XCTAssertTrue(error is CancellationError, "got \(error)")
            }
        }
    }

    func testCancellingAnUploadTaskIsCancellation() async throws {
        // The folder check answers at once (it runs in a shared task that
        // the caller's cancellation does not reach); the upload itself hangs.
        let transport = SlowUploadTransport()
        let up = GoogleDriveUploader(tokens: ScriptedTokens(["t"]), transport: transport,
                                     cachedFolderID: { "F1" }, storeFolderID: { _ in })
        let task = Task { try await up.upload(data: Data([1, 2, 3]), fileName: "a.png", mimeType: "image/png") }
        try await waitUntil { transport.uploadStarted }
        task.cancel()
        do {
            _ = try await withTimeout(4) { try await task.value }
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
    }
}

final class ListenerStartTests: XCTestCase {
    private func outcome(_ drive: @escaping @Sendable (StartGate) -> Void) async throws -> UInt16 {
        try await withTimeout(3) {
            let gate = StartGate()
            drive(gate)
            return try await withCheckedThrowingContinuation { gate.attach($0) }
        }
    }

    func testWaitingIsAFailure() async {
        do {
            _ = try await outcome { $0.handle(.waiting(.posix(.ENETDOWN)), port: nil) }
            XCTFail("expected a failure")
        } catch {
            guard case .network = error as? CloudError else { return XCTFail("got \(error)") }
        }
    }

    func testReadyWithoutPortWaitsForTheTimeout() async {
        do {
            _ = try await outcome { gate in
                gate.handle(.setup, port: nil)
                gate.handle(.ready, port: nil)
                gate.timeOut()
            }
            XCTFail("expected a failure")
        } catch {
            guard case .network = error as? CloudError else { return XCTFail("got \(error)") }
        }
    }

    func testFirstOutcomeWins() async throws {
        let port = try await outcome { gate in
            gate.handle(.ready, port: 4321)
            gate.handle(.failed(.posix(.ECONNRESET)), port: nil)
            gate.timeOut()
        }
        XCTAssertEqual(port, 4321)
    }

    func testCancelledStartIsCancellation() async {
        do {
            _ = try await outcome { $0.cancel() }
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
    }

    func testFailureAfterStartEndsTheWait() async throws {
        let listener = LoopbackRedirectListener()
        defer { listener.stop() }
        _ = try await withTimeout(5) { try await listener.start() }
        let wait = Task { try await listener.waitForRedirect(timeout: 30) }
        try await Task.sleep(nanoseconds: 100_000_000)
        listener.listenerStateChanged(.failed(.posix(.ECONNABORTED)))
        do {
            _ = try await withTimeout(3) { try await wait.value }
            XCTFail("expected a failure")
        } catch {
            guard case .network = error as? CloudError else { return XCTFail("got \(error)") }
        }
    }

    func testFailureBeforeTheWaitIsReportedByTheWait() async throws {
        let listener = LoopbackRedirectListener()
        defer { listener.stop() }
        _ = try await withTimeout(5) { try await listener.start() }
        listener.listenerStateChanged(.failed(.posix(.ECONNABORTED)))
        do {
            _ = try await withTimeout(3) { try await listener.waitForRedirect(timeout: 30) }
            XCTFail("expected a failure")
        } catch {
            guard case .network = error as? CloudError else { return XCTFail("got \(error)") }
        }
    }

    func testStartAndSignInStillWork() async throws {
        let listener = LoopbackRedirectListener()
        defer { listener.stop() }
        let uri = try await withTimeout(5) { try await listener.start() }
        XCTAssertNotNil(uri.port)
    }
}
