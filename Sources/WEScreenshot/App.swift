import AppKit

@main
@MainActor
enum App {
    // NSApplication keeps its delegate weakly, so it is held here.
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
