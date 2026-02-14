import Foundation
import AppKit

// MARK: - ALS Manager + Auto Control
final class ALSManager {
    static let shared = ALSManager()

    private enum AutoControlState {
        case off
        case on
    }

    // Published-like values (main-thread observed by view models/UI)
    private(set) var currentLux: Double? = nil
    private(set) var available: Bool = false
    private(set) var sampleHz: Double = 2.0 { didSet { sampleHz = max(0.5, min(60.0, sampleHz)) } }

    private var lpState: Double? = nil

    // Calibrator: decoded counts → estimated lux
    private var calibrator: LuxCalibrator = LuxCalibrator.load()
    private var hardwareProfileID: ALSHardwareProfileID = .defaultProfile
    private var hardwareProfile: ALSHardwareProfileConfig {
        ALSHardwareProfileCatalog.config(for: hardwareProfileID)
    }

    // Reader + sampling
    private var reader: AmbientLightReader?
    private var timer: DispatchSourceTimer?

    private var invalidStreak = 0
    private var saturatedStreak = 0

    // Day-max tracking in sensor counts (Δx = decoded - xDark)
    private var rollingMaxDx: Double = 0
    private var lastDxDecay = Date()
    private var hasSunAnchor: Bool = false
    private var warmupUntil: Date = Date()

    private var lastGoodX: Double = 0
    private var lastGoodAt: Date = .distantPast

    private var saturationApplyAfter: TimeInterval { hardwareProfile.saturationApplyAfter }
    private var saturationBoost: Double { hardwareProfile.saturationBoost }
    private var saturationFloorDx: Double { hardwareProfile.saturationFloorDx }

    // Auto mode
    private var profile: ALSProfile = .sunburst
    private(set) var autoEnabled: Bool = false
    private var graceUntil: Date = .distantPast
    private var aboveCount = 0
    private var belowCount = 0

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
    private let traceStore = ALSTraceStore(capacity: 1_000)
    private var lastTraceExportJSONL: String = ""

    // Thresholds + dwell from profile (brightness/enable policy; keep your semantics)
    private var onLux: Double {
        hardwareProfile.onLux(for: profile)
    }
    private var offLux: Double {
        hardwareProfile.offLux(for: profile)
    }
    private var onSeconds: Double {
        hardwareProfile.onSeconds(for: profile)
    }
    private var offSeconds: Double {
        hardwareProfile.offSeconds(for: profile)
    }
    private var rampStep: Double { // fraction toward target per sample
        hardwareProfile.rampStep(for: profile)
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
        hardwareProfileID = Settings.alsHardwareProfile
        warmupUntil = Date().addingTimeInterval(hardwareProfile.blendWarmupSeconds)
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
        guard on, let lux = currentLux, lux.isFinite else { return }

        // Prime dwell counters from current lux so manual -> auto transitions
        // in clearly dark/bright scenes settle immediately instead of sticking.
        let requiredOn = max(1, Int(ceil(onSeconds * sampleHz)))
        let requiredOff = max(1, Int(ceil(offSeconds * sampleHz)))
        aboveCount = lux >= onLux ? requiredOn : 0
        belowCount = lux <= offLux ? requiredOff : 0
        evaluateAuto(lux: lux)
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
        let relLux = ALSComputation.relativeLux(
            normalizedX: normalized,
            minRelativeLux: hardwareProfile.minRelativeLux,
            maxRelativeLux: hardwareProfile.maxRelativeLux,
            relativeGamma: hardwareProfile.relativeGamma
        )
        let blendWeight = ALSComputation.blendWeight(
            rollingMaxDx: rollingMaxDx,
            hasSunAnchor: hasSunAnchor,
            now: now,
            warmupUntil: warmupUntil,
            sunDxTrigger: hardwareProfile.sunDxTrigger,
            relBlendMax: hardwareProfile.relBlendMax
        )
        let finalLux = ALSComputation.blendedLux(
            fit: fitLux,
            relative: relLux,
            weight: blendWeight,
            maxPlausibleLux: hardwareProfile.maxPlausibleLux
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.traceStore.append(
                ALSTraceEvent(
                    kind: .sampleValue,
                    decodedX: xSmoothed,
                    dx: dx,
                    reason: "value_sample"
                )
            )
            self.traceStore.append(
                ALSTraceEvent(
                    kind: .blendComputed,
                    decodedX: xSmoothed,
                    dx: dx,
                    fitLux: fitLux,
                    relLux: relLux,
                    blendW: blendWeight,
                    finalLux: finalLux,
                    profile: self.profile.rawValue
                )
            )
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
        traceStore.append(
            ALSTraceEvent(
                kind: .sampleSaturated,
                reason: "saturated_streak=\(saturatedStreak)"
            )
        )
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
            let relLux = ALSComputation.relativeLux(
                normalizedX: normalized,
                minRelativeLux: hardwareProfile.minRelativeLux,
                maxRelativeLux: hardwareProfile.maxRelativeLux,
                relativeGamma: hardwareProfile.relativeGamma
            )
            let blendWeight = ALSComputation.blendWeight(
                rollingMaxDx: rollingMaxDx,
                hasSunAnchor: hasSunAnchor,
                now: now,
                warmupUntil: warmupUntil,
                sunDxTrigger: hardwareProfile.sunDxTrigger,
                relBlendMax: hardwareProfile.relBlendMax
            )
            let finalLux = ALSComputation.blendedLux(
                fit: fitLux,
                relative: relLux,
                weight: blendWeight,
                maxPlausibleLux: hardwareProfile.maxPlausibleLux
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.traceStore.append(
                    ALSTraceEvent(
                        kind: .blendComputed,
                        decodedX: xSmoothed,
                        dx: dxSm,
                        fitLux: fitLux,
                        relLux: relLux,
                        blendW: blendWeight,
                        finalLux: finalLux,
                        profile: self.profile.rawValue,
                        reason: "saturated_surrogate"
                    )
                )
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
        traceStore.append(
            ALSTraceEvent(
                kind: .sampleInvalid,
                reason: "invalid_streak=\(invalidStreak)"
            )
        )
        if ALSComputation.shouldAttemptRebind(streak: invalidStreak, sampleHz: sampleHz) {
            attemptRebind()
        }
    }

    // Profile-dependent smoothing parameters
    @inline(__always)
    private func smoothingParams() -> (tau: Double, mult: Double) {
        hardwareProfile.smoothing(for: profile)
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
    private func attemptRebind() {
        traceStore.append(ALSTraceEvent(kind: .rebindAttempt, reason: "attempt"))
        // Re-scan IORegistry if we appear stuck
        if let nr = DisplayStateProbe.shared.makeALSReader() {
            reader = nr
            traceStore.append(ALSTraceEvent(kind: .rebindResult, reason: "success"))
            DispatchQueue.main.async { [weak self] in
                self?.available = true
            }
        } else {
            traceStore.append(ALSTraceEvent(kind: .rebindResult, reason: "failure"))
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
        guard lux.isFinite else { return }

        let bc = BrightnessController.shared
        let state: AutoControlState = bc.appIsEnabled() ? .on : .off
        let targetPercent = computeTargetPercent(lux: lux)
        let nextPercent = computeRampNext(targetPercent: targetPercent, state: state, controller: bc)

        if let nextPercent {
            bc.setUserPercent(nextPercent)
        }

        if Date() < graceUntil {
            traceStore.append(
                ALSTraceEvent(
                    kind: .autoGateDecision,
                    finalLux: lux,
                    isOn: state == .on,
                    targetPercent: targetPercent,
                    nextPercent: nextPercent,
                    gateAction: "none",
                    aboveCount: aboveCount,
                    belowCount: belowCount,
                    onLux: onLux,
                    offLux: offLux,
                    profile: profile.rawValue,
                    reason: "manual_grace"
                )
            )
            return
        }

        let gate = computeGateDecision(lux: lux, state: state, controller: bc)

        aboveCount = gate.aboveCount
        belowCount = gate.belowCount

        let actionLabel = actionString(gate.action)
        traceStore.append(
            ALSTraceEvent(
                kind: .autoGateDecision,
                finalLux: lux,
                isOn: state == .on,
                targetPercent: targetPercent,
                nextPercent: nextPercent,
                gateAction: actionLabel,
                aboveCount: aboveCount,
                belowCount: belowCount,
                onLux: onLux,
                offLux: offLux,
                profile: profile.rawValue
            )
        )

        applyGateAction(gate.action, controller: bc)
        assertInvariants(lux: lux)
    }

    private func computeTargetPercent(lux: Double) -> Double {
        percent(forLux: lux)
    }

    private func computeRampNext(
        targetPercent: Double,
        state: AutoControlState,
        controller: BrightnessController
    ) -> Double? {
        guard state == .on else { return nil }

        let hdrMode = controller.hdrRegionSamplerModeValue()
        let inHDRApp = HDRAppList.isFrontmostHDRApp()
        let shouldPauseRamp = (hdrMode == 3) && inHDRApp
        guard !shouldPauseRamp else { return nil }

        let current = controller.currentUserPercent()
        let step = inHDRApp && hdrMode == 3 ? max(0.10, rampStep * 0.6) : rampStep
        let desired = boundedEntryTarget(targetPercent: targetPercent)
        let dt = 1.0 / max(0.001, sampleHz)
        return ALSComputation.nextRampPercent(
            currentPercent: current,
            targetPercent: desired,
            entryMinPercent: entryMinPercent,
            maxPercentPerSecond: maxPercentPerSecond,
            dt: dt,
            step: step
        )
    }

    private func boundedEntryTarget(targetPercent: Double) -> Double {
        var allowed = 100.0
        if let t0 = edrEnabledAt {
            let elapsed = Date().timeIntervalSince(t0)
            let slope = (100.0 - entryMinPercent) / max(0.1, entryEnvelopeSeconds)
            allowed = min(100.0, entryMinPercent + slope * elapsed)
        }
        let desired = min(targetPercent, allowed)
        return max(entryMinPercent, desired)
    }

    private func computeGateDecision(
        lux: Double,
        state: AutoControlState,
        controller: BrightnessController
    ) -> ALSComputation.AutoGateResult {
        let canEnable = !(edrDisabledAt.map { Date().timeIntervalSince($0) < minOffSecondsGuard } ?? false) &&
            !controller.isDenylistBlocked()
        let canDisable = !(edrEnabledAt.map { Date().timeIntervalSince($0) < minOnSecondsGuard } ?? false)
        return ALSComputation.nextAutoGateState(
            lux: lux,
            isOn: state == .on,
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
    }

    private func applyGateAction(_ action: ALSComputation.AutoGateAction, controller: BrightnessController) {
        switch action {
        case .none:
            return
        case .enable:
            controller.setEnabled(true)
            edrEnabledAt = Date()
            controller.setUserPercent(entryMinPercent)
            traceStore.append(
                ALSTraceEvent(
                    kind: .masterAction,
                    isOn: true,
                    nextPercent: entryMinPercent,
                    gateAction: "enable",
                    reason: "auto_gate_enable"
                )
            )
        case .disable:
            controller.setEnabled(false)
            edrDisabledAt = Date()
            edrEnabledAt = nil
            controller.setUserPercent(0.0)
            traceStore.append(
                ALSTraceEvent(
                    kind: .masterAction,
                    isOn: false,
                    nextPercent: 0.0,
                    gateAction: "disable",
                    reason: "auto_gate_disable"
                )
            )
        }
    }

    private func actionString(_ action: ALSComputation.AutoGateAction) -> String {
        switch action {
        case .none: return "none"
        case .enable: return "enable"
        case .disable: return "disable"
        }
    }

    private func assertInvariants(lux: Double) {
        assert(lux.isFinite, "ALS lux must be finite")
        assert(aboveCount >= 0, "ALS aboveCount must be non-negative")
        assert(belowCount >= 0, "ALS belowCount must be non-negative")
        let percent = BrightnessController.shared.currentUserPercent()
        assert(percent >= 0.0 && percent <= 100.0, "ALS user percent must stay bounded")
    }

    private func percent(forLux lux: Double) -> Double {
        ALSComputation.percentForLux(lux: lux, onLux: onLux, entryMinPercent: entryMinPercent)
    }

    // MARK: - Profile API
    func getProfile() -> ALSProfile { profile }
    func getHardwareProfileID() -> ALSHardwareProfileID { hardwareProfileID }

    func setProfile(_ newProfile: ALSProfile) {
        guard newProfile != profile else { return }
        profile = newProfile
        Settings.alsProfileRaw = newProfile.rawValue
        // Reset smoothing + dwell counters on profile change
        lpState = nil
        aboveCount = 0; belowCount = 0
    }

    func setHardwareProfileID(_ id: ALSHardwareProfileID) {
        guard id != hardwareProfileID else { return }
        hardwareProfileID = id
        Settings.alsHardwareProfile = id
        warmupUntil = Date().addingTimeInterval(hardwareProfile.blendWarmupSeconds)
        lpState = nil
        aboveCount = 0
        belowCount = 0
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

    // MARK: - ALS trace controls (Debug)
    func setTraceCaptureEnabled(_ enabled: Bool) {
        traceStore.setCaptureEnabled(enabled)
    }

    func traceCaptureEnabled() -> Bool {
        traceStore.isCaptureEnabled()
    }

    func traceEventCount() -> Int {
        traceStore.count()
    }

    func clearTrace() {
        traceStore.clear()
        lastTraceExportJSONL = ""
    }

    func exportTraceJSONL() -> String {
        let jsonl = traceStore.exportJSONL()
        if !jsonl.isEmpty {
            lastTraceExportJSONL = jsonl
        }
        return jsonl
    }

    func replayLastTraceSummary() -> String {
        ALSReplay.replayLastExportSummary(jsonl: lastTraceExportJSONL)
    }

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
        guard let fitted = ALSComputation.fitCalibration(
            anchorA: (anchorA.dx, anchorA.lux),
            anchorB: (anchorB.dx, anchorB.lux),
            minAnchorValue: hardwareProfile.calibrationFitMinAnchorValue,
            pMin: hardwareProfile.calibrationPMin,
            pMax: hardwareProfile.calibrationPMax
        ) else { return }
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
        guard p.isFinite && p >= hardwareProfile.calibrationPMin && p <= hardwareProfile.calibrationPMax else { return }
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
