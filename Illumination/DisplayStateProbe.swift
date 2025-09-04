import Foundation
import IOKit
import AppKit

struct DisplayInfo: Equatable {
    let identifier: String
    let isInternal: Bool
    let isActive: Bool
    let role: String // "primary" | "secondary" | "inactive"
    let edrCapable: Bool
    let edrCapSource: String? // "ioreg"|"appkit"|"runtime"
    let edrActive: Bool
    let edrMaxHeadroomRaw: UInt64?
    let hasALS: Bool
    let alsSensible: Bool
    let alsRawValue: UInt64?
    // Decoded and AppKit extras (best-effort)
    let limitMaxPhysicalBrightness: Double?// decoded from limit_max_physical_brightness (nits) — treated as Max
    let appKitPotentialRatio: Double?      // maximumPotentialExtendedDynamicRangeColorComponentValue
    let appKitCurrentRatio: Double?        // maximumExtendedDynamicRangeColorComponentValue
}

final class DisplayStateProbe {
    static let shared = DisplayStateProbe()

    private(set) var lastResults: [DisplayInfo] = []

    // Probe all IOMobileFramebufferShim instances and extract display info
    func probe() -> [DisplayInfo] {
        var results: [DisplayInfo] = []
        guard let match = IOServiceMatching("IOMobileFramebufferShim") else {
            lastResults = []
            return []
        }
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &it) == KERN_SUCCESS else {
            lastResults = []
            return []
        }
        defer { IOObjectRelease(it) }

        // AppKit hints for built-in display
        let builtInScreen: NSScreen? = {
            for s in NSScreen.screens {
                if let id = s.displayId, CGDisplayIsBuiltin(id) != 0 { return s }
            }
            return nil
        }()
        let appKitPotential: Double? = builtInScreen.flatMap { s in
            if #available(macOS 14.0, *) { return Double(s.maximumPotentialExtendedDynamicRangeColorComponentValue) }
            return nil
        }
        let appKitCurrent: Double? = builtInScreen.map { Double($0.maximumExtendedDynamicRangeColorComponentValue) }
        let runtimeSawEDR: Bool = BrightnessController.shared.currentGammaCapDetails().sawEDR

        var e: io_registry_entry_t = IOIteratorNext(it)
        while e != 0 {
            // Collect properties for this entry
            var cfDict: Unmanaged<CFMutableDictionary>? = nil
            let kr = IORegistryEntryCreateCFProperties(e, &cfDict, kCFAllocatorDefault, 0)
            var dict: [String: Any] = [:]
            if kr == KERN_SUCCESS, let d = cfDict?.takeRetainedValue() as? [String: Any] {
                dict = d
            }

            // identifier
            let identifier: String = (dict["IONameMatched"] as? String)
                ?? (dict["IOName"] as? String)
                ?? "unknown"

            // isInternal: external == No/false or missing
            let externalVal = dict["external"]
            let isExternal: Bool = {
                switch externalVal {
                case let b as Bool: return b
                case let s as String: return (s as NSString).boolValue
                case let n as NSNumber: return n.boolValue
                default: return false // default to internal if key missing
                }
            }()
            let isInternal = !isExternal

            // isActive: NormalModeActive == true AND IOPowerManagement.CurrentPowerState >= 1
            let normalModeActive: Bool = {
                if let b = dict["NormalModeActive"] as? Bool { return b }
                if let n = dict["NormalModeActive"] as? NSNumber { return n.boolValue }
                return false
            }()
            let currentPowerState: Int = {
                if let pm = dict["IOPowerManagement"] as? [String: Any] {
                    if let n = pm["CurrentPowerState"] as? NSNumber { return n.intValue }
                }
                return 0
            }()
            let isActive = normalModeActive && (currentPowerState >= 1)

            // limit_max_physical_brightness (16.16 nits)
            let limitMaxRaw: UInt64? = {
                if let n = dict["limit_max_physical_brightness"] as? NSNumber { return n.uint64Value }
                return nil
            }()
            let limitMaxDec: Double? = limitMaxRaw.map { Double($0) / 65536.0 }

            // Capability (union, no "presence only"): ≥1000 nits (limit) OR AppKit potential >1 OR runtime sawEDR
            let capViaNits = ((limitMaxDec ?? 0.0) >= 1000.0)
            let capViaAppKit = (appKitPotential ?? 1.0) > 1.0
            let edrCapable = capViaNits || capViaAppKit || runtimeSawEDR
            let capSource: String? = edrCapable ? (capViaNits ? "ioreg" : (capViaAppKit ? "appkit" : "runtime")) : nil

            // EDR active hint via IOReg DynamicRange
            let edrActiveIOReg: Bool = {
                guard let tes = dict["TimingElements"] as? [Any] else { return false }
                // Pick first for now; could scan for IsPreferred == Yes
                for te in tes {
                    guard let teDict = te as? [String: Any] else { continue }
                    if let modes = teDict["ColorModes"] as? [Any] {
                        for m in modes {
                            if let md = m as? [String: Any] {
                                if let dyn = md["DynamicRange"] as? NSNumber, dyn.doubleValue > 0 { return true }
                            }
                        }
                    }
                }
                return false
            }()
            // Prefer AppKit current ratio for internal display; fall back to IOReg
            let edrActive: Bool = {
                if isInternal, let r = appKitCurrent { return r > 1.0 }
                return edrActiveIOReg
            }()

            // ALS presence and raw
            let hasALS: Bool = {
                if let n = dict["ALSSChannelCount"] as? NSNumber { return n.intValue > 0 }
                return false
            }()
            // AmbientBrightness can be NSNumber or Data
            let (alsRaw, alsSensible): (UInt64?, Bool) = {
                if let n = dict["AmbientBrightness"] as? NSNumber {
                    let v = n.uint64Value
                    return (v, v != 65_536)
                } else if let d = dict["AmbientBrightness"] as? Data, d.count >= 4 {
                    let rawLE = d.withUnsafeBytes { $0.load(as: UInt32.self) }
                    let v = UInt64(UInt32(littleEndian: rawLE))
                    return (v, v != 65_536)
                }
                return (nil, false)
            }()

            let role: String = isActive ? (isInternal ? "primary" : "secondary") : "inactive"

            results.append(DisplayInfo(
                identifier: identifier,
                isInternal: isInternal,
                isActive: isActive,
                role: role,
                edrCapable: edrCapable,
                edrCapSource: capSource,
                edrActive: edrActive,
                edrMaxHeadroomRaw: nil,
                hasALS: hasALS,
                alsSensible: alsSensible,
                alsRawValue: alsRaw,
                limitMaxPhysicalBrightness: limitMaxDec,
                appKitPotentialRatio: isInternal ? appKitPotential : nil,
                appKitCurrentRatio: isInternal ? appKitCurrent : nil
            ))

            IOObjectRelease(e)
            e = IOIteratorNext(it)
        }

        lastResults = results
        return results
    }

    // Create an AmbientLightReader bound to the best candidate entry; retain handled by reader.
    func makeALSReader() -> AmbientLightReader? {
        // First pass: gather entries and pick primary
        guard let match = IOServiceMatching("IOMobileFramebufferShim") else { return nil }
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }

        // Collect entries and info
        var entries: [io_registry_entry_t] = []
        var infos: [DisplayInfo] = []

        var e: io_registry_entry_t = IOIteratorNext(it)
        while e != 0 {
            // Retain e into our array; we'll release later
            entries.append(e)

            var cfDict: Unmanaged<CFMutableDictionary>? = nil
            _ = IORegistryEntryCreateCFProperties(e, &cfDict, kCFAllocatorDefault, 0)
            let dict = (cfDict?.takeRetainedValue() as? [String: Any]) ?? [:]
            let identifier: String = (dict["IONameMatched"] as? String) ?? (dict["IOName"] as? String) ?? "unknown"
            let externalVal = dict["external"]
            let isExternal: Bool = {
                switch externalVal {
                case let b as Bool: return b
                case let s as String: return (s as NSString).boolValue
                case let n as NSNumber: return n.boolValue
                default: return false
                }
            }()
            let isInternal = !isExternal
            let normalModeActive: Bool = {
                if let b = dict["NormalModeActive"] as? Bool { return b }
                if let n = dict["NormalModeActive"] as? NSNumber { return n.boolValue }
                return false
            }()
            let currentPowerState: Int = {
                if let pm = dict["IOPowerManagement"] as? [String: Any] {
                    if let n = pm["CurrentPowerState"] as? NSNumber { return n.intValue }
                }
                return 0
            }()
            let isActive = normalModeActive && (currentPowerState >= 1)
            let hasALS: Bool = {
                if let n = dict["ALSSChannelCount"] as? NSNumber { return n.intValue > 0 }
                return false
            }()
            let info = DisplayInfo(
                identifier: identifier,
                isInternal: isInternal,
                isActive: isActive,
                role: isActive ? (isInternal ? "primary" : "secondary") : "inactive",
                edrCapable: false,
                edrCapSource: nil,
                edrActive: false,
                edrMaxHeadroomRaw: nil,
                hasALS: hasALS,
                alsSensible: true,
                alsRawValue: nil,
                limitMaxPhysicalBrightness: nil,
                appKitPotentialRatio: nil,
                appKitCurrentRatio: nil
            )
            infos.append(info)

            e = IOIteratorNext(it)
        }

        // Do not overwrite lastResults with minimal info here; keep full probe results stable

        // Choose the best candidate: internal+active with ALS, else internal+active, else any active with ALS, else nil
        func pickIndex() -> Int? {
            if let i = infos.firstIndex(where: { $0.isInternal && $0.isActive && $0.hasALS }) { return i }
            if let i = infos.firstIndex(where: { $0.isInternal && $0.isActive }) { return i }
            if let i = infos.firstIndex(where: { $0.isActive && $0.hasALS }) { return i }
            return nil
        }

        guard let idx = pickIndex() else {
            // Release all entries
            for en in entries { IOObjectRelease(en) }
            return nil
        }

        let chosen = entries[idx]
        // Create a reader that retains the entry
        let reader = AmbientLightReader(entry: chosen)
        // Release our references
        for en in entries { IOObjectRelease(en) }
        return reader
    }

    func debugLines() -> [String] {
        if lastResults.isEmpty { _ = probe() }
        return lastResults.map { info in
            let act = info.isActive ? "active" : "inactive"
            let cap = info.edrCapable ? "cap:yes\(info.edrCapSource.map { "(\($0))" } ?? "")" : "cap:no"
            let mode = info.edrActive ? "mode:edr" : "mode:sdr"
            let als = info.hasALS ? (info.alsSensible ? "als:ok" : "als:stale") : "als:—"
            let maxNits = info.limitMaxPhysicalBrightness.map { String(format: "max:%.0f", $0) } ?? "max:—"
            let pot = info.appKitPotentialRatio.map { String(format: "pot:%.2f", $0) } ?? "pot:—"
            let cur = info.appKitCurrentRatio.map { String(format: "cur:%.2f", $0) } ?? "cur:—"
            return "\(info.identifier) [\(info.role), \(act), \(cap), \(mode), \(als), \(maxNits), \(pot), \(cur)]"
        }
    }
}
