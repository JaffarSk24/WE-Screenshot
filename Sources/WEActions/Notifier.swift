import AppKit
import UserNotifications
import WECore

/// User notifications (UNUserNotificationCenter).
public final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private static let urlKey = "url"

    public override init() {
        super.init()
    }

    /// The notification centre crashes outside an app bundle (`swift run`).
    private static var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundlePath.hasSuffix(".app") else { return nil }
        return UNUserNotificationCenter.current()
    }

    /// Asks for the permission to show notifications (once) and becomes the
    /// notification centre delegate so banners show while the app is active.
    public func start() {
        guard let center = Notifier.center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Shows a banner. When `url` is given, clicking the banner opens it.
    public func show(title: String, body: String, url: URL?) {
        guard let center = Notifier.center else { return }
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = nil
                if let url { content.userInfo = [Notifier.urlKey: url.absoluteString] }
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                center.add(request) { _ in }
            default:
                // No permission: a soft sound is all the feedback there is.
                DispatchQueue.main.async { NSSound(named: "Tink")?.play() }
            }
        }
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
        if let text = response.notification.request.content.userInfo[Notifier.urlKey] as? String,
           let url = URL(string: text) {
            DispatchQueue.main.async {
                if url.isFileURL {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        completionHandler()
    }
}
