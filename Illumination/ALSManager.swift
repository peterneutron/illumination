import Foundation
import IOKit
import AppKit

// MARK: - ALS Auto Profiles
enum ALSProfile: String, CaseIterable {
    case aggressive
    case normal
    case conservative

    var displayName: String {
        switch self {
        case .aggressive: return "Aggressive"
        case .normal: return "Normal"
        case .conservative: return "Conservative"
        }
    }
}

// MARK: - Internal sample representation
private enum ALSSample {
    case value(Double)   // decoded sensor counts (fixed-point X-space)
    case saturated       // driver returned a sentinel / overflow
    case invalid         // missing/garbage
}

// MARK: - Lux Calibrator (maps decoded counts → estimated lux)
struct LuxCalibrator: Codable {
    // Seeded from user-provided measurements: sun anchor + LED steps @ 20cm
    var a: Double = 9.163050293295044
    var p: Double = 1.2194541017683016
    // Covered/baseline decoded value (raw 118,000 / 2^20)
    var xDark: Double = 0.1125335693359375

    func estimateLux(decodedX: Double) -> Double {
        let dx = max(0.0, decodedX - xDark)
        return a * pow(dx, p)
    }

    // Simple persistence
    private static let defaultsKey = "illumination.als.calibrator"
    static func load() -> LuxCalibrator {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let c = try? JSONDecoder().decode(LuxCalibrator.self, from: data) {
            return c
        }
        return LuxCalibrator()
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: LuxCalibrator.defaultsKey)
        }
    }
}

// Fixed-point + sentinel constants
private let kFixedPointShift = 20.0                // 12.20-ish fixed point
private let kFixedPointDiv  = pow(2.0, kFixedPointShift) // 1,048,576.0
private let kSentinelU32    = UInt32(Int32.max)    // 0x7FFFFFFF
private let kSentinelGuard  = UInt32(0x7FFFFF00)   // treat near-top as saturated too
private let kMaxPlausibleLux = 120_000.0           // sanity clamp (physical lux)
private let kMaxDecodedX: Double = 2047.0          // ≈ INT32_MAX / 2^20, safe pre-sentinel ceiling (sensor-space counts)

// Decode helper for the undocumented IOReg key (fixed-point → decoded counts in X-space)
private func decodeAmbientBrightness(_ prop: Any) -> ALSSample {
    // CFNumber path
    if let n = prop as? NSNumber {
        let raw = n.int64Value
        // guard rails
        if raw >= Int64(Int32.max) - 16 { return .saturated }
        if raw < 0 { return .invalid }
        let decodedX = Double(raw) / kFixedPointDiv
        guard decodedX.isFinite else { return .invalid }
        // Clamp in sensor-space (counts), not physical lux
        return .value(min(decodedX, kMaxDecodedX))
    }
    // CFData path (assume LE UInt32 payload)
    if let d = prop as? Data, d.count >= 4 {
        let rawLE = d.withUnsafeBytes { $0.load(as: UInt32.self) }
        let raw = UInt32(littleEndian: rawLE)
        if raw >= kSentinelGuard || raw == kSentinelU32 { return .saturated }
        let decodedX = Double(raw) / kFixedPointDiv
        guard decodedX.isFinite else { return .invalid }
        // Clamp in sensor-space (counts), not physical lux
        return .value(min(decodedX, kMaxDecodedX))
    }
    return .invalid
}

// MARK: - Ambient Light Reader (IORegistry)
final class AmbientLightReader {
    private static let requiredPathSuffix = "/disp0@7C000000/IOMobileFramebufferShim"
    private static let keyName = "AmbientBrightness"

    private var entry: io_registry_entry_t = 0

    init?() {
        // 1) Try class match + path suffix (your original approach)
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
                if IORegistryEntryCreateCFProperty(candidate, Self.keyName as CFString, kCFAllocatorDefault, 0) != nil {
                    entry = candidate // keep retained; released in deinit
                    return
                }
            }
            IOObjectRelease(candidate)
            candidate = IOIteratorNext(it)
        }

        // 2) Fallback: recursive scan by property presence (model/OS resilient)
        var it2: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane,
                                       IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents),
                                       &it2) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it2) }

        var e: io_registry_entry_t = IOIteratorNext(it2)
        while e != 0 {
            if IORegistryEntryCreateCFProperty(e, Self.keyName as CFString, kCFAllocatorDefault, 0) != nil {
                entry = e // keep; do NOT release here
                return
            }
            IOObjectRelease(e)
            e = IOIteratorNext(it2)
        }
        return nil
    }

    deinit { if entry != 0 { IOObjectRelease(entry) } }

    fileprivate func readSample() -> ALSSample {
        guard entry != 0 else { return .invalid }
        guard let prop = IORegistryEntryCreateCFProperty(entry, Self.keyName as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return .invalid
        }
        return decodeAmbientBrightness(prop)
    }
}

// MARK: - ALS Manager + Auto Control
final class ALSManager {
    static let shared = ALSManager()

    // Published-like values (thread: main)
    private(set) var currentLux: Double? = nil
    private(set) var available: Bool = false
    private(set) var sampleHz: Double = 2.0 { didSet { sampleHz = max(0.5, min(60.0, sampleHz)) } }

    // Conversion knobs (tweakable via defaults)
    private var calibration: Double { UserDefaults.standard.object(forKey: "illumination.als.calibration") as? Double ?? 1.0 }
    private var gamma: Double { UserDefaults.standard.object(forKey: "illumination.als.gamma") as? Double ?? 1.0 }

    // Smoothing state
    private var lpState: Double? = nil

    // Calibrator: decoded counts → estimated lux
    private var calibrator: LuxCalibrator = LuxCalibrator.load()

    // Reader + sampling
    private var reader: AmbientLightReader?
    private var timer: DispatchSourceTimer?

    // Watchdog
    private var invalidStreak = 0
    private var saturatedStreak = 0

    // Day-max tracking in sensor counts (Δx = decoded - xDark)
    private var rollingMaxDx: Double = 0
    private var lastDxDecay = Date()
    private var hasSunAnchor: Bool = false
    // Tuning knobs via UserDefaults
    private var sunDxTrigger: Double { // counts level suggesting bright outdoor conditions
        let v = UserDefaults.standard.object(forKey: "illumination.als.sunDxTrigger") as? Double ?? 1200.0
        return max(100.0, min(2047.0, v))
    }
    private var relBlendMax: Double { // cap for Lrel blend weight
        let v = UserDefaults.standard.object(forKey: "illumination.als.relativeBlendMax") as? Double ?? 0.25
        return max(0.0, min(0.5, v))
    }
    private var warmupUntil: Date = Date().addingTimeInterval(2.0)

    // Stall-breaker state for saturation handling
    private var lastGoodX: Double = 0
    private var lastGoodAt: Date = .distantPast

    // Saturation handling knobs
    private let saturationApplyAfter: TimeInterval = 0.5  // seconds of continuous saturation before synthesizing
    private let saturationBoost: Double = 1.15             // push above last good to reflect “very bright”
    private let saturationFloorDx: Double = 1200.0         // sensor-space floor (Δx counts) used when synthesizing in direct sun


    // Auto mode
    private let profileKey = "illumination.als.profile"
    private var profile: ALSProfile = .normal
    private(set) var autoEnabled: Bool = false
    private let autoEnabledKey = "illumination.als.autoEnabled"
    private var graceUntil: Date = .distantPast
    private var aboveCount = 0
    private var belowCount = 0
    // Staged target percent while EDR is OFF (do not move the slider pre‑EDR)
    private var pendingPercent: Double? = nil
    // Remember the user/system brightness percent before we enable EDR
    private var preEDRUserPercent: Double? = nil
    
    // Debug snapshot (exposed for Debug menu)
    private(set) var debugDecodedX: Double? = nil
    private(set) var debugDx: Double? = nil
    private(set) var debugLfit: Double? = nil
    private(set) var debugLrel: Double? = nil
    private(set) var debugBlendW: Double? = nil
    private(set) var debugRollingMaxDx: Double? = nil

    // Thresholds + dwell from profile (brightness/enable policy; keep your semantics)
    private var onLux: Double {
        // Thresholds for enabling Illumination (EDR overlay) per profile
        // Aggressive trips earlier; Conservative requires stronger daylight
        switch profile {
        case .aggressive:   return 15_000.0  // bright window / light shade
        case .normal:       return 25_000.0  // shade → outdoor
        case .conservative: return 35_000.0  // strong daylight only
        }
    }
    private var offLux: Double {
        // Hysteresis off thresholds per profile
        switch profile {
        case .aggressive:   return 10_000.0
        case .normal:       return 18_000.0
        case .conservative: return 25_000.0
        }
    }
    private var onSeconds: Double {
        // Dwell time before turning ON (shorter outside for snappy response)
        switch profile {
        case .aggressive:   return 1.0
        case .normal:       return 2.0
        case .conservative: return 3.0
        }
    }
    private var offSeconds: Double {
        // Dwell time before turning OFF (longer to avoid flapping under passing clouds)
        switch profile {
        case .aggressive:   return 2.0
        case .normal:       return 4.0
        case .conservative: return 6.0
        }
    }
    private var rampStep: Double { // fraction toward target per sample
        switch profile { case .aggressive: return 0.40; case .normal: return 0.25; case .conservative: return 0.15 }
    }

    private init() {
        reader = AmbientLightReader()
        available = (reader != nil)
        // Restore profile + Auto mode
        if let s = UserDefaults.standard.string(forKey: profileKey), let p = ALSProfile(rawValue: s) {
            profile = p
        } else {
            profile = .normal
        }
        let stored = UserDefaults.standard.object(forKey: autoEnabledKey) as? Bool ?? false
        autoEnabled = false
        setAutoEnabled(stored)
        start()
    }

    deinit { stop() }

    func setAutoEnabled(_ on: Bool) {
        if on == autoEnabled { return }
        autoEnabled = on
        UserDefaults.standard.set(on, forKey: autoEnabledKey)
    }

    func noteManualOverride() { graceUntil = Date().addingTimeInterval(15.0) }

    func setSampleHz(_ hz: Double) {
        sampleHz = hz
        start()
    }

    // MARK: - Timer lifecycle
    private func start() {
        stop()
        guard reader != nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        let interval = DispatchTimeInterval.nanoseconds(Int(1_000_000_000.0 / sampleHz))
        t.schedule(deadline: .now() + .milliseconds(100), repeating: interval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func stop() { timer?.cancel(); timer = nil }

    private func tick() {
        guard let reader else { return }
        let dt = 1.0 / max(0.001, sampleHz)
        let (tauBase, multBase) = smoothingParams()
        let now = Date()

        switch reader.readSample() {
        case .value(let decodedX):
            invalidStreak = 0; saturatedStreak = 0

            // Remember last good sample for stall-breaking
            lastGoodX = decodedX
            lastGoodAt = now

            // Compute Δx (decoded counts above dark baseline) and update day-max in sensor-space
            let dx = max(0.0, decodedX - calibrator.xDark)
            updateRollingMaxDx(dx)

            // Smooth the decoded counts (sensor-space)
            let tau = tauBase
            let mult = multBase
            let xSmoothed = ema(decodedX, state: &lpState, dt: dt, tau: tau, mult: mult)

            // Estimate physical lux from counts via calibrator
            let Lfit = calibrator.estimateLux(decodedX: xSmoothed)

            // Blend with day-max relative model for robustness (only after confidence)
            let xhat = min(1.0, dx / max(rollingMaxDx, 1e-6))
            let Lrel = 50.0 + (100_000.0 - 50.0) * pow(xhat, 1.45)

            // Confidence for using relative model: only after warmup and once we've seen strong daylight
            var w = 0.0
            if now >= warmupUntil {
                if hasSunAnchor || rollingMaxDx >= sunDxTrigger {
                    let xSun = 2047.0
                    let conf = min(1.0, max(0.0, (rollingMaxDx - sunDxTrigger) / max(1.0, (xSun - sunDxTrigger))))
                    w = relBlendMax * conf // ramp relative blend up as we gain confidence
                }
            }

            var L = (1.0 - w) * Lfit + w * Lrel
            L = min(L, kMaxPlausibleLux)

            // Optional user knobs
            L = pow(L * calibration, gamma)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.currentLux = L
                // Debug snapshot
                self.debugDecodedX = xSmoothed
                self.debugDx = dx
                self.debugLfit = Lfit
                self.debugLrel = Lrel
                self.debugBlendW = w
                self.debugRollingMaxDx = self.rollingMaxDx
                self.evaluateAuto(lux: L)
            }

        case .saturated:
            saturatedStreak += 1
            // If saturation persists long enough, synthesize a surrogate “very bright” lux value
            if now.timeIntervalSince(lastGoodAt) >= saturationApplyAfter {
                // We are saturated: mark sun-anchor and synthesize a sensor-space surrogate X (decoded counts)
                hasSunAnchor = true
                var surrogateX = max(lastGoodX * saturationBoost,
                                      calibrator.xDark + max(rollingMaxDx * 1.05, saturationFloorDx))
                surrogateX = min(surrogateX, kMaxDecodedX)

                // Nudge the filter a bit faster upward while saturated
                let tau = max(1.0, tauBase * 0.7)
                let mult = max(1.2, multBase)
                let xSmoothed = ema(surrogateX, state: &lpState, dt: dt, tau: tau, mult: mult)

                // Calibrated lux estimate + gated relative blend
                let Lfit = calibrator.estimateLux(decodedX: xSmoothed)
                let dxSm = max(0.0, xSmoothed - calibrator.xDark)
                // Keep rolling max fresh during sustained saturation
                updateRollingMaxDx(dxSm)
                let xhat = min(1.0, dxSm / max(rollingMaxDx, 1e-6))
                let Lrel = 50.0 + (100_000.0 - 50.0) * pow(xhat, 1.45)

                var w = 0.0
                if now >= warmupUntil {
                    if hasSunAnchor || rollingMaxDx >= sunDxTrigger {
                        let xSun = 2047.0
                        let conf = min(1.0, max(0.0, (rollingMaxDx - sunDxTrigger) / max(1.0, (xSun - sunDxTrigger))))
                        w = relBlendMax * conf
                    }
                }

                var L = (1.0 - w) * Lfit + w * Lrel
                L = min(L, kMaxPlausibleLux)
                L = pow(L * calibration, gamma)

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.currentLux = L
                    // Debug snapshot
                    self.debugDecodedX = xSmoothed
                    self.debugDx = dxSm
                    self.debugLfit = Lfit
                    self.debugLrel = Lrel
                    self.debugBlendW = w
                    self.debugRollingMaxDx = self.rollingMaxDx
                    self.evaluateAuto(lux: L)
                }
            }

            // Try to recover binding if saturation is stuck for a while
            if saturatedStreak >= Int(sampleHz * 5) { attemptRebind() }

        case .invalid:
            invalidStreak += 1
            if invalidStreak >= Int(sampleHz * 5) { attemptRebind() }
        }
    }

    // Profile-dependent smoothing parameters
    @inline(__always)
    private func smoothingParams() -> (tau: Double, mult: Double) {
        switch profile {
        case .aggressive:   return (1.8, 1.5)  // quicker attack
        case .normal:       return (3.5, 1.0)
        case .conservative: return (6.0, 0.8)  // extra calm indoors
        }
    }

    // EMA with time constant τ (seconds). alpha = 1 - exp(-dt/τ)
    @inline(__always)
    private func ema(_ x: Double, state: inout Double?, dt: Double, tau: Double, mult: Double) -> Double {
        let a = max(0.0, min(1.0, (1.0 - exp(-dt / tau)) * mult))
        let y0 = state ?? x
        let y = y0 + a * (x - y0)
        state = y
        return y
    }

    // MARK: - Rebind watchdog
    private func attemptRebind() {
        // Re-scan IORegistry if we appear stuck
        let newReader = AmbientLightReader()
        if let nr = newReader {
            reader = nr
            available = true
        } else {
            available = false
        }
        invalidStreak = 0
        saturatedStreak = 0
    }


    // Track the maximum observed Δx (decoded - xDark)
    private func updateRollingMaxDx(_ dx: Double) {
        rollingMaxDx = max(rollingMaxDx, dx)
        if Date().timeIntervalSince(lastDxDecay) > 30 {
            rollingMaxDx *= 0.995 // slow decay over time
            lastDxDecay = Date()
        }
    }

    // MARK: - Auto control policy
    private func evaluateAuto(lux: Double) {
        guard autoEnabled else { return }

        // Percent mapping (unchanged semantics)
        let target = percent(forLux: lux)
        let bc = BrightnessController.shared
        let isOn = bc.appIsEnabled()

        // Respect HDR Apps mode: if user selected Apps and an HDR-app is frontmost, pause ALS ramp
        let hdrMode = bc.hdrRegionSamplerModeValue()
        let inHDRApp = HDRAppList.isFrontmostHDRApp()
        let shouldPauseRamp = (hdrMode == 3) && inHDRApp

        if isOn {
            // Only move the slider while EDR is actually ON
            if !shouldPauseRamp {
                let current = bc.currentUserPercent()
                let step = inHDRApp && hdrMode == 3 ? max(0.10, rampStep * 0.6) : rampStep
                let next = current + (target - current) * step
                bc.setUserPercent(next)
            }
            // Clear any staged target once we’re actively controlling
            pendingPercent = nil
        } else {
            // Stage the desired percent; apply instantly upon enable
            pendingPercent = target
        }

        // Master gating with hysteresis + grace
        if Date() < graceUntil { return }
        let onCountReq = Int(sampleHz * onSeconds)
        let offCountReq = Int(sampleHz * offSeconds)

        if lux >= onLux {
            aboveCount = min(aboveCount + 1, onCountReq)
        } else {
            aboveCount = max(0, aboveCount - 1)
        }

        if lux <= offLux {
            belowCount = min(belowCount + 1, offCountReq)
        } else {
            belowCount = max(0, belowCount - 1)
        }

        if !isOn && aboveCount >= onCountReq {
            // Capture current slider percent as the value to restore when we later disable EDR
            if preEDRUserPercent == nil {
                preEDRUserPercent = bc.currentUserPercent()
            }
            bc.setEnabled(true)
            // Apply the staged target immediately so the user sees the boost as EDR engages
            if let staged = pendingPercent {
                bc.setUserPercent(staged)
                pendingPercent = nil
            } else {
                // Fall back to a fresh target from current lux
                bc.setUserPercent(target)
            }
            aboveCount = 0; belowCount = 0
        } else if isOn && belowCount >= offCountReq {
            // Restore the pre-EDR SDR brightness percent when turning EDR OFF
            if let prev = preEDRUserPercent {
                bc.setUserPercent(prev)
                preEDRUserPercent = nil
            }
            bc.setEnabled(false)
            // Do not move the slider further in SDR; keep last percent staged for the next ON
            aboveCount = 0; belowCount = 0
        }
    }

    /// Note: brightness anchors target indoor SDR range and saturate at 4000 lux; we only drive this curve while EDR is ON. Beyond ~4k lux, readability is handled by EDR headroom.
    // Piecewise linear mapping for lux → percent (your anchors retained)
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

    // MARK: - Profile API
    func getProfile() -> ALSProfile { profile }

    func setProfile(_ newProfile: ALSProfile) {
        guard newProfile != profile else { return }
        profile = newProfile
        UserDefaults.standard.set(newProfile.rawValue, forKey: profileKey)
        // Reset smoothing + dwell counters on profile change
        lpState = nil
        aboveCount = 0; belowCount = 0
    }
}
