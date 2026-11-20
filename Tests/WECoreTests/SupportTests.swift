import XCTest
@testable import WECore

final class KeyComboTests: XCTestCase {
    func testDisplayString() {
        XCTAssertEqual(KeyCombo.defaultCapture.displayString, "\u{21E7}\u{2318}9")
        XCTAssertEqual(KeyCombo(keyCode: 96, modifiers: [.control, .option]).displayString, "\u{2303}\u{2325}F5")
        XCTAssertEqual(KeyCombo(keyCode: 49, modifiers: [.command]).displayString, "\u{2318}Space")
        XCTAssertEqual(KeyCombo(keyCode: 36, modifiers: [.command, .shift, .option, .control]).displayString,
                       "\u{2303}\u{2325}\u{21E7}\u{2318}\u{21A9}")
        XCTAssertEqual(KeyCombo(keyCode: 123, modifiers: [.command]).displayString, "\u{2318}\u{2190}")
        XCTAssertEqual(KeyCombo(keyCode: 27, modifiers: [.command]).displayString, "\u{2318}-")
        XCTAssertEqual(KeyCombo(keyCode: 0, modifiers: [.control]).displayString, "\u{2303}A")
        XCTAssertEqual(KeyCombo(keyCode: 90, modifiers: []).displayString, "F20")
        XCTAssertEqual(KeyCombo(keyCode: 200, modifiers: [.command]).displayString, "\u{2318}Key 200")
    }

    func testEveryNamedKeyIsDistinct() {
        var seen = Set<String>()
        for code in 0..<128 {
            let name = KeyCombo(keyCode: UInt32(code), modifiers: []).displayString
            if name.hasPrefix("Key ") { continue }
            XCTAssertTrue(seen.insert(name).inserted, "duplicate \(name)")
        }
        XCTAssertGreaterThanOrEqual(seen.count, 80)
    }

    func testValidGlobalHotKey() {
        XCTAssertTrue(KeyCombo.defaultCapture.isValidGlobalHotKey)
        XCTAssertTrue(KeyCombo(keyCode: 0, modifiers: [.control]).isValidGlobalHotKey)
        XCTAssertTrue(KeyCombo(keyCode: 0, modifiers: [.option, .command]).isValidGlobalHotKey)
        XCTAssertTrue(KeyCombo(keyCode: 122, modifiers: []).isValidGlobalHotKey)
        XCTAssertTrue(KeyCombo(keyCode: 122, modifiers: [.option]).isValidGlobalHotKey)
        XCTAssertFalse(KeyCombo(keyCode: 0, modifiers: []).isValidGlobalHotKey)
        XCTAssertFalse(KeyCombo(keyCode: 0, modifiers: [.shift]).isValidGlobalHotKey)
        XCTAssertFalse(KeyCombo(keyCode: 0, modifiers: [.option]).isValidGlobalHotKey)
        XCTAssertFalse(KeyCombo(keyCode: 0, modifiers: [.option, .shift]).isValidGlobalHotKey)
    }
}

final class FileNamerTests: XCTestCase {
    func testDefaultNameUsesGivenTimeZone() {
        // 2026-11-20 23:30:05 UTC is already 2026-11-21 00:30:05 in Bratislava.
        let date = Date(timeIntervalSince1970: 1_795_217_405)
        let utc = TimeZone(identifier: "UTC")!
        let bratislava = TimeZone(identifier: "Europe/Bratislava")!
        XCTAssertEqual(FileNamer.defaultName(date: date, format: .png, timeZone: utc),
                       "Screenshot 2026-11-20 at 23.30.05.png")
        XCTAssertEqual(FileNamer.defaultName(date: date, format: .jpeg, timeZone: bratislava),
                       "Screenshot 2026-11-21 at 00.30.05.jpg")
    }

    func testUniqueURL() {
        let dir = URL(fileURLWithPath: "/tmp/x")
        XCTAssertEqual(FileNamer.uniqueURL(directory: dir, fileName: "a.png", exists: { _ in false }).lastPathComponent, "a.png")
        var taken: Set<String> = ["a.png"]
        XCTAssertEqual(FileNamer.uniqueURL(directory: dir, fileName: "a.png", exists: { taken.contains($0.lastPathComponent) }).lastPathComponent, "a 2.png")
        taken.insert("a 2.png")
        taken.insert("a 3.png")
        XCTAssertEqual(FileNamer.uniqueURL(directory: dir, fileName: "a.png", exists: { taken.contains($0.lastPathComponent) }).lastPathComponent, "a 4.png")
        taken = ["note", "note 2"]
        XCTAssertEqual(FileNamer.uniqueURL(directory: dir, fileName: "note", exists: { taken.contains($0.lastPathComponent) }).lastPathComponent, "note 3")
        XCTAssertEqual(FileNamer.uniqueURL(directory: dir, fileName: "a.png", exists: { _ in false }).deletingLastPathComponent().path, "/tmp/x")
    }
}

final class VersionsTests: XCTestCase {
    func testIsNewer() {
        XCTAssertTrue(Versions.isNewer("1.10.0", than: "1.9.3"))
        XCTAssertFalse(Versions.isNewer("1.9.3", than: "1.10.0"))
        XCTAssertFalse(Versions.isNewer("1.2.3", than: "1.2.3"))
        XCTAssertFalse(Versions.isNewer("1.2", than: "1.2.0"))
        XCTAssertTrue(Versions.isNewer("1.2.1", than: "1.2"))
        XCTAssertTrue(Versions.isNewer("2", than: "1.9.9"))
        XCTAssertTrue(Versions.isNewer("v1.1.0", than: "1.0.9"))
        XCTAssertFalse(Versions.isNewer("1.0.0", than: "v1.0.0"))
        XCTAssertFalse(Versions.isNewer("abc", than: "0.0.1"))
        XCTAssertTrue(Versions.isNewer("1.x.1", than: "1.0.0"))
    }
}

final class ReleaseInfoTests: XCTestCase {
    private func json(tag: String = "v1.2.0", assetName: String = "WE-Screenshot-1.2.0.zip", body: String? = "Notes") -> Data {
        var object: [String: Any] = [
            "tag_name": tag,
            "assets": [
                ["name": "Source.zip", "browser_download_url": "https://example.com/Source.zip", "size": 5],
                ["name": assetName, "browser_download_url": "https://github.com/o/r/releases/download/\(tag)/\(assetName)", "size": 123_456],
            ],
        ]
        if let body { object["body"] = body }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testParseMatchingAsset() {
        let info = ReleaseInfo.parse(githubJSON: json())
        XCTAssertEqual(info?.version, "1.2.0")
        XCTAssertEqual(info?.notes, "Notes")
        XCTAssertEqual(info?.assetSize, 123_456)
        XCTAssertEqual(info?.assetURL.lastPathComponent, "WE-Screenshot-1.2.0.zip")
    }

    func testTagWithoutV() {
        XCTAssertEqual(ReleaseInfo.parse(githubJSON: json(tag: "1.2.0"))?.version, "1.2.0")
    }

    func testWrongAssetName() {
        XCTAssertNil(ReleaseInfo.parse(githubJSON: json(assetName: "WE-Screenshot-1.1.0.zip")))
        XCTAssertNil(ReleaseInfo.parse(githubJSON: json(assetName: "we-screenshot-1.2.0.zip")))
    }

    func testMissingFields() {
        XCTAssertNil(ReleaseInfo.parse(githubJSON: Data("not json".utf8)))
        XCTAssertNil(ReleaseInfo.parse(githubJSON: Data("[]".utf8)))
        XCTAssertNil(ReleaseInfo.parse(githubJSON: Data(#"{"assets":[]}"#.utf8)))
        XCTAssertNil(ReleaseInfo.parse(githubJSON: Data(#"{"tag_name":"v1.0.0"}"#.utf8)))
        XCTAssertNil(ReleaseInfo.parse(githubJSON: Data(#"{"tag_name":"v1.0.0","assets":[{"name":"WE-Screenshot-1.0.0.zip"}]}"#.utf8)))
        XCTAssertEqual(ReleaseInfo.parse(githubJSON: json(body: nil))?.notes, "")
    }

    func testNonHTTPSAssetIsRejected() {
        let data = Data(#"{"tag_name":"v1.0.0","assets":[{"name":"WE-Screenshot-1.0.0.zip","browser_download_url":"http://x.test/a.zip","size":1}]}"#.utf8)
        XCTAssertNil(ReleaseInfo.parse(githubJSON: data))
    }

    func testAssetName() {
        XCTAssertEqual(ReleaseInfo.assetName(version: "1.2.0"), "WE-Screenshot-1.2.0.zip")
    }

    func testPlainNotes() {
        let md = "### What's new\n\n- **Faster** capture\n- Fixed `crash` in [settings](https://x.test)\n\n\n* Star bullet\n\n## Install\nDrag the app.\nSHA-256: abc"
        XCTAssertEqual(ReleaseInfo.plainNotes(md),
                       "What's new\n\n\u{2022} Faster capture\n\u{2022} Fixed crash in settings\n\n\u{2022} Star bullet")
    }

    func testPlainNotesCutsAtInstallAndSHALines() {
        XCTAssertEqual(ReleaseInfo.plainNotes("Line one\nInstall with brew\nmore"), "Line one")
        XCTAssertEqual(ReleaseInfo.plainNotes("Line one\nSHA-256: abc"), "Line one")
        XCTAssertEqual(ReleaseInfo.plainNotes("Line one\r\nLine two"), "Line one\nLine two")
        XCTAssertEqual(ReleaseInfo.plainNotes(""), "")
    }

    func testPlainNotesLimit() {
        let long = String(repeating: "word ", count: 500)
        let text = ReleaseInfo.plainNotes(long)
        XCTAssertLessThanOrEqual(text.count, 900)
        XCTAssertTrue(text.hasSuffix("\u{2026}"))
    }
}

final class ReverseImageSearchTests: XCTestCase {
    func testEscaping() {
        let image = URL(string: "https://drive.example.com/file?id=1&x=2#frag")!
        let url = ReverseImageSearch.url(forImageURL: image)
        XCTAssertTrue(url.absoluteString.hasPrefix("https://lens.google.com/uploadbyurl?url="))
        let query = url.absoluteString.replacingOccurrences(of: "https://lens.google.com/uploadbyurl?url=", with: "")
        for bad in ["&", "=", "?", "#"] { XCTAssertFalse(query.contains(bad), bad) }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.count, 1)
        XCTAssertEqual(items?.first?.value, image.absoluteString)
    }
}

final class SettingsAndColorTests: XCTestCase {
    private func withStore(_ body: (SettingsStore, UserDefaults) -> Void) {
        let name = "we.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(SettingsStore(defaults: defaults), defaults)
    }

    func testDefaults() {
        withStore { store, _ in
            XCTAssertEqual(store.captureHotKey, .defaultCapture)
            XCTAssertEqual(store.imageFormat, .png)
            XCTAssertEqual(store.jpegQuality, 0.9, accuracy: 0.0001)
            XCTAssertEqual(store.drawingColor, .red)
            XCTAssertNil(store.lastSaveDirectory)
            XCTAssertFalse(store.openLinkAfterUpload)
            XCTAssertTrue(store.autoCheckUpdates)
            XCTAssertNil(store.skippedVersion)
            XCTAssertFalse(store.didFirstLaunch)
            XCTAssertFalse(store.downscaleRetina)
            XCTAssertNil(store.googleClientID)
            XCTAssertNil(store.driveFolderID)
            XCTAssertNil(store.googleAccountLabel)
        }
    }

    func testRoundTrip() {
        withStore { store, defaults in
            let combo = KeyCombo(keyCode: 1, modifiers: [.control, .option])
            store.captureHotKey = combo
            store.imageFormat = .jpeg
            store.jpegQuality = 0.5
            store.drawingColor = RGBAColor(red: 0, green: 0.5, blue: 1, alpha: 0.5)
            store.lastSaveDirectory = "/tmp/shots"
            store.openLinkAfterUpload = true
            store.autoCheckUpdates = false
            store.skippedVersion = "1.2.0"
            store.didFirstLaunch = true
            store.downscaleRetina = true
            store.googleClientID = "  abc.apps  "
            store.driveFolderID = "folder"
            store.googleAccountLabel = "me@example.com"
            let other = SettingsStore(defaults: defaults)
            XCTAssertEqual(other.captureHotKey, combo)
            XCTAssertEqual(other.imageFormat, .jpeg)
            XCTAssertEqual(other.jpegQuality, 0.5, accuracy: 0.0001)
            XCTAssertEqual(other.drawingColor, RGBAColor(red: 0, green: 0.5, blue: 1, alpha: 0.5))
            XCTAssertEqual(other.lastSaveDirectory, "/tmp/shots")
            XCTAssertTrue(other.openLinkAfterUpload)
            XCTAssertFalse(other.autoCheckUpdates)
            XCTAssertEqual(other.skippedVersion, "1.2.0")
            XCTAssertTrue(other.didFirstLaunch)
            XCTAssertTrue(other.downscaleRetina)
            XCTAssertEqual(other.googleClientID, "abc.apps")
            XCTAssertEqual(other.driveFolderID, "folder")
            XCTAssertEqual(other.googleAccountLabel, "me@example.com")
            store.jpegQuality = 5
            XCTAssertEqual(store.jpegQuality, 1, accuracy: 0.0001)
            store.googleClientID = "   "
            XCTAssertNil(store.googleClientID)
        }
    }

    func testHexParsing() {
        let c = RGBAColor(hex: "#FF8000")
        XCTAssertEqual(c?.red ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(c?.green ?? 0, 128.0 / 255, accuracy: 0.001)
        XCTAssertEqual(c?.blue ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(c?.alpha ?? 0, 1, accuracy: 0.001)
        let a = RGBAColor(hex: "00ff0080")
        XCTAssertEqual(a?.green ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(a?.alpha ?? 0, 128.0 / 255, accuracy: 0.001)
        XCTAssertNil(RGBAColor(hex: "#12345"))
        XCTAssertNil(RGBAColor(hex: "#GGGGGG"))
        XCTAssertNil(RGBAColor(hex: ""))
        XCTAssertEqual(RGBAColor.red.withAlpha(0.3).alpha, 0.3, accuracy: 0.0001)
    }
}
