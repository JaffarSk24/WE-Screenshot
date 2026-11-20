import Foundation

// Virtual key codes are the kVK_ values from Carbon's Events.h, written as
// numbers so that WECore does not import Carbon.
private let functionKeyCodes: [UInt32: String] = [
    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
    101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
    106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
]

private let keyNames: [UInt32: String] = {
    var names: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "\u{21A9}", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "\u{21E5}", 49: "Space",
        50: "`", 51: "\u{232B}", 53: "\u{238B}",
        115: "Home", 116: "Page Up", 117: "\u{2326}", 119: "End", 121: "Page Down",
        123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
    ]
    for (code, name) in functionKeyCodes { names[code] = name }
    return names
}()

public extension KeyCombo {
    /// The shortcut as the user reads it, modifiers in the macOS order
    /// (Control, Option, Shift, Command) followed by the key: "⇧⌘9", "⌃⌥F5".
    /// Keys are named by their US layout legend; unknown codes give "Key 123".
    var displayString: String {
        var text = ""
        if modifiers.contains(.control) { text += "\u{2303}" }
        if modifiers.contains(.option) { text += "\u{2325}" }
        if modifiers.contains(.shift) { text += "\u{21E7}" }
        if modifiers.contains(.command) { text += "\u{2318}" }
        text += keyNames[keyCode] ?? "Key \(keyCode)"
        return text
    }

    /// A shortcut is acceptable as a global hotkey when it has Command or
    /// Control, or when the key is a function key. Option and Shift alone are
    /// not enough.
    var isValidGlobalHotKey: Bool {
        if functionKeyCodes[keyCode] != nil { return true }
        if modifiers.contains(.command) || modifiers.contains(.control) { return true }
        // Option or Option+Shift on a normal key types a character, and macOS 15
        // refuses to register such combinations.
        return false
    }
}

public enum FileNamer {
    /// "Screenshot 2026-11-20 at 10.31.05.png". The date is formatted in the
    /// given time zone (the caller passes the local one), never in UTC.
    public static func defaultName(date: Date, format: ImageFormat, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screenshot \(formatter.string(from: date)).\(format.fileExtension)"
    }

    /// A URL in the directory that does not exist yet: the name itself, or
    /// "name 2.ext", "name 3.ext"... `exists` answers whether a path is taken.
    public static func uniqueURL(directory: URL, fileName: String, exists: (URL) -> Bool) -> URL {
        let first = directory.appendingPathComponent(fileName)
        if !exists(first) { return first }
        let ext = (fileName as NSString).pathExtension
        let base = (fileName as NSString).deletingPathExtension
        var counter = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            let url = directory.appendingPathComponent(name)
            if !exists(url) { return url }
            counter += 1
        }
    }
}

public enum Versions {
    /// Compares dotted numeric versions ("1.10.0" is newer than "1.9.3").
    /// Missing parts count as zero; non-numeric parts compare as zero.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func parts(_ version: String) -> [Int] {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        return text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
    }
}

/// What the updater needs from GitHub's "latest release" answer.
public struct ReleaseInfo: Equatable, Sendable {
    public let version: String
    public let notes: String
    public let assetURL: URL
    public let assetSize: Int

    public init(version: String, notes: String, assetURL: URL, assetSize: Int) {
        self.version = version
        self.notes = notes
        self.assetURL = assetURL
        self.assetSize = assetSize
    }

    /// The only attachment name the updater accepts for a version.
    public static func assetName(version: String) -> String {
        "WE-Screenshot-\(version).zip"
    }

    /// Parses the JSON of api.github.com/repos/.../releases/latest. The tag is
    /// "vX.Y.Z" or "X.Y.Z"; returns nil when the JSON is not a release or has
    /// no attachment named exactly assetName(version:).
    public static func parse(githubJSON data: Data) -> ReleaseInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String else { return nil }
        var version = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.hasPrefix("v") || version.hasPrefix("V") { version.removeFirst() }
        guard !version.isEmpty, let assets = root["assets"] as? [[String: Any]] else { return nil }
        let wanted = assetName(version: version)
        for asset in assets {
            guard asset["name"] as? String == wanted,
                  let link = asset["browser_download_url"] as? String,
                  let url = URL(string: link), url.scheme == "https" else { continue }
            let size = (asset["size"] as? NSNumber)?.intValue ?? 0
            return ReleaseInfo(version: version, notes: root["body"] as? String ?? "",
                               assetURL: url, assetSize: size)
        }
        return nil
    }

    /// Release notes as plain text for an alert: Markdown marks removed,
    /// "- " bullets turned into "• ", cut at the first "## " heading or a line
    /// starting with "SHA-256" or "Install", at most 900 characters.
    public static func plainNotes(_ markdown: String) -> String {
        let normalised = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        var lines: [String] = []
        for raw in normalised.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") { break }
            var line = trimmed
            // Remaining heading marks ("# Title", "### Title").
            while line.hasPrefix("#") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            var bullet = false
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                bullet = true
                line = String(line.dropFirst(2))
            }
            line = stripInlineMarks(line).trimmingCharacters(in: .whitespaces)
            // Bullets are changelog entries, so only plain lines can end the notes.
            if !bullet, isTrailerLine(line) { break }
            lines.append(bullet ? "\u{2022} " + line : line)
        }
        var result: [String] = []
        for line in lines {
            if line.isEmpty, result.last?.isEmpty ?? true { continue }
            result.append(line)
        }
        var text = result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 900 {
            text = String(text.prefix(899)).trimmingCharacters(in: .whitespacesAndNewlines) + "\u{2026}"
        }
        return text
    }

    /// "SHA-256..." or the word Install/Installation ("Installer is smaller" is not one).
    private static func isTrailerLine(_ line: String) -> Bool {
        if line.hasPrefix("SHA-256") { return true }
        for word in ["Installation", "Install"] where line.hasPrefix(word) {
            let rest = line.dropFirst(word.count)
            if rest.first.map({ !$0.isLetter && !$0.isNumber }) ?? true { return true }
        }
        return false
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: template)
    }

    private static func stripInlineMarks(_ text: String) -> String {
        // Images keep the alt text, links keep the label.
        var result = replacing("!\\[([^\\]]*)\\]\\([^)]*\\)", in: text, with: "$1")
        result = replacing("\\[([^\\]]*)\\]\\([^)]*\\)", in: result, with: "$1")
        // Emphasis only at word boundaries, so snake_case and 2*3*4 survive.
        result = replacing("(?<![\\w*])\\*\\*(?=\\S)(.+?)(?<=\\S)\\*\\*(?![\\w*])", in: result, with: "$1")
        result = replacing("(?<![\\w_])__(?=\\S)(.+?)(?<=\\S)__(?![\\w_])", in: result, with: "$1")
        result = replacing("(?<![\\w*])\\*(?=\\S)(.+?)(?<=\\S)\\*(?![\\w*])", in: result, with: "$1")
        result = replacing("(?<![\\w_])_(?=\\S)(.+?)(?<=\\S)_(?![\\w_])", in: result, with: "$1")
        result = result.replacingOccurrences(of: "`", with: "")
        return result
    }
}

public enum ReverseImageSearch {
    /// The page that searches for images similar to the one at a public URL.
    public static func url(forImageURL imageURL: URL) -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = imageURL.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "https://lens.google.com/uploadbyurl?url=" + encoded)!
    }
}
