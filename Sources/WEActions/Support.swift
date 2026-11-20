import AppKit
import WEAnnotate
import WECore

/// Brings the app forward before a modal alert or panel (the app is a menu bar
/// agent, so it is usually not the active one).
@MainActor
enum AppFocus {
    static func activate() {
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
enum Alerts {
    /// A plain information alert with one OK button.
    static func inform(_ title: String, _ text: String) {
        AppFocus.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }
}

/// The one place that turns a finished screenshot into file data.
enum ScreenshotEncoding {
    /// The image and scale to write: halved to one pixel per point when the
    /// setting asks for it and the display is Retina.
    static func prepared(_ screenshot: FinishedScreenshot, downscaleRetina: Bool) throws -> (image: CGImage, scale: CGFloat) {
        if downscaleRetina, screenshot.scale > 1 {
            return (try ImageComposer.downscaled(screenshot.image, fromScale: screenshot.scale), 1)
        }
        return (screenshot.image, screenshot.scale)
    }

    /// Encoded file data and the default file name, in the user's format.
    static func fileData(for screenshot: FinishedScreenshot, settings: SettingsStore) throws -> (data: Data, fileName: String) {
        let format = settings.imageFormat
        let prepared = try prepared(screenshot, downscaleRetina: settings.downscaleRetina)
        let data = try ImageEncoder.data(for: prepared.image, format: format, scale: prepared.scale,
                                         jpegQuality: settings.jpegQuality)
        let name = FileNamer.defaultName(date: Date(), format: format, timeZone: .current)
        return (data, name)
    }
}

/// Small decisions kept apart from the UI so they can be checked on their own.
enum ActionRules {
    static var desktopURL: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }

    static func isUsableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue && FileManager.default.isWritableFile(atPath: url.path)
    }

    /// Quick save folder: the remembered one while it still exists and is
    /// writable, else the Desktop.
    static func quickSaveDirectory(remembered: String?, desktop: URL,
                                   isUsable: (URL) -> Bool = ActionRules.isUsableDirectory) -> URL {
        if let remembered, !remembered.isEmpty {
            let url = URL(fileURLWithPath: remembered, isDirectory: true)
            if isUsable(url) { return url }
        }
        return desktop
    }

    /// Empty or blank input counts as "not set".
    static func normalized(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// True when either the client ID or the secret really changed.
    static func clientChanged(oldID: String?, newID: String?, oldSecret: String?, newSecret: String?) -> Bool {
        normalized(oldID) != normalized(newID) || normalized(oldSecret) != normalized(newSecret)
    }

    /// Size that fits into the printable area, never enlarged.
    static func fittedSize(_ size: CGSize, in available: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, available.width > 0, available.height > 0 else { return size }
        let factor = min(1, available.width / size.width, available.height / size.height)
        return CGSize(width: size.width * factor, height: size.height * factor)
    }
}
