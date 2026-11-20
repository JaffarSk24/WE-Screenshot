import AppKit

// Developer tool: renders the overlay off screen into PNG files and checks a
// few rules on the way. Nothing is shown on screen and no permission is
// needed. Usage: weshot-harness <output folder>

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write("usage: weshot-harness <output folder>\n".data(using: .utf8)!)
    exit(2)
}
outputFolder = URL(fileURLWithPath: arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)

Task { @MainActor in
    runMain(width: 1440, height: 900, scale: 2, prefix: "", full: true)
    runMain(width: 800, height: 600, scale: 1, prefix: "narrow-", full: false)
    runLogicChecks()
    print(failures == 0 ? "all checks passed" : "\(failures) checks failed")
    // The colour panel stores its toolbar state under this tool's own
    // preferences domain; leave nothing behind.
    UserDefaults.standard.removePersistentDomain(forName: ProcessInfo.processInfo.processName)
    UserDefaults.standard.synchronize()
    let leftover = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/\(ProcessInfo.processInfo.processName).plist")
    try? FileManager.default.removeItem(at: leftover)
    exit(failures == 0 ? 0 : 1)
}
RunLoop.main.run()
