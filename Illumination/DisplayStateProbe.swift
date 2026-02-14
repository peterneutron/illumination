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

    // DRY: shared enumerator over IOMobileFramebufferShim entries
    private func collectShimEntries() -> [(io_registry_entry_t, [String: Any])] {
        var out: [(io_registry_entry_t, [String: Any])] = []
        guard let match = IOServiceMatching("IOMobileFramebufferShim") else { return out }
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &it) == KERN_SUCCESS else { return out }
        defer { IOObjectRelease(it) }
        var e: io_registry_entry_t = IOIteratorNext(it)
        while e != 0 {
            var cfDict: Unmanaged<CFMutableDictionary>? = nil
            _ = IORegistryEntryCreateCFProperties(e, &cfDict, kCFAllocatorDefault, 0)
            let dict = (cfDict?.takeRetainedValue() as? [String: Any]) ?? [:]
            out.append((e, dict))
            e = IOIteratorNext(it)
        }
        return out
    }

    // Probe all IOMobileFramebufferShim instances and extract display info
    func probe() -> [DisplayInfo] {
        let collected = collectShimEntries()
        if collected.isEmpty { lastResults = []; return [] }

        let (appKitPotential, appKitCurrent) = appKitHintsForBuiltInDisplay()
        let runtimeSawEDR: Bool = BrightnessController.shared.currentGammaCapDetails().sawEDR

        var results: [DisplayInfo] = []
        for (e, dict) in collected {
            let info = buildDisplayInfo(
                dict: dict,
                appKitPotential: appKitPotential,
                appKitCurrent: appKitCurrent,
                runtimeSawEDR: runtimeSawEDR
            )
            results.append(info)

            IOObjectRelease(e)
        }

        lastResults = results
        return results
    }

    private func appKitHintsForBuiltInDisplay() -> (Double?, Double?) {
        let builtIn = NSScreen.screens.first(where: { screen in
            if let id = screen.displayId { return CGDisplayIsBuiltin(id) != 0 }
            return false
        })
        let potential = builtIn.flatMap { screen in
            if #available(macOS 14.0, *) { return Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue) }
            return nil
        }
        let current = builtIn.map { Double($0.maximumExtendedDynamicRangeColorComponentValue) }
        return (potential, current)
    }

    private func buildDisplayInfo(
        dict: [String: Any],
        appKitPotential: Double?,
        appKitCurrent: Double?,
        runtimeSawEDR: Bool
    ) -> DisplayInfo {
        let identifier = (dict["IONameMatched"] as? String) ?? (dict["IOName"] as? String) ?? "unknown"
        let isExternal = boolValue(dict["external"])
        let isInternal = !isExternal
        let normalModeActive = boolValue(dict["NormalModeActive"])
        let currentPowerState = (dict["IOPowerManagement"] as? [String: Any]).flatMap { ($0["CurrentPowerState"] as? NSNumber)?.intValue } ?? 0
        let isActive = normalModeActive && (currentPowerState >= 1)

        let limitMaxRaw = (dict["limit_max_physical_brightness"] as? NSNumber)?.uint64Value
        let limitMaxDec = limitMaxRaw.map { Double($0) / 65536.0 }

        let capViaNits = (limitMaxDec ?? 0.0) >= 1000.0
        let capViaAppKit = (appKitPotential ?? 1.0) > 1.0
        let edrCapable = capViaNits || capViaAppKit || runtimeSawEDR
        let capSource: String? = edrCapable ? (capViaNits ? "ioreg" : (capViaAppKit ? "appkit" : "runtime")) : nil

        let edrActiveIOReg = hasEDRDynamicRange(dict)
        let edrActive = isInternal ? ((appKitCurrent ?? 1.0) > 1.0) : edrActiveIOReg

        let hasALS = ((dict["ALSSChannelCount"] as? NSNumber)?.intValue ?? 0) > 0
        let (alsRaw, alsSensible) = decodeAmbientBrightness(dict["AmbientBrightness"])
        let role = isActive ? (isInternal ? "primary" : "secondary") : "inactive"

        return DisplayInfo(
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
        )
    }

    private func boolValue(_ value: Any?) -> Bool {
        switch value {
        case let b as Bool: return b
        case let s as String: return (s as NSString).boolValue
        case let n as NSNumber: return n.boolValue
        default: return false
        }
    }

    private func hasEDRDynamicRange(_ dict: [String: Any]) -> Bool {
        guard let timingElements = dict["TimingElements"] as? [Any] else { return false }
        for element in timingElements {
            guard let elementDict = element as? [String: Any],
                  let colorModes = elementDict["ColorModes"] as? [Any] else { continue }
            for mode in colorModes {
                guard let modeDict = mode as? [String: Any],
                      let dynamicRange = modeDict["DynamicRange"] as? NSNumber else { continue }
                if dynamicRange.doubleValue > 0 { return true }
            }
        }
        return false
    }

    private func decodeAmbientBrightness(_ rawValue: Any?) -> (UInt64?, Bool) {
        if let number = rawValue as? NSNumber {
            let value = number.uint64Value
            return (value, value != 65_536)
        }
        if let data = rawValue as? Data, data.count >= 4 {
            let rawLE = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            let value = UInt64(UInt32(littleEndian: rawLE))
            return (value, value != 65_536)
        }
        return (nil, false)
    }

    // Create an AmbientLightReader bound to the best candidate entry; retain handled by reader.
    func makeALSReader() -> AmbientLightReader? {
        // Collect entries and info
        let collected = collectShimEntries()
        if collected.isEmpty { return nil }
        var entries: [io_registry_entry_t] = []
        var infos: [DisplayInfo] = []
        for (e, dict) in collected {
            entries.append(e)
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
