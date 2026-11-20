import Foundation
import Network
import WECore

/// A one-shot HTTP listener on 127.0.0.1 that receives the OAuth redirect.
public final class LoopbackRedirectListener: @unchecked Sendable {
    /// The most the listener reads of one request; the request line is all
    /// it needs, and a bound keeps a misbehaving client from eating memory.
    static let maxRequestBytes = 16 * 1024
    /// A connection that sends nothing useful is dropped after this long.
    static let connectionTimeout: TimeInterval = 10

    private let queue = DispatchQueue(label: "sk.whiteeagles.screenshot.loopback")
    private let lock = NSLock()

    // All mutable state below is guarded by `lock`.
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var result: [String: String]?
    private var waiter: CheckedContinuation<[String: String], Error>?
    private var waitID = 0
    private var stopped = false
    private var cancelled = false

    public init() {}

    deinit {
        listener?.cancel()
        for connection in connections.values { connection.cancel() }
    }

    /// Starts listening on a free port of the loopback interface only and
    /// returns the redirect URI to send to Google: "http://127.0.0.1:PORT".
    public func start() async throws -> URL {
        let parameters = NWParameters.tcp
        // Bind to the IPv4 loopback address explicitly (never a wildcard
        // address), keep to the loopback interface and refuse remote peers.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = false

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw CloudError.network(error.localizedDescription)
        }

        guard install(listener) else {
            listener.cancel()
            throw CloudError.badResponse("Listener already used")
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue, once.claim() {
                        continuation.resume(returning: port)
                    }
                case let .failed(error):
                    if once.claim() { continuation.resume(throwing: CloudError.network(error.localizedDescription)) }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: CloudError.signInCancelled) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        // The handler captures the listener; dropping it breaks that cycle.
        listener.stateUpdateHandler = nil
        guard let url = URL(string: "http://127.0.0.1:\(port)") else {
            throw CloudError.badResponse("Bad loopback port")
        }
        return url
    }

    private func install(_ listener: NWListener) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if stopped || self.listener != nil { return false }
        self.listener = listener
        return true
    }

    /// Waits for the browser's request to the redirect URI and returns its
    /// query parameters ("code", "state", "error"...). The browser gets a small
    /// page saying the window can be closed. Requests for other paths (such as
    /// /favicon.ico) are answered with 404 and do not end the wait.
    /// Throws CloudError.signInCancelled after `timeout` seconds.
    public func waitForRedirect(timeout: TimeInterval) async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: String], Error>) in
                lock.lock()
                if let result = result {
                    lock.unlock()
                    continuation.resume(returning: result)
                    return
                }
                if stopped || cancelled || waiter != nil {
                    lock.unlock()
                    continuation.resume(throwing: CloudError.signInCancelled)
                    return
                }
                waiter = continuation
                waitID += 1
                let id = waitID
                lock.unlock()

                queue.asyncAfter(deadline: .now() + max(0, timeout)) { [weak self] in
                    self?.finishWait(id: id, with: .failure(CloudError.signInCancelled))
                }
            }
        } onCancel: {
            lock.lock()
            cancelled = true
            let pending = waiter
            waiter = nil
            lock.unlock()
            pending?.resume(throwing: CloudError.signInCancelled)
        }
    }

    public func stop() {
        lock.lock()
        stopped = true
        let listener = self.listener
        self.listener = nil
        let open = Array(connections.values)
        connections.removeAll()
        let pending = waiter
        waiter = nil
        lock.unlock()

        listener?.cancel()
        for connection in open { connection.cancel() }
        pending?.resume(throwing: CloudError.signInCancelled)
    }

    // MARK: - Connections

    private func finishWait(id: Int?, with outcome: Result<[String: String], Error>) {
        lock.lock()
        if let id = id, id != waitID {
            lock.unlock()
            return
        }
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(with: outcome)
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        if stopped {
            lock.unlock()
            connection.cancel()
            return
        }
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.forget(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + LoopbackRedirectListener.connectionTimeout) {
            connection.cancel()
        }
        receive(on: connection, buffer: Data())
    }

    private func forget(_ connection: NWConnection) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        let remaining = LoopbackRedirectListener.maxRequestBytes - buffer.count
        connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, remaining)) { [weak self] content, _, isComplete, error in
            guard let self = self else { connection.cancel(); return }
            var buffer = buffer
            if let content = content { buffer.append(content) }
            let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) != nil
            if headerEnd || isComplete || error != nil || buffer.count >= LoopbackRedirectListener.maxRequestBytes {
                self.handle(buffer, on: connection)
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func handle(_ request: Data, on connection: NWConnection) {
        guard let lineEnd = request.range(of: Data("\r\n".utf8)) ?? request.range(of: Data("\n".utf8)),
              let line = String(data: request[request.startIndex..<lineEnd.lowerBound], encoding: .utf8) else {
            respond(on: connection, status: "400 Bad Request", html: nil)
            return
        }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/") else {
            respond(on: connection, status: "400 Bad Request", html: nil)
            return
        }
        guard parts[0] == "GET" else {
            respond(on: connection, status: "405 Method Not Allowed", html: nil)
            return
        }
        let target = String(parts[1])
        let path: Substring
        let query: String
        if let mark = target.firstIndex(of: "?") {
            path = target[target.startIndex..<mark]
            query = String(target[target.index(after: mark)...])
        } else {
            path = Substring(target)
            query = ""
        }
        let parameters = FormEncoding.decode(query)
        // Only the root path carrying an OAuth answer ends the wait; anything
        // else (favicon, a stray prefetch of "/") is not the redirect.
        guard path == "/", parameters["code"] != nil || parameters["error"] != nil else {
            respond(on: connection, status: "404 Not Found", html: nil)
            return
        }

        let text = parameters["error"] != nil
            ? L("Sign-in was not completed. You can close this window.")
            : L("You can close this window and return to WE Screenshot.")
        respond(on: connection, status: "200 OK", html: LoopbackRedirectListener.page(text))

        lock.lock()
        let first = result == nil
        if first { result = parameters }
        lock.unlock()
        if first { finishWait(id: nil, with: .success(parameters)) }
    }

    private func respond(on connection: NWConnection, status: String, html: String?) {
        let body = Data((html ?? "").utf8)
        var head = "HTTP/1.1 \(status)\r\n"
        if html != nil {
            head += "Content-Type: text/html; charset=utf-8\r\n"
            head += "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Referrer-Policy: no-referrer\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        connection.send(content: data, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    static func page(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <title>WE Screenshot</title>
        <style>body{font:16px -apple-system,Helvetica,sans-serif;margin:0;display:flex;\
        align-items:center;justify-content:center;min-height:100vh;background:#f5f5f7;color:#1d1d1f}\
        p{max-width:28em;padding:24px;text-align:center}\
        @media(prefers-color-scheme:dark){body{background:#1d1d1f;color:#f5f5f7}}</style>
        </head><body><p>\(escaped)</p></body></html>
        """
    }
}

/// A flag that can be claimed once, from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
