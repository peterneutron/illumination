import AppKit
import Foundation

struct InstalledHDRApp: Hashable {
    let bundleID: String
    let displayName: String
}

enum InstalledAppDiscovery {
    static func discoverInstalledApps(limit: Int = 800) -> [InstalledHDRApp] {
        let appDirectories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]

        var seen: Set<String> = []
        var results: [InstalledHDRApp] = []

        for root in appDirectories {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                if results.count >= limit { break }
                guard url.pathExtension == "app" else { continue }
                enumerator.skipDescendants()

                guard let bundle = Bundle(url: url),
                      let bundleID = bundle.bundleIdentifier else {
                    continue
                }

                let normalized = bundleID.lowercased()
                if seen.contains(normalized) { continue }
                seen.insert(normalized)

                let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent

                results.append(InstalledHDRApp(bundleID: bundleID, displayName: displayName))
            }
        }

        return results.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }
}
