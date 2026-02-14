import Foundation
import IOKit
import AppKit

// MARK: - ALS Auto Profiles
enum ALSProfile: String, CaseIterable {
    case twilight      // formerly: earliest
    case daybreak      // formerly: earlier
    case midday        // formerly: aggressive
    case sunburst      // formerly: normal
    case highNoon      // formerly: conservative

    var displayName: String {
        switch self {
        case .twilight: return "Twilight"
        case .daybreak: return "Daybreak"
        case .midday: return "Midday"
        case .sunburst: return "Sunburst"
        case .highNoon: return "High Noon"
        }
    }
}

// Legacy raw-value migration helper
private func migrateALSProfileRaw(_ raw: String) -> ALSProfile? {
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

// MARK: - Internal sample representation
private enum ALSSample {
    case value(Double)   // decoded sensor counts (fixed-point X-space)
    case saturated       // driver returned a sentinel / overflow
    case invalid         // missing/garbage
}

// MARK: - Lux Calibrator (maps decoded counts → estimated lux)
struct LuxCalibrator: Codable {
    // Seeded from user-provided measurements: sun anchor + LED steps @ 20cm
    var a: Double = 20.701263635343665
    var p: Double = 1.13652988767883
    // Covered/baseline decoded value (raw 118,000 / 2^20).
    // NOTE: xDark is intentionally pinned to 0.0 in the current model.
    // The exact historical rationale is unclear; preserve behavior and revisit later.
    var xDark: Double = 0.0

    func estimateLux(decodedX: Double) -> Double {
        let dx = max(0.0, decodedX - xDark)
        return a * pow(dx, p)
    }

    // Simple persistence
    static func load() -> LuxCalibrator {
        if let data = Settings.alsCalibratorData,
           let c = try? JSONDecoder().decode(LuxCalibrator.self, from: data) {
            return c
        }
        return LuxCalibrator()
    }
    static func exists() -> Bool {
        return Settings.alsCalibratorData != nil
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            Settings.alsCalibratorData = data
        }
    }
}

// Convenience for UI line
extension ALSManager {
    func calibratorLine() -> String {
        let cp = calibratorParams()
        return String(format: "Calibrator: a=%.5f, p=%.5f, xDark=%.5f", cp.a, cp.p, cp.xDark)
    }
}

// Fixed-point/sentinel constants are implemented in ALSComputation.decodeAmbientBrightnessSample.
private let kMaxDecodedX: Double = 2047.0 // used for saturation surrogate bounds

// MARK: - Final model: calibrated power law with xDark=0 and day-max relative blend

// Decode helper for the undocumented IOReg key (fixed-point → decoded counts in X-space)
private func decodeAmbientBrightness(_ prop: Any) -> ALSSample {
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

    // Published-like values (main-thread observed by view models/UI)
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
    // Fixed internal blend parameters (previously tunable)
    private let sunDxTriggerConst: Double = 1200.0
    private let relBlendMaxConst: Double = 0.25
    private var warmupUntil: Date = Date().addingTimeInterval(2.0)

    // Stall-breaker state for saturation handling
    private var lastGoodX: Double = 0
    private var lastGoodAt: Date = .distantPast

    // Saturation handling knobs
    private let saturationApplyAfter: TimeInterval = 0.5  // seconds of continuous saturation before synthesizing
    private let saturationBoost: Double = 1.15             // push above last good to reflect “very bright”
    private let saturationFloorDx: Double = 1200.0         // sensor-space floor (Δx counts) used when synthesizing in direct sun


    // Auto mode
    private var profile: ALSProfile = .sunburst
    private(set) var autoEnabled: Bool = false
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
    // Removed: debug fields for alternate models

    // Thresholds + dwell from profile (brightness/enable policy; keep your semantics)
    private var onLux: Double {
        // Thresholds for enabling Illumination (EDR overlay) per profile
        // Aggressive trips earlier; Conservative requires stronger daylight
        switch profile {
        case .twilight:     return 8_000.0   // very early
        case .daybreak:     return 12_000.0  // early
        case .midday:       return 15_000.0  // bright window / light shade
        case .sunburst:     return 25_000.0  // shade → outdoor
        case .highNoon:     return 35_000.0  // strong daylight only
        }
    }
    private var offLux: Double {
        // Hysteresis off thresholds per profile
        switch profile {
        case .twilight:     return 5_000.0
        case .daybreak:     return 8_000.0
        case .midday:       return 10_000.0
        case .sunburst:     return 18_000.0
        case .highNoon:     return 25_000.0
        }
    }
    private var onSeconds: Double {
        // Dwell time before turning ON (shorter outside for snappy response)
        switch profile {
        case .twilight:     return 1.0
        case .daybreak:     return 1.0
        case .midday:       return 1.0
        case .sunburst:     return 2.0
        case .highNoon:     return 3.0
        }
    }
    private var offSeconds: Double {
        // Dwell time before turning OFF (longer to avoid flapping under passing clouds)
        switch profile {
        case .twilight:     return 2.0
        case .daybreak:     return 3.0
        case .midday:       return 2.0
        case .sunburst:     return 4.0
        case .highNoon:     return 6.0
        }
    }
    private var rampStep: Double { // fraction toward target per sample
        switch profile {
        case .twilight: return 0.50
        case .daybreak: return 0.45
        case .midday: return 0.40
        case .sunburst: return 0.25
        case .highNoon: return 0.15
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
        if let s = Settings.alsProfileRaw, let p = migrateALSProfileRaw(s) {
            profile = p
            // Write back migrated value if legacy key was used
            if p.rawValue != s { Settings.alsProfileRaw = p.rawValue }
        } else {
            profile = .midday
        }
        autoEnabled = false
        setAutoEnabled(Settings.alsAutoEnabled)
        // Bootstrap-persist calibrator defaults on first run so a/p survive restarts
        if !LuxCalibrator.exists() {
            calibrator.save()
        }
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
            handleValueSample(decodedX: decodedX, now: now, dt: dt, tauBase: tauBase, multBase: multBase)

        case .saturated:
            handleSaturatedSample(now: now, dt: dt, tauBase: tauBase, multBase: multBase)

        case .invalid:
            handleInvalidSample()
        }
    }

    private func handleValueSample(decodedX: Double, now: Date, dt: Double, tauBase: Double, multBase: Double) {
        invalidStreak = 0
        saturatedStreak = 0

        lastGoodX = decodedX
        lastGoodAt = now

        let dx = max(0.0, decodedX - calibrator.xDark)
        updateRollingMaxDx(dx)

        let xSmoothed = ema(decodedX, state: &lpState, dt: dt, tau: tauBase, mult: multBase)
        let fitLux = calibrator.estimateLux(decodedX: xSmoothed)
        let normalized = min(1.0, dx / max(rollingMaxDx, 1e-6))
        let relLux = ALSComputation.relativeLux(normalizedX: normalized)
        let blendWeight = ALSComputation.blendWeight(
            rollingMaxDx: rollingMaxDx,
            hasSunAnchor: hasSunAnchor,
            now: now,
            warmupUntil: warmupUntil,
            sunDxTrigger: sunDxTriggerConst,
            relBlendMax: relBlendMaxConst
        )
        let finalLux = ALSComputation.blendedLux(fit: fitLux, relative: relLux, weight: blendWeight)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.currentLux = finalLux
            self.debugDecodedX = xSmoothed
            self.debugDx = dx
            self.debugLfit = fitLux
            self.debugLrel = relLux
            self.debugBlendW = blendWeight
            self.debugRollingMaxDx = self.rollingMaxDx
            self.evaluateAuto(lux: finalLux)
        }
    }

    private func handleSaturatedSample(now: Date, dt: Double, tauBase: Double, multBase: Double) {
        saturatedStreak += 1
        if now.timeIntervalSince(lastGoodAt) >= saturationApplyAfter {
            hasSunAnchor = true
            let surrogateX = ALSComputation.surrogateSaturatedX(
                lastGoodX: lastGoodX,
                calibratorXDark: calibrator.xDark,
                rollingMaxDx: rollingMaxDx,
                saturationBoost: saturationBoost,
                saturationFloorDx: saturationFloorDx,
                maxDecodedX: kMaxDecodedX
            )

            let tau = max(1.0, tauBase * 0.7)
            let mult = max(1.2, multBase)
            let xSmoothed = ema(surrogateX, state: &lpState, dt: dt, tau: tau, mult: mult)

            let fitLux = calibrator.estimateLux(decodedX: xSmoothed)
            let dxSm = max(0.0, xSmoothed - calibrator.xDark)
            updateRollingMaxDx(dxSm)
            let normalized = min(1.0, dxSm / max(rollingMaxDx, 1e-6))
            let relLux = ALSComputation.relativeLux(normalizedX: normalized)
            let blendWeight = ALSComputation.blendWeight(
                rollingMaxDx: rollingMaxDx,
                hasSunAnchor: hasSunAnchor,
                now: now,
                warmupUntil: warmupUntil,
                sunDxTrigger: sunDxTriggerConst,
                relBlendMax: relBlendMaxConst
            )
            let finalLux = ALSComputation.blendedLux(fit: fitLux, relative: relLux, weight: blendWeight)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.currentLux = finalLux
                self.debugDecodedX = xSmoothed
                self.debugDx = dxSm
                self.debugLfit = fitLux
                self.debugLrel = relLux
                self.debugBlendW = blendWeight
                self.debugRollingMaxDx = self.rollingMaxDx
                self.evaluateAuto(lux: finalLux)
            }
        }

        if ALSComputation.shouldAttemptRebind(streak: saturatedStreak, sampleHz: sampleHz) {
            attemptRebind()
        }
    }

    private func handleInvalidSample() {
        invalidStreak += 1
        if ALSComputation.shouldAttemptRebind(streak: invalidStreak, sampleHz: sampleHz) {
            attemptRebind()
        }
    }

    // Profile-dependent smoothing parameters
    @inline(__always)
    private func smoothingParams() -> (tau: Double, mult: Double) {
        switch profile {
        case .twilight:     return (1.5, 1.6)  // quickest
        case .daybreak:     return (1.6, 1.55)
        case .midday:       return (1.8, 1.5)  // quicker attack
        case .sunburst:     return (3.5, 1.0)
        case .highNoon:     return (6.0, 0.8)  // extra calm indoors
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
            DispatchQueue.main.async { [weak self] in
                self?.available = true
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.available = false
            }
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
                let next = ALSComputation.nextRampPercent(
                    currentPercent: current,
                    targetPercent: desired,
                    entryMinPercent: entryMinPercent,
                    maxPercentPerSecond: maxPercentPerSecond,
                    dt: dt,
                    step: step
                )
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
        let canEnable = !(edrDisabledAt.map { Date().timeIntervalSince($0) < minOffSecondsGuard } ?? false)
        let canDisable = !(edrEnabledAt.map { Date().timeIntervalSince($0) < minOnSecondsGuard } ?? false)
        let gate = ALSComputation.nextAutoGateState(
            lux: lux,
            isOn: isOn,
            aboveCount: aboveCount,
            belowCount: belowCount,
            onLux: onLux,
            offLux: offLux,
            sampleHz: sampleHz,
            onSeconds: onSeconds,
            offSeconds: offSeconds,
            canEnable: canEnable,
            canDisable: canDisable
        )

        aboveCount = gate.aboveCount
        belowCount = gate.belowCount

        switch gate.action {
        case .none:
            break
        case .enable:
            bc.setEnabled(true)
            edrEnabledAt = Date()
            bc.setUserPercent(entryMinPercent)
        case .disable:
            bc.setEnabled(false)
            edrDisabledAt = Date()
            edrEnabledAt = nil
            bc.setUserPercent(0.0)
        }
    }

    /// Smooth onLux-relative mapping for lux → EDR percent.
    /// - At L = onLux: ~entryMinPercent
    /// - At L ≈ 3×onLux: ~50–70%
    /// - At L ≈ 10×onLux: ~85–95%
    /// - Approaches 100% asymptotically for extreme L
    private func percent(forLux lux: Double) -> Double {
        ALSComputation.percentForLux(lux: lux, onLux: onLux, entryMinPercent: entryMinPercent)
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

    // MARK: - Debug tuners API (kept minimal)
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

    // MARK: - Calibration helper
    struct CalibAnchor: Codable { let dx: Double; let lux: Double }
    private func saveAnchor(_ a: CalibAnchor?, isA: Bool) {
        let data = a.flatMap { try? JSONEncoder().encode($0) }
        if isA {
            Settings.alsCalibAnchorAData = data
        } else {
            Settings.alsCalibAnchorBData = data
        }
    }
    private func loadAnchor(isA: Bool) -> CalibAnchor? {
        let data = isA ? Settings.alsCalibAnchorAData : Settings.alsCalibAnchorBData
        if let data, let a = try? JSONDecoder().decode(CalibAnchor.self, from: data) { return a }
        return nil
    }
    func calibAnchorA() -> CalibAnchor? { loadAnchor(isA: true) }
    func calibAnchorB() -> CalibAnchor? { loadAnchor(isA: false) }
    func clearAnchors() { saveAnchor(nil, isA: true); saveAnchor(nil, isA: false) }
    func setDarkFromCurrent() {
        guard let x = debugDecodedX else { return }
        // NOTE: xDark pinning is intentional for now (xDark = 0.0), even when this capture path is used.
        // Historical reasoning is unclear; revisit later with explicit calibration experiments.
        // We still gate this action on near-dark capture to avoid accidental operator misuse.
        let epsilon: Double = 0.02 // counts in decoded X-space (~2e-2 of 1 count)
        guard x <= epsilon else { return }
        var c = calibrator
        c.xDark = 0.0
        c.save()
        calibrator = LuxCalibrator.load()
    }
    func setAnchorAFromCurrent(lux: Double) {
        guard let x = debugDecodedX else { return }
        let dx = max(0.0, x - calibrator.xDark)
        guard dx > 1e-6 else { return }
        saveAnchor(CalibAnchor(dx: dx, lux: lux), isA: true)
    }
    func setAnchorBFromCurrent(lux: Double) {
        guard let x = debugDecodedX else { return }
        let dx = max(0.0, x - calibrator.xDark)
        guard dx > 1e-6 else { return }
        saveAnchor(CalibAnchor(dx: dx, lux: lux), isA: false)
    }
    func fitCalibrationFromAnchors() {
        guard let anchorA = calibAnchorA(), let anchorB = calibAnchorB() else { return }
        guard let fitted = ALSComputation.fitCalibration(anchorA: (anchorA.dx, anchorA.lux), anchorB: (anchorB.dx, anchorB.lux)) else { return }
        var c = calibrator
        c.a = fitted.a
        c.p = fitted.p
        c.save()
        calibrator = LuxCalibrator.load()
    }
    func resetCalibration() { calibrator = LuxCalibrator(); calibrator.save() }

    // Debug: expose current calibrator parameters
    func calibratorParams() -> (a: Double, p: Double, xDark: Double) {
        return (calibrator.a, calibrator.p, calibrator.xDark)
    }

    // Set calibrator a/p with validation and persist
    func setCalibrator(a: Double, p: Double) {
        guard a.isFinite && a > 0 else { return }
        guard p.isFinite && p > 0 && p < 4.0 else { return }
        calibrator.a = a
        calibrator.p = p
        calibrator.save()
    }

    // Export calibrator as JSON string for clipboard/sharing
    func calibratorJSON() -> String? {
        guard let data = try? JSONEncoder().encode(calibrator) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
