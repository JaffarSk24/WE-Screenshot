import Foundation
import Security
import XCTest
@testable import WECloud

final class KeychainTests: XCTestCase {
    private var service = ""

    override func setUp() {
        super.setUp()
        service = "sk.whiteeagles.screenshot.tests.\(UUID().uuidString)"
    }

    override func tearDown() {
        // Remove every item of the test service, whatever the test left behind.
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
        super.tearDown()
    }

    /// Runs a keychain test, skipping it where the keychain cannot be used
    /// without user interaction (for example on some CI machines).
    private func withUsableKeychain(_ body: (KeychainStore) throws -> Void) throws {
        let keychain = KeychainStore(service: service)
        do {
            try keychain.set("probe", for: "probe")
            guard try keychain.string(for: "probe") == "probe" else {
                throw XCTSkip("The keychain did not return the stored value.")
            }
            try keychain.set(nil, for: "probe")
        } catch let error as CloudError {
            throw XCTSkip("The keychain is not usable here: \(error)")
        }
        try body(keychain)
    }

    func testKeychainRoundTrip() throws {
        try withUsableKeychain { keychain in
            XCTAssertNil(try keychain.string(for: "a"))
            try keychain.set("first", for: "a")
            XCTAssertEqual(try keychain.string(for: "a"), "first")
            try keychain.set("second value", for: "a")
            XCTAssertEqual(try keychain.string(for: "a"), "second value")
            try keychain.set("other", for: "b")
            XCTAssertEqual(try keychain.string(for: "a"), "second value")
            try keychain.set("", for: "a")
            XCTAssertNil(try keychain.string(for: "a"))
            try keychain.set(nil, for: "b")
            XCTAssertNil(try keychain.string(for: "b"))
            try keychain.set(nil, for: "never-there")
        }
    }

    func testKeychainTokenStoreRoundTrip() throws {
        try withUsableKeychain { keychain in
            let store = KeychainTokenStore(keychain: keychain, account: "tokens")
            XCTAssertNil(try store.load())
            let tokens = OAuthTokens(accessToken: "at-1", refreshToken: "rt-1",
                                     expiresAt: Date(timeIntervalSince1970: 1_800_000_123))
            try store.save(tokens)
            XCTAssertEqual(try store.load(), tokens)
            let raw = try XCTUnwrap(try keychain.string(for: "tokens"))
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
            try store.clear()
            XCTAssertNil(try store.load())
            try keychain.set("not json", for: "tokens")
            XCTAssertNil(try store.load(), "a damaged item reads as signed out")
        }
    }
}

final class InMemoryTokenStoreTests: XCTestCase {
    func testSaveLoadClear() throws {
        let tokens = OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 5))
        let store = InMemoryTokenStore()
        XCTAssertNil(try store.load())
        try store.save(tokens)
        XCTAssertEqual(try store.load(), tokens)
        try store.clear()
        XCTAssertNil(try store.load())
        XCTAssertEqual(try InMemoryTokenStore(tokens).load(), tokens)
    }

    func testConcurrentAccess() throws {
        let store = InMemoryTokenStore()
        DispatchQueue.concurrentPerform(iterations: 500) { i in
            try? store.save(OAuthTokens(accessToken: "a\(i)", refreshToken: nil, expiresAt: Date()))
            _ = try? store.load()
            if i % 7 == 0 { try? store.clear() }
        }
        try store.save(OAuthTokens(accessToken: "last", refreshToken: nil, expiresAt: Date()))
        XCTAssertEqual(try store.load()?.accessToken, "last")
    }
}

final class CloudErrorTests: XCTestCase {
    func testDescriptionsDoNotLeakTokens() {
        let access = "ya29.a0AfB_byC1dEfGhIjKlMnOpQrStUvWxYz0123456789"
        let refresh = "1//0gLmNoPqRsTuVwXyZ-abcdefghijklmnop0123456789"
        let long = "AbCdEf0123456789GhIjKl0123456789"
        let texts = [
            "Invalid token \(access)",
            "refresh_token=\(refresh) rejected",
            "Bearer \(access)",
            "code=4/0AbCdEf leaked \(long)",
        ]
        for text in texts {
            let errors: [CloudError] = [
                .signInRejected(text),
                .server(status: 401, message: text),
                .badResponse(text),
                .sharingForbidden(text),
                .network(text),
            ]
            for error in errors {
                let description = error.errorDescription ?? ""
                XCTAssertFalse(description.isEmpty)
                for secret in [access, refresh, long, "4/0AbCdEf"] {
                    XCTAssertFalse(description.contains(secret), "\(error) leaks into: \(description)")
                }
            }
        }
    }

    func testDescriptionsAreShortAndHuman() {
        let all: [CloudError] = [.notConfigured, .notSignedIn, .signInCancelled, .signInRejected("x"),
                                 .server(status: 500, message: "Backend Error"), .badResponse(""),
                                 .sharingForbidden(""), .network("The Internet connection appears to be offline.")]
        for error in all {
            let description = error.errorDescription ?? ""
            XCTAssertFalse(description.isEmpty)
            XCTAssertLessThan(description.count, 300)
        }
        XCTAssertTrue(CloudError.server(status: 500, message: "Backend Error").errorDescription?.contains("Backend Error") ?? false)
        XCTAssertTrue(CloudError.server(status: 500, message: "Backend Error").errorDescription?.contains("500") ?? false)
    }
}
