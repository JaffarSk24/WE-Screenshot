import Foundation
import XCTest
@testable import WECloud

final class LocalSecretStoreTests: XCTestCase {
    private var root: URL!
    private var dir: URL { root.appendingPathComponent("store", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("we-secret-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func mode(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func file(_ name: String) -> URL { dir.appendingPathComponent("\(name).secret") }

    func testRoundTrip() throws {
        let store = LocalSecretStore(directory: dir)
        XCTAssertNil(try store.string(for: "a"))
        try store.set("first", for: "a")
        XCTAssertEqual(try store.string(for: "a"), "first")
        try store.set("second value", for: "a")
        XCTAssertEqual(try store.string(for: "a"), "second value")
        try store.set("other", for: "b")
        XCTAssertEqual(try store.string(for: "a"), "second value")
        XCTAssertEqual(try store.string(for: "b"), "other")
    }

    func testNilAndEmptyRemoveTheFile() throws {
        let store = LocalSecretStore(directory: dir)
        try store.set("x", for: "a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file("a").path))
        try store.set("", for: "a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file("a").path))
        XCTAssertNil(try store.string(for: "a"))
        try store.set("y", for: "a")
        try store.set(nil, for: "a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file("a").path))
        try store.set(nil, for: "never-there")
    }

    func testMissingFileGivesNil() throws {
        XCTAssertNil(try LocalSecretStore(directory: dir).string(for: "nothing"))
    }

    func testModesHoldWithPermissiveUmask() throws {
        let old = umask(0)
        defer { umask(old) }
        let store = LocalSecretStore(directory: dir)
        try store.set("secret", for: "a")
        XCTAssertEqual(try mode(dir), 0o700)
        XCTAssertEqual(try mode(file("a")), 0o600)
    }

    func testExistingWideDirectoryIsTightened() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(try mode(dir), 0o755)
        try LocalSecretStore(directory: dir).set("secret", for: "a")
        XCTAssertEqual(try mode(dir), 0o700)
    }

    func testOverwriteKeepsModeAndLeavesNoTemporaryFiles() throws {
        let store = LocalSecretStore(directory: dir)
        try store.set("one", for: "a")
        try store.set("two", for: "a")
        XCTAssertEqual(try mode(file("a")), 0o600)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names, ["a.secret"])
    }

    func testSymbolicLinkIsRefusedOnReadAndReplacedOnWrite() throws {
        let store = LocalSecretStore(directory: dir)
        try store.set("seed", for: "seed")
        let outside = root.appendingPathComponent("outside.txt")
        try "original".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: file("a"), withDestinationURL: outside)
        XCTAssertThrowsError(try store.string(for: "a"))
        try store.set("new", for: "a")
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "original")
        XCTAssertEqual(try store.string(for: "a"), "new")
        let attrs = try FileManager.default.attributesOfItem(atPath: file("a").path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeRegular)
    }

    func testInvalidNamesThrow() throws {
        let store = LocalSecretStore(directory: dir)
        for name in ["../x", "a/b", "", "a b", "a.b"] {
            XCTAssertThrowsError(try store.set("v", for: name), name)
            XCTAssertThrowsError(try store.string(for: name), name)
        }
    }

    func testOversizedFileIsRefused() throws {
        let store = LocalSecretStore(directory: dir)
        try store.set("seed", for: "seed")
        try Data(repeating: 0x61, count: 64 * 1024 + 1).write(to: file("big"))
        XCTAssertThrowsError(try store.string(for: "big"))
        try Data(repeating: 0x61, count: 64 * 1024).write(to: file("edge"))
        XCTAssertEqual(try store.string(for: "edge")?.count, 64 * 1024)
    }

    func testErrorsDoNotContainTheValue() throws {
        let store = LocalSecretStore(directory: dir)
        do { try store.set("TOP-SECRET-VALUE", for: "../bad") } catch {
            XCTAssertFalse(((error as? CloudError)?.errorDescription ?? "").contains("TOP-SECRET-VALUE"))
        }
    }

    func testConcurrentWritesLeaveAValidValue() async throws {
        let store = LocalSecretStore(directory: dir)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask { try? store.set("value-\(i)", for: "a") }
            }
        }
        let value = try XCTUnwrap(try store.string(for: "a"))
        XCTAssertTrue((0..<20).map { "value-\($0)" }.contains(value))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["a.secret"])
    }

    func testFileTokenStoreRoundTripDamagedAndClear() throws {
        let secrets = LocalSecretStore(directory: dir)
        let store = FileTokenStore(store: secrets, name: "tokens")
        XCTAssertNil(try store.load())
        let tokens = OAuthTokens(accessToken: "at-1", refreshToken: "rt-1",
                                 expiresAt: Date(timeIntervalSince1970: 1_800_000_123))
        try store.save(tokens)
        XCTAssertEqual(try store.load(), tokens)
        let raw = try XCTUnwrap(try secrets.string(for: "tokens"))
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        try secrets.set("not json", for: "tokens")
        XCTAssertNil(try store.load(), "a damaged file reads as signed out")
        try store.save(tokens)
        try store.clear()
        XCTAssertNil(try store.load())
        XCTAssertNoThrow(try store.clear())
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
