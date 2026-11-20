import Foundation
import XCTest
@testable import WECloud

final class UploaderTests: XCTestCase {
    private let image = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF, 0x2D, 0x2D, 0x0D, 0x0A])
    private let uploadAnswer = #"{"id":"FILE1","webViewLink":"https://drive.google.com/file/d/FILE1/view?usp=drivesdk"}"#

    private func makeUploader(_ transport: MockTransport, _ folder: FolderBox,
                              tokens: AccessTokenProviding = ScriptedTokens(["t1"])) -> GoogleDriveUploader {
        GoogleDriveUploader(tokens: tokens, transport: transport,
                            cachedFolderID: { folder.current }, storeFolderID: { folder.store($0) })
    }

    func testCachedFolderStillValid() async throws {
        let transport = MockTransport()
        transport.enqueue(200, #"{"id":"F1","trashed":false}"#)
        transport.enqueue(200, uploadAnswer)
        transport.enqueue(200, #"{"id":"anyoneWithLink"}"#)
        let folder = FolderBox("F1")
        let result = try await makeUploader(transport, folder).upload(data: image, fileName: "Shot.png", mimeType: "image/png")

        XCTAssertEqual(result.fileID, "FILE1")
        let requests = transport.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(requests[0].url?.path, "/drive/v3/files/F1")
        XCTAssertEqual(queryFields(rawQuery(requests[0].url))["fields"], "id,trashed")
        XCTAssertEqual(requests[1].url?.host, "www.googleapis.com")
        XCTAssertEqual(requests[1].url?.path, "/upload/drive/v3/files")
        XCTAssertEqual(requests[2].url?.path, "/drive/v3/files/FILE1/permissions")
        XCTAssertTrue(folder.history.isEmpty, "a valid cached folder is not stored again")
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t1")
        }
    }

    func testCachedFolderGoneSearchFindsOne() async throws {
        let transport = MockTransport()
        transport.enqueue(404, #"{"error":{"code":404,"message":"File not found: F1."}}"#)
        transport.enqueue(200, #"{"files":[{"id":"F2","name":"WE Screenshot"}]}"#)
        transport.enqueue(200, uploadAnswer)
        transport.enqueue(200, "{}")
        let folder = FolderBox("F1")
        _ = try await makeUploader(transport, folder).upload(data: image, fileName: "Shot.png", mimeType: "image/png")

        let requests = transport.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[1].httpMethod, "GET")
        XCTAssertEqual(requests[1].url?.path, "/drive/v3/files")
        let search = queryFields(rawQuery(requests[1].url))
        XCTAssertEqual(search["q"], "mimeType = 'application/vnd.google-apps.folder' and name = 'WE Screenshot' and trashed = false")
        XCTAssertEqual(search["fields"], "files(id,name)")
        XCTAssertEqual(folder.history, [nil, "F2"])
        let metadata = try multipartMetadata(requests[2])
        XCTAssertEqual(metadata["parents"] as? [String], ["F2"])
    }

    func testTrashedCachedFolderIsCreatedAgain() async throws {
        let transport = MockTransport()
        transport.enqueue(200, #"{"id":"F1","trashed":true}"#)
        transport.enqueue(200, #"{"files":[]}"#)
        transport.enqueue(200, #"{"id":"F3"}"#)
        transport.enqueue(200, uploadAnswer)
        transport.enqueue(200, "{}")
        let folder = FolderBox("F1")
        _ = try await makeUploader(transport, folder).upload(data: image, fileName: "Shot.png", mimeType: "image/png")
        XCTAssertEqual(folder.history, [nil, "F3"])
        XCTAssertEqual(transport.requests[2].httpMethod, "POST")
        XCTAssertEqual(transport.requests[2].url?.path, "/drive/v3/files")
    }

    func testNothingFoundCreatesFolderAndStoresID() async throws {
        let transport = MockTransport()
        transport.enqueue(200, #"{"files":[]}"#)
        transport.enqueue(200, #"{"id":"F3"}"#)
        transport.enqueue(200, uploadAnswer)
        transport.enqueue(200, "{}")
        let folder = FolderBox(nil)
        _ = try await makeUploader(transport, folder).upload(data: image, fileName: "Shot.png", mimeType: "image/png")

        let requests = transport.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[0].url?.path, "/drive/v3/files")
        XCTAssertEqual(requests[1].httpMethod, "POST")
        XCTAssertEqual(requests[1].url?.path, "/drive/v3/files")
        XCTAssertTrue(requests[1].value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") ?? false)
        let body = jsonObject(requests[1].httpBody)
        XCTAssertEqual(body["name"] as? String, "WE Screenshot")
        XCTAssertEqual(body["mimeType"] as? String, "application/vnd.google-apps.folder")
        XCTAssertEqual(folder.history, ["F3"])
    }

    func testMultipartBodyAndPermissionRequest() async throws {
        let transport = MockTransport()
        transport.enqueue(200, #"{"id":"F1","trashed":false}"#)
        transport.enqueue(200, uploadAnswer)
        transport.enqueue(200, "{}")
        _ = try await makeUploader(transport, FolderBox("F1"))
            .upload(data: image, fileName: "Screenshot 2026-11-20 at 10.15.00.png", mimeType: "image/png")

        let upload = transport.requests[1]
        XCTAssertEqual(upload.httpMethod, "POST")
        let query = queryFields(rawQuery(upload.url))
        XCTAssertEqual(query["uploadType"], "multipart")
        XCTAssertEqual(query["fields"], "id,webViewLink")
        let contentType = try XCTUnwrap(upload.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/related; boundary="))
        let boundary = String(contentType.dropFirst("multipart/related; boundary=".count))
        XCTAssertFalse(boundary.isEmpty)

        let body = try XCTUnwrap(upload.httpBody)
        XCTAssertTrue(body.starts(with: Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)))
        XCTAssertNotNil(body.range(of: Data("\r\n--\(boundary)\r\nContent-Type: image/png\r\n\r\n".utf8)))
        var expectedTail = image
        expectedTail.append(Data("\r\n--\(boundary)--\r\n".utf8))
        XCTAssertTrue(body.suffix(expectedTail.count) == expectedTail, "image bytes intact, closing boundary last")

        let metadata = try multipartMetadata(upload)
        XCTAssertEqual(metadata["name"] as? String, "Screenshot 2026-11-20 at 10.15.00.png")
        XCTAssertEqual(metadata["parents"] as? [String], ["F1"])

        let permission = transport.requests[2]
        XCTAssertEqual(permission.httpMethod, "POST")
        XCTAssertEqual(permission.url?.absoluteString, "https://www.googleapis.com/drive/v3/files/FILE1/permissions")
        let permissionBody = jsonObject(permission.httpBody)
        XCTAssertEqual(permissionBody["type"] as? String, "anyone")
        XCTAssertEqual(permissionBody["role"] as? String, "reader")
        XCTAssertEqual(permissionBody.count, 2)
    }

    func testLinksInResult() async throws {
        let transport = MockTransport()
        transport.enqueue(200, #"{"id":"F1","trashed":false}"#)
        transport.enqueue(200, uploadAnswer)
        transport.enqueue(200, "{}")
        let result = try await makeUploader(transport, FolderBox("F1")).upload(data: image, fileName: "a.png", mimeType: "image/png")
        XCTAssertEqual(result, UploadResult(
            fileID: "FILE1",
            viewURL: URL(string: "https://drive.google.com/file/d/FILE1/view?usp=drivesdk")!,
            directImageURL: URL(string: "https://drive.google.com/uc?export=view&id=FILE1")!))
    }

    func testViewURLFallbackWithoutWebViewLink() async throws {
        let transport = MockTransport()
        transport.enqueue(200, #"{"id":"F1","trashed":false}"#)
        transport.enqueue(200, #"{"id":"FILE2"}"#)
        transport.enqueue(200, "{}")
        let result = try await makeUploader(transport, FolderBox("F1")).upload(data: image, fileName: "a.jpg", mimeType: "image/jpeg")
        XCTAssertEqual(result.viewURL.absoluteString, "https://drive.google.com/file/d/FILE2/view")
        XCTAssertEqual(result.directImageURL.absoluteString, "https://drive.google.com/uc?export=view&id=FILE2")
    }

    func testUnauthorizedRetriesOnceWithNewToken() async throws {
        let transport = MockTransport()
        transport.enqueue(200, #"{"id":"F1","trashed":false}"#)
        transport.enqueue(401, #"{"error":{"code":401,"message":"Invalid Credentials"}}"#)
        transport.enqueue(200, uploadAnswer)
        transport.enqueue(200, "{}")
        let tokens = ScriptedTokens(["t1", "t1", "t2"])
        let result = try await makeUploader(transport, FolderBox("F1"), tokens: tokens)
            .upload(data: image, fileName: "a.png", mimeType: "image/png")
        XCTAssertEqual(result.fileID, "FILE1")
        let requests = transport.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer t1")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer t2")
        XCTAssertEqual(requests[2].httpBody, requests[1].httpBody)
        XCTAssertEqual(tokens.calls, 4)
    }

    func testSecondUnauthorizedIsServerError() async {
        let transport = MockTransport()
        transport.enqueue(401, #"{"error":{"code":401,"message":"Invalid Credentials"}}"#)
        transport.enqueue(401, #"{"error":{"code":401,"message":"Invalid Credentials"}}"#)
        do {
            _ = try await makeUploader(transport, FolderBox("F1")).upload(data: image, fileName: "a.png", mimeType: "image/png")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CloudError, .server(status: 401, message: "Invalid Credentials"))
        }
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testUnauthorizedWithRealAuthorizerForcesRefresh() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore(OAuthTokens(accessToken: "at-old", refreshToken: "rt-1",
                                                   expiresAt: clock.now.addingTimeInterval(1800)))
        let authTransport = MockTransport()
        authTransport.enqueue(200, #"{"access_token":"at-new","expires_in":3600}"#)
        let authorizer = GoogleAuthorizer(config: testConfig, transport: authTransport, store: store,
                                          openURL: { _ in }, now: { clock.now })
        let drive = MockTransport()
        drive.enqueue(401, #"{"error":{"code":401,"message":"Invalid Credentials"}}"#)
        drive.enqueue(200, #"{"user":{"displayName":"Kim","emailAddress":"kim@example.com"}}"#)
        let uploader = GoogleDriveUploader(tokens: authorizer, transport: drive,
                                           cachedFolderID: { nil }, storeFolderID: { _ in })
        let label = try await uploader.accountLabel()
        XCTAssertEqual(label, "kim@example.com")
        XCTAssertEqual(authTransport.requests.count, 1, "the rejected token was refreshed")
        XCTAssertEqual(drive.requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer at-new")
        XCTAssertEqual(try store.load()?.accessToken, "at-new")
    }

    func testForbiddenPermissionIsSharingForbidden() async {
        let transport = MockTransport()
        transport.enqueue(200, #"{"id":"F1","trashed":false}"#)
        transport.enqueue(200, uploadAnswer)
        transport.enqueue(403, #"{"error":{"code":403,"message":"The user does not have sufficient permissions for this file.","errors":[{"reason":"domainPolicy"}]}}"#)
        do {
            _ = try await makeUploader(transport, FolderBox("F1")).upload(data: image, fileName: "a.png", mimeType: "image/png")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CloudError, .sharingForbidden("The user does not have sufficient permissions for this file."))
        }
    }

    func testBadRequestOnPermissionIsSharingForbidden() async {
        let transport = MockTransport()
        transport.enqueue(200, #"{"id":"F1","trashed":false}"#)
        transport.enqueue(200, uploadAnswer)
        transport.enqueue(400, #"{"error":{"code":400,"message":"Bad Request. User message: \"Sharing is not allowed.\"","errors":[{"reason":"invalidSharingRequest"}]}}"#)
        do {
            _ = try await makeUploader(transport, FolderBox("F1")).upload(data: image, fileName: "a.png", mimeType: "image/png")
            XCTFail("expected an error")
        } catch {
            guard case .sharingForbidden = error as? CloudError else { return XCTFail("got \(error)") }
        }
    }

    func testServerErrorOnUploadCarriesGoogleMessage() async {
        let transport = MockTransport()
        transport.enqueue(200, #"{"id":"F1","trashed":false}"#)
        transport.enqueue(500, #"{"error":{"code":500,"message":"Backend Error","errors":[{"reason":"backendError"}]}}"#)
        do {
            _ = try await makeUploader(transport, FolderBox("F1")).upload(data: image, fileName: "a.png", mimeType: "image/png")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CloudError, .server(status: 500, message: "Backend Error"))
        }
        XCTAssertEqual(transport.requests.count, 2, "no permission call after a failed upload")
    }

    func testThrowingTransportIsNetworkError() async {
        let transport = MockTransport()
        transport.enqueue(.fail(URLError(.notConnectedToInternet)))
        do {
            _ = try await makeUploader(transport, FolderBox("F1")).upload(data: image, fileName: "a.png", mimeType: "image/png")
            XCTFail("expected an error")
        } catch {
            guard case .network = error as? CloudError else { return XCTFail("got \(error)") }
        }
    }

    func testNotSignedInPassesThrough() async {
        let authorizer = GoogleAuthorizer(config: testConfig, transport: MockTransport(), store: InMemoryTokenStore(),
                                          openURL: { _ in })
        let transport = MockTransport()
        let uploader = GoogleDriveUploader(tokens: authorizer, transport: transport,
                                           cachedFolderID: { nil }, storeFolderID: { _ in })
        do {
            _ = try await uploader.upload(data: image, fileName: "a.png", mimeType: "image/png")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CloudError, .notSignedIn)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testAccountLabel() async throws {
        let transport = MockTransport()
        transport.enqueue(200, #"{"user":{"displayName":"Kim Novak","emailAddress":"kim@example.com"}}"#)
        transport.enqueue(200, #"{"user":{"displayName":"Kim Novak"}}"#)
        let uploader = makeUploader(transport, FolderBox(nil))
        let first = try await uploader.accountLabel()
        XCTAssertEqual(first, "kim@example.com")
        let second = try await uploader.accountLabel()
        XCTAssertEqual(second, "Kim Novak")
        let request = transport.requests[0]
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/drive/v3/about")
        XCTAssertEqual(queryFields(rawQuery(request.url))["fields"], "user(displayName,emailAddress)")
    }

    func testFolderNameWithQuoteIsEscapedInSearch() async throws {
        let transport = MockTransport()
        transport.enqueue(200, #"{"files":[{"id":"F9"}]}"#)
        transport.enqueue(200, uploadAnswer)
        transport.enqueue(200, "{}")
        let folder = FolderBox(nil)
        let uploader = GoogleDriveUploader(tokens: ScriptedTokens(["t"]), transport: transport, folderName: "Kim's shots",
                                           cachedFolderID: { folder.current }, storeFolderID: { folder.store($0) })
        _ = try await uploader.upload(data: image, fileName: "a.png", mimeType: "image/png")
        let q = queryFields(rawQuery(transport.requests[0].url))["q"]
        XCTAssertEqual(q, #"mimeType = 'application/vnd.google-apps.folder' and name = 'Kim\'s shots' and trashed = false"#)
    }

    private func multipartMetadata(_ request: URLRequest) throws -> [String: Any] {
        let body = try XCTUnwrap(request.httpBody)
        let start = try XCTUnwrap(body.range(of: Data("\r\n\r\n".utf8))).upperBound
        let end = try XCTUnwrap(body.range(of: Data("\r\n--".utf8), in: start..<body.endIndex)).lowerBound
        return jsonObject(body.subdata(in: start..<end))
    }
}
