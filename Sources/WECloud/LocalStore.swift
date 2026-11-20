import Darwin
import Foundation

/// Small secrets as private files, one file per value.
///
/// This is used instead of the keychain on purpose: the app is signed with a
/// self-signed certificate, and macOS binds such an app's keychain items to
/// the exact build, so every update would ask for the keychain password.
public final class LocalSecretStore: @unchecked Sendable {
    private static let maxFileSize = 64 * 1024

    private let directory: URL
    // Serializes writers and readers inside the process.
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
    }

    /// The store in the app's own folder. One instance, so that its lock
    /// really covers every reader and writer in the process.
    public static let shared = LocalSecretStore(directory: LocalSecretStore.defaultDirectory)

    /// The file exists but cannot be trusted as a stored value.
    struct Damaged: Error {}

    /// `<Application Support>/WE Screenshot`.
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("WE Screenshot", isDirectory: true)
    }

    /// The stored value, nil when there is no file.
    public func string(for name: String) throws -> String? {
        do {
            return try read(name)
        } catch is Damaged {
            throw Self.failure("The secret file is damaged.")
        }
    }

    /// Like string(for:), but a file that is not a usable value (a symbolic
    /// link, not a regular file, too large, not text) throws Damaged, so that
    /// callers can tell it from a real input or output error.
    func read(_ name: String) throws -> String? {
        try Self.validate(name)
        lock.lock(); defer { lock.unlock() }
        guard try directoryIsUsable() else { return nil }
        let path = fileURL(name).path
        // O_NOFOLLOW makes a symbolic link at the path an error, not a detour.
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        if fd < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw Damaged() }
            throw Self.failure("The secret file cannot be opened.")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Self.failure("The secret file cannot be read.") }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= off_t(Self.maxFileSize) else {
            throw Damaged()
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw Self.failure("The secret file cannot be read.")
            }
            if count == 0 { break }
            data.append(buffer, count: count)
            if data.count > Self.maxFileSize { throw Damaged() }
        }
        guard let text = String(data: data, encoding: .utf8) else { throw Damaged() }
        return text
    }

    /// False when the folder does not exist yet. A folder that is a link, not
    /// a folder, or owned by someone else is never used.
    private func directoryIsUsable() throws -> Bool {
        var info = stat()
        guard lstat(directory.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw Self.failure("The secret folder cannot be read.")
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw Self.failure("The secret folder is not a folder.")
        }
        guard info.st_uid == getuid() else {
            throw Self.failure("The secret folder does not belong to this user.")
        }
        return true
    }

    /// Stores the value; nil or an empty string removes the file.
    public func set(_ value: String?, for name: String) throws {
        try Self.validate(name)
        lock.lock(); defer { lock.unlock() }
        let target = fileURL(name)
        guard let value = value, !value.isEmpty else {
            if unlink(target.path) != 0 && errno != ENOENT {
                throw Self.failure("The secret file cannot be removed.")
            }
            return
        }
        try prepareDirectory()
        let temp = directory.appendingPathComponent(".\(name).\(UUID().uuidString).tmp").path
        // O_EXCL and O_NOFOLLOW: only ever write into a file created right here.
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Self.failure("The secret file cannot be created.") }
        var finished = false
        defer { if !finished { unlink(temp) } }
        do {
            // The creation mode is filtered by the umask, so set it explicitly.
            guard fchmod(fd, 0o600) == 0 else { throw Self.failure("The secret file permissions cannot be set.") }
            let bytes = Array(value.utf8)
            var offset = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                if written < 0 {
                    if errno == EINTR { continue }
                    throw Self.failure("The secret file cannot be written.")
                }
                offset += written
            }
            fsync(fd)
        } catch {
            close(fd)
            throw error
        }
        close(fd)
        // rename replaces a symbolic link at the target instead of following it.
        guard rename(temp, target.path) == 0 else { throw Self.failure("The secret file cannot be replaced.") }
        finished = true
        // Best effort: keep the secret out of backups.
        var url = target
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private func fileURL(_ name: String) -> URL {
        directory.appendingPathComponent("\(name).secret", isDirectory: false)
    }

    private func prepareDirectory() throws {
        var info = stat()
        if lstat(directory.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                throw Self.failure("The secret folder is not a folder.")
            }
            guard info.st_uid == getuid() else {
                throw Self.failure("The secret folder does not belong to this user.")
            }
            if (info.st_mode & 0o777) != 0o700 {
                guard chmod(directory.path, 0o700) == 0 else {
                    throw Self.failure("The secret folder permissions cannot be set.")
                }
            }
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw Self.failure("The secret folder cannot be created.")
        }
        // The umask may have narrowed or the system widened the mode: be exact.
        guard chmod(directory.path, 0o700) == 0 else {
            throw Self.failure("The secret folder permissions cannot be set.")
        }
    }

    private static func validate(_ name: String) throws {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard !name.isEmpty, name.allSatisfy({ allowed.contains($0) }) else {
            throw failure("The secret name is not valid.")
        }
    }

    private static func failure(_ text: String) -> CloudError {
        .badResponse(text)
    }
}

/// Tokens in a private file of the app (one JSON document).
public final class FileTokenStore: TokenStore, @unchecked Sendable {
    private let store: LocalSecretStore
    private let name: String

    public init(store: LocalSecretStore = .shared, name: String = "oauth-tokens") {
        self.store = store
        self.name = name
    }

    public func load() throws -> OAuthTokens? {
        // A damaged file means "signed out": the user signs in again instead
        // of being stuck with an error. Real read errors are still reported.
        let json: String?
        do {
            json = try store.read(name)
        } catch is LocalSecretStore.Damaged {
            return nil
        }
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? TokenCoding.decoder.decode(OAuthTokens.self, from: data)
    }

    public func save(_ tokens: OAuthTokens) throws {
        let data = try TokenCoding.encoder.encode(tokens)
        try store.set(String(decoding: data, as: UTF8.self), for: name)
    }

    public func clear() throws {
        try store.set(nil, for: name)
    }
}
