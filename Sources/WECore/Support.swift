import Foundation

// CONTRACT STUB. The public declarations are fixed; the bodies are placeholders.

public extension KeyCombo {
    /// The shortcut as the user reads it, modifiers in the macOS order
    /// (Control, Option, Shift, Command) followed by the key: "⇧⌘9", "⌃⌥F5".
    /// Keys are named by their US layout legend; unknown codes give "Key 123".
    var displayString: String {
        fatalError("stub")
    }

    /// A shortcut is acceptable as a global hotkey when it has Command, Control
    /// or Option (Shift alone is not enough), or when the key is a function key.
    var isValidGlobalHotKey: Bool {
        fatalError("stub")
    }
}

public enum FileNamer {
    /// "Screenshot 2026-11-20 at 10.31.05.png". The date is formatted in the
    /// given time zone (the caller passes the local one), never in UTC.
    public static func defaultName(date: Date, format: ImageFormat, timeZone: TimeZone) -> String {
        fatalError("stub")
    }

    /// A URL in the directory that does not exist yet: the name itself, or
    /// "name 2.ext", "name 3.ext"... `exists` answers whether a path is taken.
    public static func uniqueURL(directory: URL, fileName: String, exists: (URL) -> Bool) -> URL {
        fatalError("stub")
    }
}

public enum Versions {
    /// Compares dotted numeric versions ("1.10.0" is newer than "1.9.3").
    /// Missing parts count as zero; non-numeric parts compare as zero.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        fatalError("stub")
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
        fatalError("stub")
    }

    /// Release notes as plain text for an alert: Markdown marks removed,
    /// "- " bullets turned into "• ", cut at the first "## " heading or a line
    /// starting with "SHA-256" or "Install", at most 900 characters.
    public static func plainNotes(_ markdown: String) -> String {
        fatalError("stub")
    }
}

public enum ReverseImageSearch {
    /// The page that searches for images similar to the one at a public URL.
    public static func url(forImageURL imageURL: URL) -> URL {
        fatalError("stub")
    }
}
