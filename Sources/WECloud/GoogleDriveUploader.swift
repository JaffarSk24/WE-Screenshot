import Foundation
import WECore

/// Uploads into the folder "WE Screenshot" of the user's Google Drive and
/// opens the file to anyone with the link (reader).
public final class GoogleDriveUploader: ScreenshotUploading, @unchecked Sendable {
    static let filesEndpoint = URL(string: "https://www.googleapis.com/drive/v3/files")!
    static let uploadEndpoint = URL(string: "https://www.googleapis.com/upload/drive/v3/files")!
    static let aboutEndpoint = URL(string: "https://www.googleapis.com/drive/v3/about")!
    static let folderMimeType = "application/vnd.google-apps.folder"

    private let tokens: AccessTokenProviding
    private let transport: HTTPTransport
    private let folderName: String
    private let cachedFolderID: @Sendable () -> String?
    private let storeFolderID: @Sendable (String?) -> Void

    // Two uploads started at once must not create two folders: the folder
    // lookup runs once and later callers wait for it.
    private let lock = NSLock()
    private var folderTask: Task<String, Error>?

    /// `cachedFolderID` and `storeFolderID` read and write the remembered ID of
    /// the folder, so it is not searched for on every upload.
    public init(tokens: AccessTokenProviding, transport: HTTPTransport,
                folderName: String = "WE Screenshot",
                cachedFolderID: @escaping @Sendable () -> String?,
                storeFolderID: @escaping @Sendable (String?) -> Void) {
        self.tokens = tokens
        self.transport = transport
        self.folderName = folderName
        self.cachedFolderID = cachedFolderID
        self.storeFolderID = storeFolderID
    }

    /// Steps: make sure the folder exists (the cached ID, else search among the
    /// files the app created, else create it; a cached folder that is gone or
    /// in the trash is created again), upload the file into it, add the
    /// permission "anyone with the link can view", return the links.
    /// A 401 answer makes one more attempt with a fresh token.
    public func upload(data: Data, fileName: String, mimeType: String) async throws -> UploadResult {
        let folderID = try await ensureFolder()

        let boundary = "WEScreenshot-" + UUID().uuidString
        let body = GoogleDriveUploader.multipartBody(boundary: boundary, fileName: fileName,
                                                     folderID: folderID, mimeType: mimeType, data: data)
        let uploadURL = GoogleDriveUploader.url(GoogleDriveUploader.uploadEndpoint, query: [
            ("uploadType", "multipart"),
            ("fields", "id,webViewLink"),
        ])
        let (answer, response) = try await send { token in
            var request = GoogleDriveUploader.request(uploadURL, method: "POST", token: token)
            request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            return request
        }
        try GoogleDriveUploader.requireSuccess(answer, response)
        guard let json = JSONBody.object(answer), let fileID = json["id"] as? String, !fileID.isEmpty else {
            throw CloudError.badResponse("No file ID in the upload answer")
        }

        let permissionsURL = GoogleDriveUploader.filesEndpoint
            .appendingPathComponent(fileID)
            .appendingPathComponent("permissions")
        let permission = JSONBody.data(["type": "anyone", "role": "reader"])
        let (shareAnswer, shareResponse) = try await send { token in
            var request = GoogleDriveUploader.request(permissionsURL, method: "POST", token: token)
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = permission
            return request
        }
        if !isSuccess(shareResponse) {
            let message = JSONBody.googleMessage(shareAnswer, status: shareResponse.statusCode)
            // Workspace policies that forbid public links answer 400
            // (invalidSharingRequest) or 403 (domainPolicy and similar).
            if shareResponse.statusCode == 400 || shareResponse.statusCode == 403 {
                throw CloudError.sharingForbidden(message)
            }
            throw CloudError.server(status: shareResponse.statusCode, message: message)
        }

        let viewURL = (json["webViewLink"] as? String)
            .flatMap { URL(string: $0) }
            .flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil }
            ?? GoogleDriveUploader.defaultViewURL(fileID)
        return UploadResult(fileID: fileID, viewURL: viewURL,
                            directImageURL: GoogleDriveUploader.directImageURL(fileID))
    }

    /// Name or e-mail of the account the tokens belong to, for display.
    public func accountLabel() async throws -> String {
        let url = GoogleDriveUploader.url(GoogleDriveUploader.aboutEndpoint, query: [
            ("fields", "user(displayName,emailAddress)"),
        ])
        let (data, response) = try await send { token in
            GoogleDriveUploader.request(url, method: "GET", token: token)
        }
        try GoogleDriveUploader.requireSuccess(data, response)
        guard let user = JSONBody.object(data)?["user"] as? [String: Any] else {
            throw CloudError.badResponse("No user in the account answer")
        }
        // The e-mail address tells accounts apart; the name is the fallback.
        if let email = user["emailAddress"] as? String, !email.isEmpty { return email }
        if let name = user["displayName"] as? String, !name.isEmpty { return name }
        throw CloudError.badResponse("No user in the account answer")
    }

    // MARK: - Links

    static func defaultViewURL(_ fileID: String) -> URL {
        URL(string: "https://drive.google.com/file/d/\(FormEncoding.escape(fileID))/view")!
    }

    /// A link that serves the image bytes of a file shared by link. Google does
    /// not document this form and may change it; it is kept here in one place
    /// so it is easy to replace.
    static func directImageURL(_ fileID: String) -> URL {
        URL(string: "https://drive.google.com/uc?export=view&id=\(FormEncoding.escape(fileID))")!
    }

    // MARK: - Folder

    private func ensureFolder() async throws -> String {
        try await folderLookup().value
    }

    private func folderLookup() -> Task<String, Error> {
        lock.lock(); defer { lock.unlock() }
        if let running = folderTask { return running }
        let task = Task { [self] () async throws -> String in
            defer { folderLookupFinished() }
            return try await resolveFolder()
        }
        folderTask = task
        return task
    }

    private func folderLookupFinished() {
        lock.lock(); defer { lock.unlock() }
        folderTask = nil
    }

    private func resolveFolder() async throws -> String {
        if let cached = cachedFolderID(), !cached.isEmpty {
            if try await folderIsUsable(cached) { return cached }
            storeFolderID(nil)
        }
        if let found = try await searchFolder() {
            storeFolderID(found)
            return found
        }
        let created = try await createFolder()
        storeFolderID(created)
        return created
    }

    private func folderIsUsable(_ id: String) async throws -> Bool {
        let url = GoogleDriveUploader.url(GoogleDriveUploader.filesEndpoint.appendingPathComponent(id),
                                          query: [("fields", "id,trashed")])
        let (data, response) = try await send { token in
            GoogleDriveUploader.request(url, method: "GET", token: token)
        }
        if response.statusCode == 404 { return false }
        try GoogleDriveUploader.requireSuccess(data, response)
        let trashed = JSONBody.object(data)?["trashed"] as? Bool ?? false
        return !trashed
    }

    private func searchFolder() async throws -> String? {
        // Drive's query language quotes with single quotes and escapes with a
        // backslash.
        let quotedName = folderName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let q = "mimeType = '\(GoogleDriveUploader.folderMimeType)' and name = '\(quotedName)' and trashed = false"
        let url = GoogleDriveUploader.url(GoogleDriveUploader.filesEndpoint, query: [
            ("q", q),
            ("fields", "files(id,name)"),
        ])
        let (data, response) = try await send { token in
            GoogleDriveUploader.request(url, method: "GET", token: token)
        }
        try GoogleDriveUploader.requireSuccess(data, response)
        guard let files = JSONBody.object(data)?["files"] as? [[String: Any]] else {
            throw CloudError.badResponse("No file list in the search answer")
        }
        return files.lazy.compactMap { $0["id"] as? String }.first { !$0.isEmpty }
    }

    private func createFolder() async throws -> String {
        let url = GoogleDriveUploader.url(GoogleDriveUploader.filesEndpoint, query: [("fields", "id")])
        let body = JSONBody.data(["name": folderName, "mimeType": GoogleDriveUploader.folderMimeType])
        let (data, response) = try await send { token in
            var request = GoogleDriveUploader.request(url, method: "POST", token: token)
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            return request
        }
        try GoogleDriveUploader.requireSuccess(data, response)
        guard let id = JSONBody.object(data)?["id"] as? String, !id.isEmpty else {
            throw CloudError.badResponse("No folder ID in the answer")
        }
        return id
    }

    // MARK: - Requests

    /// Sends a Drive request built for a token. A 401 means the token was not
    /// accepted: ask for a token again and repeat the call once.
    private func send(_ build: (String) -> URLRequest) async throws -> (Data, HTTPURLResponse) {
        let token = try await tokens.validAccessToken()
        let first = try await perform(build(token))
        guard first.1.statusCode == 401 else { return first }

        tokens.invalidate(accessToken: token)
        let retryToken = try await tokens.validAccessToken()
        return try await perform(build(retryToken))
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch {
            throw transportError(error)
        }
    }

    private static func request(_ url: URL, method: String, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func requireSuccess(_ data: Data, _ response: HTTPURLResponse) throws {
        guard isSuccess(response) else {
            throw CloudError.server(status: response.statusCode,
                                    message: JSONBody.googleMessage(data, status: response.statusCode))
        }
    }

    static func url(_ base: URL, query: [(String, String)]) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.percentEncodedQuery = FormEncoding.encode(query)
        return components.url ?? base
    }

    static func multipartBody(boundary: String, fileName: String, folderID: String,
                              mimeType: String, data: Data) -> Data {
        let metadata = JSONBody.data(["name": fileName, "parents": [folderID]])
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(metadata)
        body.append(Data("\r\n--\(boundary)\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}
