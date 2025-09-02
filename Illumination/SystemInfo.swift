import Foundation
import IOKit

enum SystemInfo {
    static func getModelIdentifier() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        guard let modelData = IORegistryEntryCreateCFProperty(service, "model" as CFString, kCFAllocatorDefault, 0)
            .takeRetainedValue() as? Data else { return nil }
        return String(data: modelData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
    }
}

