//
//  DeviceUtils.swift
//  Illumination
//

import Foundation
import IOKit

#if DEBUG
let supportedDevices: [String] = [
    "MacBookPro18,1", "MacBookPro18,2", "MacBookPro18,3", "MacBookPro18,4",
    "Mac14,6", "Mac14,10", "Mac14,5", "Mac14,9",
    "Mac15,7", "Mac15,9", "Mac15,11", "Mac15,6", "Mac15,8", "Mac15,10", "Mac15,3",
    "Mac16,1", "Mac16,6", "Mac16,8", "Mac16,7", "Mac16,5",
    "MacBookAir10,1"
]
#else
let supportedDevices: [String] = [
    "MacBookPro18,1", "MacBookPro18,2", "MacBookPro18,3", "MacBookPro18,4",
    "Mac14,6", "Mac14,10", "Mac14,5", "Mac14,9",
    "Mac15,7", "Mac15,9", "Mac15,11", "Mac15,6", "Mac15,8", "Mac15,10", "Mac15,3",
    "Mac16,1", "Mac16,6", "Mac16,8", "Mac16,7", "Mac16,5"
]
#endif

let sdr600nitsDevices: [String] = [
    "Mac15,3", "Mac15,6", "Mac15,7", "Mac15,8", "Mac15,9", "Mac15,10", "Mac15,11",
    "Mac16,1", "Mac16,6", "Mac16,8", "Mac16,7", "Mac16,5"
]

func getModelIdentifier() -> String? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    defer { IOObjectRelease(service) }
    guard let modelData = IORegistryEntryCreateCFProperty(service, "model" as CFString, kCFAllocatorDefault, 0)
        .takeRetainedValue() as? Data else { return nil }
    return String(data: modelData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
}

func getDeviceMaxBrightness() -> Float {
    if let model = getModelIdentifier(), sdr600nitsDevices.contains(model) {
        return 1.535
    }
    return 1.59
}

