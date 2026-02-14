import Foundation
import IOKit
import AppKit

enum ALSProfile: String, CaseIterable {
    case twilight
    case daybreak
    case midday
    case sunburst
    case highNoon

    var displayName: String {
        switch self {
        case .twilight: return L("Twilight")
        case .daybreak: return L("Daybreak")
        case .midday: return L("Midday")
        case .sunburst: return L("Sunburst")
        case .highNoon: return L("High Noon")
        }
    }
}

func migrateALSProfileRaw(_ raw: String) -> ALSProfile? {
    if let p = ALSProfile(rawValue: raw) { return p }
    switch raw {
    case "earliest": return .twilight
    case "earlier": return .daybreak
    case "aggressive": return .midday
    case "normal": return .sunburst
    case "conservative": return .highNoon
    default: return nil
    }
}

enum ALSSample {
    case value(Double)
    case saturated
    case invalid
}

struct LuxCalibrator: Codable {
    var a: Double = ALSHardwareProfileCatalog.defaultConfig.calibratorA
    var p: Double = ALSHardwareProfileCatalog.defaultConfig.calibratorP
    // NOTE: xDark is intentionally pinned to 0.0 in the current model.
    // The exact historical rationale is unclear; preserve behavior and revisit later.
    var xDark: Double = ALSHardwareProfileCatalog.defaultConfig.calibratorXDark

    func estimateLux(decodedX: Double) -> Double {
        let dx = max(0.0, decodedX - xDark)
        return a * pow(dx, p)
    }

    static func load() -> LuxCalibrator {
        if let data = Settings.alsCalibratorData,
           let c = try? JSONDecoder().decode(LuxCalibrator.self, from: data) {
            return c
        }
        return LuxCalibrator()
    }

    static func exists() -> Bool {
        Settings.alsCalibratorData != nil
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            Settings.alsCalibratorData = data
        }
    }
}

extension ALSManager {
    func calibratorLine() -> String {
        let cp = calibratorParams()
        return String(format: "Calibrator: a=%.5f, p=%.5f, xDark=%.5f", cp.a, cp.p, cp.xDark)
    }
}

let kMaxDecodedX: Double = 2047.0

func decodeAmbientBrightness(_ prop: Any) -> ALSSample {
    let decoded = ALSComputation.decodeAmbientBrightnessSample(raw: prop)
    switch decoded.kind {
    case "value":
        if let value = decoded.value { return .value(value) }
        return .invalid
    case "saturated":
        return .saturated
    default:
        return .invalid
    }
}

final class AmbientLightReader {
    private static let keyName = "AmbientBrightness"

    private var entry: io_registry_entry_t = 0

    private init?() { return nil }

    deinit {
        if entry != 0 { IOObjectRelease(entry) }
    }

    func readSample() -> ALSSample {
        guard entry != 0 else { return .invalid }
        guard let prop = IORegistryEntryCreateCFProperty(entry, Self.keyName as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return .invalid
        }
        return decodeAmbientBrightness(prop)
    }

    init?(entry: io_registry_entry_t) {
        guard entry != 0 else { return nil }
        if IORegistryEntryCreateCFProperty(entry, Self.keyName as CFString, kCFAllocatorDefault, 0) == nil {
            return nil
        }
        self.entry = entry
        IOObjectRetain(self.entry)
    }
}
