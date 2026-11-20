// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WE-Screenshot",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure logic: geometry, selection, hotkey model, settings, naming, versions.
        .target(name: "WECore"),
        // Annotation model, rendering, image composition and encoding.
        .target(name: "WEAnnotate", dependencies: ["WECore"]),
        // Google sign-in (OAuth for desktop apps) and Google Drive upload.
        .target(
            name: "WECloud",
            dependencies: ["WECore"],
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("Network")]
        ),
        // Screen capture with ScreenCaptureKit and the Screen Recording permission.
        .target(
            name: "WECapture",
            dependencies: ["WECore"],
            linkerSettings: [.linkedFramework("ScreenCaptureKit")]
        ),
        // The selection overlay: windows, selection, toolbars, drawing tools.
        .target(
            name: "WEOverlay",
            dependencies: ["WECore", "WEAnnotate"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        // What happens with a finished screenshot: copy, save, print, search,
        // upload; notifications and the self-updater.
        .target(
            name: "WEActions",
            dependencies: ["WECore", "WEAnnotate", "WECloud"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("UserNotifications")]
        ),
        .executableTarget(
            name: "WEScreenshot",
            dependencies: ["WECore", "WEAnnotate", "WECloud", "WECapture", "WEOverlay", "WEActions"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        // Developer tool: renders the overlay off screen into PNG files, so its
        // look can be checked without the Screen Recording permission.
        .executableTarget(
            name: "weshot-harness",
            dependencies: ["WECore", "WEAnnotate", "WEOverlay"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .testTarget(name: "WECoreTests", dependencies: ["WECore"]),
        .testTarget(name: "WEAnnotateTests", dependencies: ["WEAnnotate", "WECore"]),
        .testTarget(name: "WECloudTests", dependencies: ["WECloud", "WECore"]),
    ]
)
