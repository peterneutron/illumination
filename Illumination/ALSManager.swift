import Foundation
import IOKit
import AppKit

// MARK: - ALS Auto Profiles
enum ALSProfile: String, CaseIterable {
    case earliest
    case earlier
    case aggressive
    case normal
    case conservative

    var displayName: String {
        switch self {
        case .earliest: return "Earliest"
        case .earlier: return "Earlier"
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

    // Deprecated legacy scan initializer removed; construct via DisplayStateProbe.makeALSReader()
    private init?() { return nil }

    deinit { if entry != 0 { IOObjectRelease(entry) } }

    fileprivate func readSample() -> ALSSample {
        guard entry != 0 else { return .invalid }
        guard let prop = IORegistryEntryCreateCFProperty(entry, Self.keyName as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return .invalid
        }
        return decodeAmbientBrightness(prop)
    }

    // Bind to a provided IORegistry entry (retains it); validate key presence
    init?(entry: io_registry_entry_t) {
        guard entry != 0 else { return nil }
        // Validate the key exists
        if IORegistryEntryCreateCFProperty(entry, Self.keyName as CFString, kCFAllocatorDefault, 0) == nil {
            return nil
        }
        self.entry = entry
        IOObjectRetain(self.entry)
    }
}

// MARK: - ALS Manager + Auto Control
final class ALSManager {
    static let shared = ALSManager()

    // Published-like values (thread: main)
    private(set) var currentLux: Double? = nil
    private(set) var available: Bool = false
    private(set) var sampleHz: Double = 2.0 { didSet { sampleHz = max(0.5, min(60.0, sampleHz)) } }

    // Removed legacy calibration/gamma scalars

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
    // Tuning knobs via Settings
    private var sunDxTrigger: Double { Settings.sunDxTrigger }
    private var relBlendMax: Double { Settings.relativeBlendMax }
    private var warmupUntil: Date = Date().addingTimeInterval(2.0)

    // Stall-breaker state for saturation handling
    private var lastGoodX: Double = 0
    private var lastGoodAt: Date = .distantPast

    // Saturation handling knobs
    private let saturationApplyAfter: TimeInterval = 0.5  // seconds of continuous saturation before synthesizing
    private let saturationBoost: Double = 1.15             // push above last good to reflect “very bright”
    private let saturationFloorDx: Double = 1200.0         // sensor-space floor (Δx counts) used when synthesizing in direct sun


    // Auto mode
    private let profileKey = "illumination.als.profile" // legacy key kept for migration only
    private var profile: ALSProfile = .normal
    private(set) var autoEnabled: Bool = false
    private let autoEnabledKey = "illumination.als.autoEnabled" // legacy key kept for migration only
    private var graceUntil: Date = .distantPast
    private var aboveCount = 0
    private var belowCount = 0
    // Staged target percent while EDR is OFF (do not move the slider pre‑EDR)
    private var pendingPercent: Double? = nil
    // pre-EDR user percent tracking removed

    // EDR entry behavior
    private var edrEnabledAt: Date? = nil
    private var edrDisabledAt: Date? = nil
    private var entryMinPercent: Double { Settings.entryMinPercent }
    private var entryEnvelopeSeconds: Double { Settings.entryEnvelopeSeconds }
    private var maxPercentPerSecond: Double { Settings.maxPercentPerSecond }
    private var minOnSecondsGuard: Double { Settings.minOnSeconds }
    private var minOffSecondsGuard: Double { Settings.minOffSeconds }
    
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
        case .earliest:     return 8_000.0   // very early
        case .earlier:      return 12_000.0  // early
        case .aggressive:   return 15_000.0  // bright window / light shade
        case .normal:       return 25_000.0  // shade → outdoor
        case .conservative: return 35_000.0  // strong daylight only
        }
    }
    private var offLux: Double {
        // Hysteresis off thresholds per profile
        switch profile {
        case .earliest:     return 5_000.0
        case .earlier:      return 8_000.0
        case .aggressive:   return 10_000.0
        case .normal:       return 18_000.0
        case .conservative: return 25_000.0
        }
    }
    private var onSeconds: Double {
        // Dwell time before turning ON (shorter outside for snappy response)
        switch profile {
        case .earliest:     return 1.0
        case .earlier:      return 1.0
        case .aggressive:   return 1.0
        case .normal:       return 2.0
        case .conservative: return 3.0
        }
    }
    private var offSeconds: Double {
        // Dwell time before turning OFF (longer to avoid flapping under passing clouds)
        switch profile {
        case .earliest:     return 2.0
        case .earlier:      return 3.0
        case .aggressive:   return 2.0
        case .normal:       return 4.0
        case .conservative: return 6.0
        }
    }
    private var rampStep: Double { // fraction toward target per sample
        switch profile {
        case .earliest: return 0.50
        case .earlier: return 0.45
        case .aggressive: return 0.40
        case .normal: return 0.25
        case .conservative: return 0.15
        }
    }

    private init() {
        // First, run a full probe so Debug has data on startup
        _ = DisplayStateProbe.shared.probe()
        // Prefer robust probe; fallback to legacy discovery
        if let r = DisplayStateProbe.shared.makeALSReader() {
            reader = r
            available = true
        } else {
            reader = nil
            available = false
        }
        // Restore profile + Auto mode
        if let s = Settings.alsProfileRaw, let p = ALSProfile(rawValue: s) {
            profile = p
        } else {
            profile = .normal
        }
        autoEnabled = false
        setAutoEnabled(Settings.alsAutoEnabled)
        start()
    }

    deinit { stop() }

    func setAutoEnabled(_ on: Bool) {
        if on == autoEnabled { return }
        autoEnabled = on
        Settings.alsAutoEnabled = on
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
        case .earliest:     return (1.5, 1.6)  // quickest
        case .earlier:      return (1.6, 1.55)
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
        if let nr = DisplayStateProbe.shared.makeALSReader() {
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
                // Entry envelope: cap allowed percent during first seconds after enable
                var allowed = 100.0
                if let t0 = edrEnabledAt {
                    let elapsed = Date().timeIntervalSince(t0)
                    let slope = (100.0 - entryMinPercent) / max(0.1, entryEnvelopeSeconds)
                    allowed = min(100.0, entryMinPercent + slope * elapsed)
                }
                var desired = min(target, allowed)
                // Maintain minimum while on
                desired = max(entryMinPercent, desired)
                // Ramp and slope-limit
                let dt = 1.0 / max(0.001, sampleHz)
                var next = current + (desired - current) * step
                let maxDelta = maxPercentPerSecond * dt
                next = current + max(-maxDelta, min(maxDelta, next - current))
                next = max(entryMinPercent, min(100.0, next))
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
            // Enforce minimum OFF time before enabling
            if let tOff = edrDisabledAt, Date().timeIntervalSince(tOff) < minOffSecondsGuard {
                // wait a bit longer before re-enabling
            } else {
                bc.setEnabled(true)
                edrEnabledAt = Date()
                // Start gently at entry minimum
                bc.setUserPercent(entryMinPercent)
            }
            aboveCount = 0; belowCount = 0
        } else if isOn && belowCount >= offCountReq {
            // Enforce minimum ON time before disabling
            if let tOn = edrEnabledAt, Date().timeIntervalSince(tOn) < minOnSecondsGuard {
                // remain ON a bit longer
            } else {
                // Turn EDR OFF and set percent to 0
                bc.setEnabled(false)
                edrDisabledAt = Date()
                edrEnabledAt = nil
                bc.setUserPercent(0.0)
            }
            aboveCount = 0; belowCount = 0
        }
    }

    /// Smooth onLux-relative mapping for lux → EDR percent.
    /// - At L = onLux: ~entryMinPercent
    /// - At L ≈ 3×onLux: ~50–70%
    /// - At L ≈ 10×onLux: ~85–95%
    /// - Approaches 100% asymptotically for extreme L
    private func percent(forLux lux: Double) -> Double {
        let L_on = max(1.0, onLux)
        let p0 = entryMinPercent
        if lux <= L_on { return p0 }
        let L_hi = L_on * 10.0
        let r = min(1.0, max(0.0, log(lux / L_on) / max(1e-6, log(L_hi / L_on))))
        // smoothstep
        let s = r * r * (3.0 - 2.0 * r)
        return p0 + (100.0 - p0) * s
    }

    // MARK: - Profile API
    func getProfile() -> ALSProfile { profile }

    func setProfile(_ newProfile: ALSProfile) {
        guard newProfile != profile else { return }
        profile = newProfile
        Settings.alsProfileRaw = newProfile.rawValue
        // Reset smoothing + dwell counters on profile change
        lpState = nil
        aboveCount = 0; belowCount = 0
    }

    // MARK: - Debug tuners API
    func setEntryMinPercent(_ p: Double) { Settings.entryMinPercent = p }
    func setEntryEnvelopeSeconds(_ s: Double) { Settings.entryEnvelopeSeconds = s }
    func setMaxPercentPerSecond(_ v: Double) { Settings.maxPercentPerSecond = v }
    func setMinOnSeconds(_ v: Double) { Settings.minOnSeconds = v }
    func setMinOffSeconds(_ v: Double) { Settings.minOffSeconds = v }

    func entryMinPercentValue() -> Double { entryMinPercent }
    func entryEnvelopeSecondsValue() -> Double { entryEnvelopeSeconds }
    func maxPercentPerSecondValue() -> Double { maxPercentPerSecond }
    func minOnSecondsValue() -> Double { minOnSecondsGuard }
    func minOffSecondsValue() -> Double { minOffSecondsGuard }
    func sunDxTriggerValue() -> Double { sunDxTrigger }
    func setSunDxTrigger(_ v: Double) { Settings.sunDxTrigger = v }
    func relativeBlendMaxValue() -> Double { relBlendMax }
    func setRelativeBlendMax(_ v: Double) { Settings.relativeBlendMax = v }

    // MARK: - Calibration helper
    struct CalibAnchor: Codable { let dx: Double; let lux: Double }
    private let anchorAKey = "illumination.als.calib.anchorA"
    private let anchorBKey = "illumination.als.calib.anchorB"
    private func saveAnchor(_ a: CalibAnchor?, key: String) {
        if let a = a, let data = try? JSONEncoder().encode(a) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    private func loadAnchor(key: String) -> CalibAnchor? {
        if let data = UserDefaults.standard.data(forKey: key), let a = try? JSONDecoder().decode(CalibAnchor.self, from: data) { return a }
        return nil
    }
    func calibAnchorA() -> CalibAnchor? { loadAnchor(key: anchorAKey) }
    func calibAnchorB() -> CalibAnchor? { loadAnchor(key: anchorBKey) }
    func clearAnchors() { saveAnchor(nil, key: anchorAKey); saveAnchor(nil, key: anchorBKey) }
    func setDarkFromCurrent() {
        guard let x = debugDecodedX else { return }
        var c = calibrator
        c.xDark = x
        c.save()
        calibrator = LuxCalibrator.load()
    }
    func setAnchorAFromCurrent(lux: Double) {
        guard let x = debugDecodedX else { return }
        let dx = max(0.0, x - calibrator.xDark)
        guard dx > 1e-6 else { return }
        saveAnchor(CalibAnchor(dx: dx, lux: lux), key: anchorAKey)
    }
    func setAnchorBFromCurrent(lux: Double) {
        guard let x = debugDecodedX else { return }
        let dx = max(0.0, x - calibrator.xDark)
        guard dx > 1e-6 else { return }
        saveAnchor(CalibAnchor(dx: dx, lux: lux), key: anchorBKey)
    }
    func fitCalibrationFromAnchors() {
        guard let A = calibAnchorA(), let B = calibAnchorB() else { return }
        guard A.dx > 1e-6, B.dx > 1e-6, A.lux > 1e-6, B.lux > 1e-6, A.dx != B.dx else { return }
        let p = log(B.lux / A.lux) / log(B.dx / A.dx)
        let pClamped = max(0.8, min(1.8, p))
        let a = A.lux / pow(A.dx, pClamped)
        var c = calibrator
        c.a = a
        c.p = pClamped
        c.save()
        calibrator = LuxCalibrator.load()
    }
    func resetCalibration() { calibrator = LuxCalibrator(); calibrator.save() }
}
