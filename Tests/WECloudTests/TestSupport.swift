import Foundation
import XCTest
@testable import WECloud

/// A scripted network: records every request and answers from a queue.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    enum Answer {
        case reply(Int, Data)
        case fail(Error)
    }

    private let lock = NSLock()
    private var answers: [Answer] = []
    private var recorded: [URLRequest] = []
    private let delayNanoseconds: UInt64

    init(delay: TimeInterval = 0) {
        delayNanoseconds = UInt64(delay * 1_000_000_000)
    }

    func enqueue(_ status: Int, _ json: String) {
        enqueue(.reply(status, Data(json.utf8)))
    }

    func enqueue(_ answer: Answer) {
        lock.lock(); defer { lock.unlock() }
        answers.append(answer)
    }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    private func next(_ request: URLRequest) -> Answer {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
        if answers.isEmpty { return .reply(599, Data("{\"error\":\"no scripted answer\"}".utf8)) }
        return answers.removeFirst()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let answer = next(request)
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        switch answer {
        case let .reply(status, data):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            return (data, response)
        case let .fail(error):
            throw error
        }
    }
}

/// A clock the test moves by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

/// Hands out the scripted tokens one by one, the last one again when used up.
final class ScriptedTokens: AccessTokenProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String]
    private var count = 0

    init(_ tokens: [String]) { self.tokens = tokens }

    var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func validAccessToken() async throws -> String {
        next()
    }

    private func next() -> String {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return tokens.count > 1 ? tokens.removeFirst() : tokens[0]
    }
}

/// Collects the values handed to storeFolderID.
final class FolderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: String?
    private var stored: [String?] = []

    init(_ cached: String?) { self.cached = cached }

    var current: String? {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    var history: [String?] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func store(_ value: String?) {
        lock.lock(); defer { lock.unlock() }
        cached = value
        stored.append(value)
    }
}

/// Decodes a form body or query string for assertions.
func formFields(_ data: Data?) -> [String: String] {
    guard let data = data, let text = String(data: data, encoding: .utf8) else { return [:] }
    return queryFields(text)
}

func queryFields(_ query: String?) -> [String: String] {
    var result: [String: String] = [:]
    for part in (query ?? "").split(separator: "&") {
        let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(pieces[0]).removingPercentEncoding ?? ""
        let value = pieces.count > 1 ? (String(pieces[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "") : ""
        result[name] = value
    }
    return result
}

/// The query of a URL exactly as sent, still percent-encoded.
func rawQuery(_ url: URL?) -> String? {
    guard let url = url else { return nil }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
}

func jsonObject(_ data: Data?) -> [String: Any] {
    guard let data = data else { return [:] }
    return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
}

/// A session for talking to the loopback listener like a browser would.
func browserSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 3
    configuration.timeoutIntervalForResource = 5
    return URLSession(configuration: configuration)
}

let testConfig = OAuthClientConfig.google(clientID: "client-123.apps.googleusercontent.com",
                                          clientSecret: "test-client-secret")
