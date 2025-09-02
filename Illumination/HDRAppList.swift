import AppKit

enum HDRAppList {
    static let hdrApps: Set<String> = [
        "com.apple.Photos",
        "com.apple.QuickTimePlayerX",
        "com.apple.TV"
    ]
    static let browsers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "org.mozilla.firefox"
    ]

    static func isFrontmostHDRApp() -> Bool {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        return hdrApps.contains(front) || browsers.contains(front)
    }
}

