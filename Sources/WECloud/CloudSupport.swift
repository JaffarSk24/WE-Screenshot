import CryptoKit
import Foundation
import Security

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum SecureRandom {
    static func bytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        // Without a working random source PKCE and the state are worthless;
        // continuing would silently weaken the sign-in.
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes)
    }

    /// URL safe random text with `byteCount` bytes of entropy.
    static func token(byteCount: Int = 32) -> String {
        Base64URL.encode(bytes(byteCount))
    }
}

enum SHA256Digest {
    static func hash(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

/// Comparison whose duration does not depend on where the inputs differ.
func constantTimeEquals(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    var difference: UInt8 = 0
    for i in 0..<x.count { difference |= x[i] ^ y[i] }
    return difference == 0
}

enum FormEncoding {
    /// RFC 3986 unreserved characters; everything else is percent-encoded,
    /// which is correct both for query strings and form bodies.
    private static let unreserved: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return set
    }()

    static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    static func encode(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }

    /// Decodes "a=1&b=x+y" style text; "+" is a space. The first occurrence
    /// of a name wins, so a repeated parameter cannot override the real one.
    static func decode(_ query: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in query.split(separator: "&", omittingEmptySubsequences: true) {
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = decodeComponent(String(pieces[0]))
            let value = pieces.count > 1 ? decodeComponent(String(pieces[1])) : ""
            if !name.isEmpty, result[name] == nil { result[name] = value }
        }
        return result
    }

    private static func decodeComponent(_ text: String) -> String {
        let spaced = text.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }
}

enum TokenCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

enum ErrorText {
    /// Makes a message from a server or the system safe to show: anything
    /// that looks like a credential is cut out and the length is limited.
    /// Google's messages do not normally contain tokens, but an error text is
    /// the kind of thing that ends up in a bug report.
    static func sanitized(_ message: String) -> String {
        var words: [String] = []
        for word in message.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }) {
            words.append(looksLikeSecret(word) ? "[hidden]" : String(word))
        }
        var text = words.joined(separator: " ")
        if text.count > 200 { text = String(text.prefix(200)) + "..." }
        return text
    }

    private static func looksLikeSecret(_ word: Substring) -> Bool {
        let lower = word.lowercased()
        if lower.contains("ya29.") || lower.contains("1//") || lower.contains("token=")
            || lower.contains("code=") || lower.contains("secret") || lower.contains("bearer") {
            return true
        }
        // Long runs of token alphabet characters with digits are not words.
        let core = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()[]{}\"'"))
        guard core.count >= 20 else { return false }
        let tokenAlphabet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./+=~"))
        let allTokenLike = core.unicodeScalars.allSatisfy { tokenAlphabet.contains($0) }
        let hasDigit = core.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
        return allTokenLike && hasDigit
    }
}

enum JSONBody {
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func data(_ object: [String: Any]) -> Data {
        // Only plain strings and arrays of strings are passed in, so this
        // cannot fail; sorted keys keep the bodies stable for tests.
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// Google's error text: Drive uses {"error": {"message": ...}}, the
    /// token endpoint {"error": "...", "error_description": "..."}.
    static func googleMessage(_ data: Data, status: Int) -> String {
        if let json = object(data) {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let description = json["error_description"] as? String { return description }
            if let error = json["error"] as? String { return error }
        }
        return HTTPURLResponse.localizedString(forStatusCode: status)
    }

    /// The "reason" of the first entry of Drive's error list, if any.
    static func googleReason(_ data: Data) -> String? {
        guard let json = object(data), let error = json["error"] as? [String: Any],
              let errors = error["errors"] as? [[String: Any]] else { return nil }
        return errors.first?["reason"] as? String
    }
}

func isSuccess(_ response: HTTPURLResponse) -> Bool {
    (200..<300).contains(response.statusCode)
}

/// Turns a transport failure into a CloudError. URLError texts do not carry
/// request bodies or headers, so they are safe to pass on.
func networkError(_ error: Error) -> CloudError {
    if let cloud = error as? CloudError { return cloud }
    return .network(error.localizedDescription)
}
