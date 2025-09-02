import Foundation
import IOKit

// MARK: - Ambient Light Reader (copied from ALSTest, trimmed)
final class AmbientLightReader {
    private static let requiredPathSuffix = "/disp0@7C000000/IOMobileFramebufferShim"
    private static let keyName = "AmbientBrightness"

    private var entry: io_registry_entry_t = 0

    init?() {
        guard let match = IOServiceMatching("IOMobileFramebufferShim") else { return nil }
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var candidate: io_registry_entry_t = IOIteratorNext(it)
        while candidate != 0 {
            var buf = [CChar](repeating: 0, count: 512)
            IORegistryEntryGetPath(candidate, kIOServicePlane, &buf)
            let path = String(cString: buf)
            if path.contains(Self.requiredPathSuffix) {
                if let _ = IORegistryEntryCreateCFProperty(candidate, Self.keyName as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
                    entry = candidate
                    return
                }
            }
            IOObjectRelease(candidate)
            candidate = IOIteratorNext(it)
        }
        return nil
    }

    deinit { if entry != 0 { IOObjectRelease(entry) } }

    func readRaw() -> Double? {
        guard entry != 0 else { return nil }
        guard let prop = IORegistryEntryCreateCFProperty(entry, Self.keyName as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return nil }
        if let n = prop as? NSNumber { return n.doubleValue }
        if let d = prop as? Data, d.count >= 4 { return d.withUnsafeBytes { Double($0.load(as: UInt32.self)) } }
        return nil
    }
}

// MARK: - ALS Manager + Auto Control
final class ALSManager {
    static let shared = ALSManager()

    // Published-like values (thread: main)
    private(set) var currentLux: Double? = nil
    private(set) var available: Bool = false
    private(set) var sampleHz: Double = 2.0

    // Conversion knobs (tweakable via defaults)
    private let divisor = 1_048_576.0 // 2^20 fixed-point
    private var calibration: Double { UserDefaults.standard.object(forKey: "illumination.als.calibration") as? Double ?? 1.0 }
    private var gamma: Double { UserDefaults.standard.object(forKey: "illumination.als.gamma") as? Double ?? 1.0 }

    // Smoothing
    private var lpState: Double? = nil
    private let alpha = 0.2 // 0..1

    private let reader: AmbientLightReader?
    private var timer: DispatchSourceTimer?

    // Auto mode
    private(set) var autoEnabled: Bool = false
    private var savedHDRMode: Int? = nil
    private var graceUntil: Date = .distantPast
    private var aboveCount = 0
    private var belowCount = 0
    private let onLux = 120.0
    private let offLux = 80.0
    private let onSeconds = 3.0
    private let offSeconds = 6.0

    private init() {
        reader = AmbientLightReader()
        available = reader != nil
        start()
    }

    deinit { stop() }

    func setAutoEnabled(_ on: Bool) {
        if on == autoEnabled { return }
        autoEnabled = on
        if on {
            // Suspend HDR detection and Tile visuals, preserve user preferences
            if savedHDRMode == nil { savedHDRMode = BrightnessController.shared.hdrRegionSamplerModeValue() }
            BrightnessController.shared.setHDRRegionSamplerMode(0)
            DispatchQueue.main.async { TileFeature.shared.suspendForALS() }
        } else {
            // Restore HDR detection and Tile visuals
            if let mode = savedHDRMode {
                BrightnessController.shared.setHDRRegionSamplerMode(mode)
            }
            savedHDRMode = nil
            DispatchQueue.main.async { TileFeature.shared.resumeAfterALS() }
        }
    }
    func noteManualOverride() { graceUntil = Date().addingTimeInterval(15.0) }

    func setSampleHz(_ hz: Double) {
        sampleHz = max(0.5, min(60.0, hz))
        start()
    }

    private func start() {
        stop()
        guard let reader else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        let interval = DispatchTimeInterval.nanoseconds(Int(1_000_000_000.0 / sampleHz))
        t.schedule(deadline: .now() + .milliseconds(100), repeating: interval)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            guard let raw = reader.readRaw() else { return }
            let smoothed = self.lowPass(raw)
            let lux = pow((smoothed / self.divisor) * self.calibration, self.gamma)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.currentLux = lux
                self.evaluateAuto(lux: lux)
            }
        }
        t.resume()
        timer = t
    }

    private func stop() { timer?.cancel(); timer = nil }

    private func lowPass(_ x: Double) -> Double { let y = (lpState ?? x) + alpha * (x - (lpState ?? x)); lpState = y; return y }

    private func evaluateAuto(lux: Double) {
        guard autoEnabled else { return }
        // Percent mapping
        let target = percent(forLux: lux)
        let bc = BrightnessController.shared
        if BrightnessController.shared.hdrRegionSamplerModeValue() >= 0 { // always true; just to reference bc
            // Smooth percent towards target
            let current = bc.currentUserPercent()
            let step = 0.25 // move 25% toward target per sample
            let next = current + (target - current) * step
            bc.setUserPercent(next)
        }
        // Master gating with hysteresis + grace
        if Date() < graceUntil { return }
        let onCountReq = Int(sampleHz * onSeconds)
        let offCountReq = Int(sampleHz * offSeconds)
        let isOn = bc.appIsEnabled()
        if lux >= onLux {
            aboveCount = min(aboveCount + 1, onCountReq)
        } else { aboveCount = max(0, aboveCount - 1) }
        if lux <= offLux {
            belowCount = min(belowCount + 1, offCountReq)
        } else { belowCount = max(0, belowCount - 1) }
        if !isOn && aboveCount >= onCountReq {
            bc.setEnabled(true)
            aboveCount = 0; belowCount = 0
        } else if isOn && belowCount >= offCountReq {
            bc.setEnabled(false)
            aboveCount = 0; belowCount = 0
        }
    }

    // Piecewise linear mapping for lux → percent
    private func percent(forLux lux: Double) -> Double {
        let anchors: [(Double, Double)] = [
            (0, 0), (150, 20), (300, 40), (600, 60), (1000, 75), (2000, 90), (4000, 100)
        ]
        if lux <= anchors.first!.0 { return anchors.first!.1 }
        if lux >= anchors.last!.0 { return anchors.last!.1 }
        for i in 0..<(anchors.count - 1) {
            let a = anchors[i], b = anchors[i+1]
            if lux >= a.0 && lux <= b.0 {
                let t = (lux - a.0) / max(1.0, (b.0 - a.0))
                return a.1 + (b.1 - a.1) * t
            }
        }
        return 0
    }
}
