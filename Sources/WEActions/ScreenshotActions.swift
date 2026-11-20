import AppKit
import UniformTypeIdentifiers
import WEAnnotate
import WECore

/// Carries out the action the user picked in the overlay.
@MainActor
public final class ScreenshotActions {
    private let settings: SettingsStore
    private let cloud: CloudCoordinator
    private let notifier: Notifier

    public init(settings: SettingsStore, cloud: CloudCoordinator, notifier: Notifier) {
        self.settings = settings
        self.cloud = cloud
        self.notifier = notifier
    }

    public func perform(_ action: ScreenshotAction, on screenshot: FinishedScreenshot) {
        switch action {
        case .copy: copy(screenshot)
        case .save: save(screenshot)
        case .quickSave: quickSave(screenshot)
        case .upload:
            let cloud = self.cloud
            Task { await cloud.upload(screenshot) }
        case .searchSimilar:
            let cloud = self.cloud
            Task {
                if let url = await cloud.uploadForSearch(screenshot) {
                    NSWorkspace.shared.open(ReverseImageSearch.url(forImageURL: url))
                }
            }
        case .print: printImage(screenshot)
        }
    }

    // MARK: Copy

    private func copy(_ screenshot: FinishedScreenshot) {
        do {
            let prepared = try ScreenshotEncoding.prepared(screenshot, downscaleRetina: settings.downscaleRetina)
            let png = try ImageEncoder.data(for: prepared.image, format: .png, scale: prepared.scale, jpegQuality: 1)
            let image = NSImage(cgImage: prepared.image, size: Self.pointSize(of: prepared.image, scale: prepared.scale))
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            if let tiff = image.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
        } catch {
            Alerts.inform(L("The screenshot was not copied."), error.localizedDescription)
        }
    }

    // MARK: Save

    private func save(_ screenshot: FinishedScreenshot) {
        let file: (data: Data, fileName: String)
        do {
            file = try ScreenshotEncoding.fileData(for: screenshot, settings: settings)
        } catch {
            Alerts.inform(L("The screenshot was not saved."), error.localizedDescription)
            return
        }
        AppFocus.activate()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [settings.imageFormat == .png ? UTType.png : UTType.jpeg]
        panel.nameFieldStringValue = file.fileName
        panel.canCreateDirectories = true
        panel.directoryURL = ActionRules.quickSaveDirectory(remembered: settings.lastSaveDirectory,
                                                            desktop: ActionRules.desktopURL)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try file.data.write(to: url, options: .atomic)
            settings.lastSaveDirectory = url.deletingLastPathComponent().path
        } catch {
            Alerts.inform(L("The screenshot was not saved."), error.localizedDescription)
        }
    }

    private func quickSave(_ screenshot: FinishedScreenshot) {
        do {
            let file = try ScreenshotEncoding.fileData(for: screenshot, settings: settings)
            let directory = ActionRules.quickSaveDirectory(remembered: settings.lastSaveDirectory,
                                                           desktop: ActionRules.desktopURL)
            let url = FileNamer.uniqueURL(directory: directory, fileName: file.fileName) {
                FileManager.default.fileExists(atPath: $0.path)
            }
            try file.data.write(to: url, options: .atomic)
            notifier.show(title: L("Screenshot saved"), body: url.lastPathComponent, url: url)
        } catch {
            Alerts.inform(L("The screenshot was not saved."), error.localizedDescription)
        }
    }

    // MARK: Print

    private func printImage(_ screenshot: FinishedScreenshot) {
        let pointSize = Self.pointSize(of: screenshot.image, scale: screenshot.scale)
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        let available = CGSize(width: info.paperSize.width - info.leftMargin - info.rightMargin,
                               height: info.paperSize.height - info.topMargin - info.bottomMargin)
        let size = ActionRules.fittedSize(pointSize, in: available)
        let view = NSImageView(frame: NSRect(origin: .zero, size: size))
        view.image = NSImage(cgImage: screenshot.image, size: pointSize)
        view.imageScaling = .scaleProportionallyUpOrDown
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        AppFocus.activate()
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }

    private static func pointSize(of image: CGImage, scale: CGFloat) -> CGSize {
        let factor = max(scale, 1)
        return CGSize(width: CGFloat(image.width) / factor, height: CGFloat(image.height) / factor)
    }
}
