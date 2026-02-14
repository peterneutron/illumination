import AppKit
import Foundation

struct HDRAppEntry: Codable, Hashable {
    let bundleID: String
    let displayName: String?
    let isDefault: Bool
    var isEnabled: Bool

    var normalizedBundleID: String {
        bundleID.lowercased()
    }
}

struct HDRAppRegistry: Codable {
    var entries: [HDRAppEntry]
}

enum HDRAppList {
    private static let defaultEntries: [HDRAppEntry] = [
        HDRAppEntry(bundleID: "com.apple.Photos", displayName: "Photos", isDefault: true, isEnabled: true),
        HDRAppEntry(bundleID: "com.apple.QuickTimePlayerX", displayName: "QuickTime Player", isDefault: true, isEnabled: true),
        HDRAppEntry(bundleID: "com.apple.TV", displayName: "TV", isDefault: true, isEnabled: true)
    ]

    static func frontmostAppInfo() -> (bundleID: String?, displayName: String?) {
        let app = NSWorkspace.shared.frontmostApplication
        return (app?.bundleIdentifier, app?.localizedName)
    }

    static func isFrontmostDenylistedApp() -> Bool {
        isBundleIDDenylisted(frontmostAppInfo().bundleID)
    }

    static func isBundleIDDenylisted(_ bundleID: String?) -> Bool {
        guard let bundleID = normalized(bundleID), !bundleID.isEmpty else { return false }
        return loadRegistry().entries.contains { entry in
            entry.isEnabled && entry.normalizedBundleID == bundleID
        }
    }

    static func allDenylistedEntries() -> [HDRAppEntry] {
        loadRegistry().entries.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault && !rhs.isDefault }
            let lhsName = (lhs.displayName ?? lhs.bundleID).localizedLowercase
            let rhsName = (rhs.displayName ?? rhs.bundleID).localizedLowercase
            return lhsName < rhsName
        }
    }

    static func addDenylistedApp(bundleID: String, displayName: String?) {
        guard let normalizedID = normalized(bundleID), !normalizedID.isEmpty else { return }
        var registry = loadRegistry()
        if let index = registry.entries.firstIndex(where: { $0.normalizedBundleID == normalizedID }) {
            registry.entries[index].isEnabled = true
            if let displayName, !displayName.isEmpty {
                let existing = registry.entries[index]
                registry.entries[index] = HDRAppEntry(
                    bundleID: existing.bundleID,
                    displayName: displayName,
                    isDefault: existing.isDefault,
                    isEnabled: true
                )
            }
        } else {
            registry.entries.append(
                HDRAppEntry(
                    bundleID: bundleID,
                    displayName: displayName,
                    isDefault: false,
                    isEnabled: true
                )
            )
        }
        saveRegistry(registry)
    }

    static func setDenylistedEnabled(bundleID: String, isEnabled: Bool) {
        guard let normalizedID = normalized(bundleID), !normalizedID.isEmpty else { return }
        var registry = loadRegistry()
        guard let index = registry.entries.firstIndex(where: { $0.normalizedBundleID == normalizedID }) else { return }
        registry.entries[index].isEnabled = isEnabled
        saveRegistry(registry)
    }

    static func removeDenylistedApp(bundleID: String) {
        guard let normalizedID = normalized(bundleID), !normalizedID.isEmpty else { return }
        var registry = loadRegistry()
        registry.entries.removeAll { entry in
            entry.normalizedBundleID == normalizedID && !entry.isDefault
        }
        saveRegistry(registry)
    }

    static func resetDenylistDefaults(keepUserAdded: Bool = true) {
        if keepUserAdded {
            let userEntries = loadRegistry().entries.filter { !$0.isDefault }
            saveRegistry(HDRAppRegistry(entries: mergeDefaults(into: userEntries)))
        } else {
            saveRegistry(HDRAppRegistry(entries: defaultEntries))
        }
    }

    private static func loadRegistry() -> HDRAppRegistry {
        if let data = Settings.hdrAppRegistryData,
           let decoded = try? JSONDecoder().decode(HDRAppRegistry.self, from: data) {
            let merged = HDRAppRegistry(entries: mergeDefaults(into: decoded.entries))
            if merged.entries != decoded.entries { saveRegistry(merged) }
            return merged
        }

        let seeded = HDRAppRegistry(entries: defaultEntries)
        saveRegistry(seeded)
        return seeded
    }

    private static func saveRegistry(_ registry: HDRAppRegistry) {
        if let data = try? JSONEncoder().encode(registry) {
            Settings.hdrAppRegistryData = data
        }
    }

    private static func mergeDefaults(into entries: [HDRAppEntry]) -> [HDRAppEntry] {
        var map: [String: HDRAppEntry] = [:]

        for entry in entries {
            let key = entry.normalizedBundleID
            guard !key.isEmpty else { continue }
            if let existing = map[key] {
                map[key] = merge(existing: existing, incoming: entry)
            } else {
                map[key] = entry
            }
        }

        for fallback in defaultEntries {
            let key = fallback.normalizedBundleID
            if let existing = map[key] {
                map[key] = HDRAppEntry(
                    bundleID: existing.bundleID,
                    displayName: existing.displayName ?? fallback.displayName,
                    isDefault: true,
                    isEnabled: existing.isEnabled
                )
            } else {
                map[key] = fallback
            }
        }

        return Array(map.values).sorted { lhs, rhs in
            lhs.normalizedBundleID < rhs.normalizedBundleID
        }
    }

    private static func merge(existing: HDRAppEntry, incoming: HDRAppEntry) -> HDRAppEntry {
        let preferredDisplayName = incoming.displayName ?? existing.displayName
        return HDRAppEntry(
            bundleID: incoming.bundleID,
            displayName: preferredDisplayName,
            isDefault: existing.isDefault || incoming.isDefault,
            isEnabled: incoming.isEnabled
        )
    }

    private static func normalized(_ bundleID: String?) -> String? {
        bundleID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// Backward-compatible wrappers used by existing tests and debug paths.
extension HDRAppList {
    static func isFrontmostHDRApp() -> Bool { isFrontmostDenylistedApp() }
    static func isBundleIDEnabled(_ bundleID: String?) -> Bool { isBundleIDDenylisted(bundleID) }
    static func allEntries() -> [HDRAppEntry] { allDenylistedEntries() }
    static func addOrEnable(bundleID: String, displayName: String?) { addDenylistedApp(bundleID: bundleID, displayName: displayName) }
    static func setEnabled(bundleID: String, isEnabled: Bool) { setDenylistedEnabled(bundleID: bundleID, isEnabled: isEnabled) }
    static func removeUserEntry(bundleID: String) { removeDenylistedApp(bundleID: bundleID) }
    static func resetDefaults(keepUserAdded: Bool = true) { resetDenylistDefaults(keepUserAdded: keepUserAdded) }
}
