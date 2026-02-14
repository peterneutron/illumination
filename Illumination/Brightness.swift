//
//  Brightness.swift
//  Illumination
//

import Foundation
import AppKit

enum RuntimeControlMode: String, Codable {
    case off
    case manual
    case auto
}

struct RuntimeUIState: Equatable {
    let masterEnabled: Bool
    let mode: RuntimeControlMode
    let scope: Int
    let effectivePercent: Double
    let manualPercent: Double
    let tileEnabled: Bool
    let tileVisibleNow: Bool
    let denylistBlocked: Bool
    let blockedAppName: String?
    let appPolicyDiagnostics: String
    let experimentalHDRDiagnostics: String
}

final class BrightnessController {
    static let shared = BrightnessController()

    private typealias CapDetails = (
        cap: Double,
        rawCap: Double,
        bestRatio: Double,
        adaptiveMargin: Double,
        refGain: Double,
        refAlpha: Double,
        sawEDR: Bool,
        abStaticMode: Bool,
        guardFactor: Double
    )

    private struct AppPolicySnapshot {
        let masterEnabled: Bool
        let userPercent: Double
    }

    private struct CapDetailsCache {
        let details: CapDetails
        let expiresAt: Date
    }

    private let technique = GammaTechnique()
    private var enabled: Bool = false
    private var factor: Double = 1.0
    private var userPercent: Double = 100.0 // 0...100 user intent
    private var edrPolicyProfileID: EDRPolicyProfileID = .defaultProfile
    private var edrPolicy: EDRPolicyProfileConfig { EDRPolicyProfileCatalog.config(for: edrPolicyProfileID) }
    private var safetyMargin: Double { edrPolicy.safetyMargin } // base margin aimed to allow near-maximum when AB is on
    private var refSpan: Double { edrPolicy.refSpan } // scale for reference EDR lift normalization
    private var refAlpha: Double { edrPolicy.refAlpha } // exponent for reference gain impact
    private var capPoller: Timer?
    private var edrRecoveryTimer: Timer?
    private var edrLowStreak: Int = 0
    private var edrRecoveryPendingRevert: Bool = false
    // Guard mode controls (user-configurable)
    private var guardEnabled: Bool = false
    private var guardFactor: Double = 0.90
    // Removed legacy AB (Auto-Brightness) heuristics
    // HDR-aware auto-duck
    private var hdrAwareEnabled: Bool = false
    private var hdrAwareDuckPercent: Double = 50.0 // lower target percent during HDR
    private var hdrAwareThreshold: Double = EDRPolicyProfileCatalog.defaultConfig.hdrDefaultThreshold    // EDR ratio threshold to consider HDR present
    private var hdrRegionSamplerMode: Int = 0 // 0=Off,2=Auto,3=Apps
    private var hdrActiveStreak: Int = 0
    private var hdrInactiveStreak: Int = 0
    private let hdrDuckEngine = HDRDuckEngine()
    private var hdrDuckFadeDuration: Double = EDRPolicyProfileCatalog.defaultConfig.hdrDefaultFadeDuration // seconds
    private let hdrSampler = HDRRegionSampler()
    private var hdrLastFrontmostBundleID: String = "unknown"
    private var hdrLastMatch: Bool = false
    private var hdrLastGate: String = "Off"
    private var hdrLastSamplerStatus: String = "inactive"
    private var appPolicyScope: AppPolicyScope = .apps
    private var appPolicyFrontmostBundleID: String = "unknown"
    private var appPolicyDenylisted: Bool = false
    private var appPolicyResult: String = "allowed"
    private var appPolicyRestorePending: Bool = false
    private var denylistBlocked: Bool = false
    private var denylistSnapshot: AppPolicySnapshot?
    private var capDetailsCache: CapDetailsCache?

    private func onMainSync<T>(_ body: () -> T) -> T {
        if Thread.isMainThread { return body() }
        return DispatchQueue.main.sync(execute: body)
    }

    init() {
        precondition(Thread.isMainThread, "BrightnessController must be initialized on the main thread")
        edrPolicyProfileID = Settings.edrPolicyProfile
        // Restore persisted state
        let storedEnabled = Settings.masterEnabled
        let storedValue = Settings.brightnessFactor
        let maxCap = currentGammaCap()
        // Load guard settings
        self.guardEnabled = Settings.guardEnabled
        let gf = Settings.guardFactor
        self.guardFactor = Swift.max(0.70, Swift.min(0.98, gf))
        // Load HDR-aware settings
        self.hdrAwareEnabled = Settings.hdrAwareEnabled
        self.hdrAwareDuckPercent = Settings.hdrDuckPercent
        self.hdrAwareThreshold = Settings.hdrThreshold
        var storedMode = Settings.hdrRegionSamplerMode
        // Migration: remove legacy "On" (1); map to "Apps" (3).
        if storedMode == 1 { storedMode = 3; Settings.hdrRegionSamplerMode = storedMode }
        self.hdrRegionSamplerMode = storedMode
        self.hdrDuckFadeDuration = Settings.hdrFadeDuration
        self.appPolicyScope = AppPolicyScope(rawValue: Settings.appPolicyScope) ?? .everywhere
        // Migrate: if previous value looked like percentage (e.g. > 2.0), map to factor
        if let v = storedValue {
            if v >= 1.0 && v <= 2.0 {
                factor = Swift.max(1.0, Swift.min(maxCap, v))
                // derive percent from factor for sticky behavior
                userPercent = BrightnessController.percent(forFactor: factor, cap: maxCap)
            } else { // assume 0..100 percent
                userPercent = Swift.max(0.0, Swift.min(100.0, v))
                factor = BrightnessController.factor(forPercent: userPercent, cap: maxCap)
                Settings.brightnessFactor = factor
            }
        } else {
            factor = maxCap // default to max capability
            userPercent = 100.0
            Settings.brightnessFactor = factor
        }
        enabled = storedEnabled

        // Apply initial state
        if enabled {
            technique.enable()
            technique.adjust(factor: Float(factor))
            technique.setOverlayConfig(fullsize: overlayFullsizeEnabled(), fps: overlayFPSValue())
        }
        applyTileRuntimePolicyOnMain()

        // Listen for screen and wake events
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged(_:)), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screensDidWake(_:)), name: NSWorkspace.screensDidWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activeSpaceChanged(_:)), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        // Periodically adapt to runtime EDR changes (e.g., Auto-Brightness effects)
        startCapPoller()
    }

    @objc private func activeSpaceChanged(_ note: Notification) {
        invalidateCapDetailsCacheOnMain()
        // Refresh overlays on Space changes and nudge EDR to re-engage
        technique.screenUpdate(screens: targetDisplays())
        technique.setOverlayConfig(fullsize: overlayFullsizeEnabled(), fps: overlayFPSValue())
        technique.nudgeEDR()
    }

    func setEnabled(_ enabled: Bool) {
        onMainSync {
            setEnabledOnMain(enabled)
        }
    }

    private func setEnabledOnMain(_ enabled: Bool) {
        if denylistBlocked && enabled {
            self.enabled = false
            Settings.masterEnabled = false
            return
        }
        // If EDR not supported, force disabled
        let supportsEDR = currentGammaCapDetails().sawEDR
        let request = enabled && supportsEDR
        self.enabled = request
        // Persist master state so UI reflects changes from Auto as well
        Settings.masterEnabled = request
        if request {
            // Resume auxiliary visuals (tile) on main thread to avoid window-thread issues
            DispatchQueue.main.async {
                TileFeature.shared.resumeAfterMasterEnable()
            }
            technique.enable()
            technique.adjust(factor: Float(factor))
            technique.setOverlayConfig(fullsize: overlayFullsizeEnabled(), fps: overlayFPSValue())
        } else {
            // Suspend auxiliary visuals (tile) on main thread
            DispatchQueue.main.async {
                TileFeature.shared.suspendForMasterDisable()
            }
            edrRecoveryTimer?.invalidate()
            edrRecoveryTimer = nil
            technique.disable()
        }
        applyTileRuntimePolicyOnMain()
    }

    // Expose current master-enabled state for collaborators
    func appIsEnabled() -> Bool { onMainSync { enabled } }

    func setBrightnessFactor(_ factor: Double) {
        onMainSync {
            let maxCap = currentGammaCap()
            self.factor = Swift.max(1.0, Swift.min(maxCap, factor))
            // Update user intent based on current cap
            self.userPercent = BrightnessController.percent(forFactor: self.factor, cap: maxCap)
            Settings.brightnessFactor = self.factor
            if enabled {
                technique.adjust(factor: Float(self.factor))
            }
        }
    }

    // Backward-compat helper if any caller still passes percent
    func setBrightnessPercent(_ percent: Double) {
        setUserPercent(percent)
    }

    func setUserPercent(_ percent: Double) {
        onMainSync {
            let p = Swift.max(0.0, Swift.min(100.0, percent))
            userPercent = p
            let cap = currentGammaCap()
            self.factor = BrightnessController.factor(forPercent: p, cap: cap)
            Settings.brightnessFactor = self.factor
            if enabled {
                technique.adjust(factor: Float(self.factor))
            }
            applyTileRuntimePolicyOnMain()
        }
    }

    @objc private func screensChanged(_ note: Notification) {
        invalidateCapDetailsCacheOnMain()
        if enabled {
            technique.screenUpdate(screens: targetDisplays())
            // Recompute factor from user intent with new cap
            let cap = currentGammaCap()
            factor = BrightnessController.factor(forPercent: userPercent, cap: cap)
            technique.adjust(factor: Float(factor))
        }
        // Refresh display capability/probe info on topology changes
        _ = DisplayStateProbe.shared.probe()
    }

    @objc private func screensDidWake(_ note: Notification) {
        invalidateCapDetailsCacheOnMain()
        if enabled {
            let cap = currentGammaCap()
            factor = BrightnessController.factor(forPercent: userPercent, cap: cap)
            technique.adjust(factor: Float(factor))
        }
        // Refresh display capability after wake
        _ = DisplayStateProbe.shared.probe()
    }

    // MARK: - Cap computation

    func currentGammaCap() -> Double {
        onMainSync {
            // Inspect target displays for EDR capabilities, derive cap from ratio of max/reference EDR.
            currentGammaCapDetailsOnMain().cap
        }
    }

    func currentGammaCapDetails() -> (cap: Double, rawCap: Double, bestRatio: Double, adaptiveMargin: Double, refGain: Double, refAlpha: Double, sawEDR: Bool, abStaticMode: Bool, guardFactor: Double) {
        onMainSync {
            currentGammaCapDetailsOnMain()
        }
    }

    private func currentGammaCapDetailsCachedOnMain(maxAge: TimeInterval = 0.4) -> CapDetails {
        let now = Date()
        if let cache = capDetailsCache, now < cache.expiresAt {
            return cache.details
        }
        let details = currentGammaCapDetailsOnMain()
        capDetailsCache = CapDetailsCache(details: details, expiresAt: now.addingTimeInterval(maxAge))
        return details
    }

    private func invalidateCapDetailsCacheOnMain() {
        capDetailsCache = nil
    }

    private func currentGammaCapDetailsOnMain() -> (cap: Double, rawCap: Double, bestRatio: Double, adaptiveMargin: Double, refGain: Double, refAlpha: Double, sawEDR: Bool, abStaticMode: Bool, guardFactor: Double) {
        // Determine capability from ALL screens using potential EDR
        var anyScreenHasPotentialEDR = false
        for s in NSScreen.screens {
            if #available(macOS 14.0, *) {
                if s.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0 { anyScreenHasPotentialEDR = true; break }
            } else {
                if s.maximumExtendedDynamicRangeColorComponentValue > 1.0 { anyScreenHasPotentialEDR = true; break }
            }
        }

        // Derive cap from TARGET (built-in) displays only, using potential EDR
        let screens = targetDisplays()
        var bestRatio: Double = 1.0
        var bestRef: Double = 1.0
        var bestMaxPotentialEDR: Double = 1.0
        for screen in screens {
            let potential: Double
            if #available(macOS 14.0, *) {
                potential = Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
            } else {
                potential = Double(screen.maximumExtendedDynamicRangeColorComponentValue)
            }
            let refEDR = Double(screen.maximumReferenceExtendedDynamicRangeColorComponentValue)
            if potential > 1.0 {
                let denom = Swift.max(refEDR, 1.0)
                let ratio = potential / denom
                if potential > bestMaxPotentialEDR {
                    bestMaxPotentialEDR = potential
                    bestRatio = ratio
                    bestRef = denom
                }
            }
        }
        if bestMaxPotentialEDR > 1.0 {
            let adaptiveMargin: Double = safetyMargin
            // Reference gain (legacy; kept for debug visibility)
            let refGain = Swift.max(0.0, Swift.min(1.0, (bestRef - 1.0) / Swift.max(0.0001, refSpan)))
            let rawCap = 1.0 + (bestMaxPotentialEDR - 1.0) * adaptiveMargin
            let guardApplied = guardEnabled ? guardFactor : 1.0
            let capped = BrightnessController.effectiveCap(
                rawCap: rawCap,
                guardEnabled: guardEnabled,
                guardFactor: guardFactor
            )
            // Map abStaticMode to guardEnabled for compatibility with Debug UI
            return (capped, rawCap, bestRatio, adaptiveMargin, refGain, refAlpha, anyScreenHasPotentialEDR, guardEnabled, guardApplied)
        }
        // Fallback if EDR not reported/available: treat as SDR-only (cap = 1.0)
        let fallback = 1.0
        let guardApplied = guardEnabled ? guardFactor : 1.0
        let effective = BrightnessController.effectiveCap(
            rawCap: fallback,
            guardEnabled: guardEnabled,
            guardFactor: guardFactor
        )
        return (effective, fallback, 1.0, safetyMargin, 0.0, refAlpha, anyScreenHasPotentialEDR, guardEnabled, guardApplied)
    }

    // MARK: - Poller
    private func startCapPoller() {
        stopCapPoller()
        capPoller = Timer(fire: Date.now, interval: edrPolicy.capPollIntervalSeconds, repeats: true, block: { [weak self] _ in
            guard let self = self else { return }
            if self.shouldEvaluateAppPolicyOnIdle() {
                self.evaluateAppPolicyOverride()
            }
            if self.enabled {
                let details = self.currentGammaCapDetailsOnMain()
                let cap = details.cap
                let newFactor = BrightnessController.factor(forPercent: self.userPercent, cap: cap)
                var effective = newFactor
                // Experimental HDR ducking remains debug-only and must never override denylist policy.
                let shouldRunExperimental = BrightnessController.shouldRunExperimentalHDR(
                    mode: self.hdrRegionSamplerModeValue(),
                    hdrAwareEnabled: self.hdrAwareEnabled,
                    denylistBlocked: self.denylistBlocked
                )
                if shouldRunExperimental {
                    if self.isHDRContentLikely(bestRatioHint: details.bestRatio) {
                        self.hdrActiveStreak = min(self.edrPolicy.hdrStreakClamp, self.hdrActiveStreak + 1)
                        self.hdrInactiveStreak = 0
                    } else {
                        self.hdrInactiveStreak = min(self.edrPolicy.hdrStreakClamp, self.hdrInactiveStreak + 1)
                        self.hdrActiveStreak = 0
                    }
                    // Trigger tween when state flips
                    var desired: Double? = nil
                    if self.hdrActiveStreak >= self.edrPolicy.hdrActiveRequired { desired = 1.0 }
                    else if self.hdrInactiveStreak >= self.edrPolicy.hdrInactiveRequired { desired = 0.0 }
                    if let d = desired,
                       abs(d - self.hdrDuckEngine.duckLevel) > self.edrPolicy.hdrDuckAnimationEpsilon,
                       !self.hdrDuckEngine.isAnimating {
                        self.startHDRDuckAnimation(to: d, fps: self.edrPolicy.duckAnimationFPS)
                    }
                    if !self.hdrDuckEngine.isAnimating && self.hdrDuckEngine.duckLevel > self.edrPolicy.hdrDuckApplyMinLevel {
                        let duckTarget = BrightnessController.factor(forPercent: self.hdrAwareDuckPercent, cap: cap)
                        effective = (1.0 - self.hdrDuckEngine.duckLevel) * effective + self.hdrDuckEngine.duckLevel * duckTarget
                    }
                } else {
                    self.resetHDRExperimentalState(reason: "Off")
                }
                if !self.hdrDuckEngine.isAnimating {
                    if abs(effective - self.factor) > 0.0001 {
                        self.factor = effective
                        self.technique.adjust(factor: Float(self.factor))
                    }
                }
                // In paused mode, drive an occasional present to keep EDR alive without a tight loop
                // Skip pulses if the HDR tile is enabled; tile maintains EDR by itself.
                if self.userPercent > 0.0, !TileFeature.shared.enabled {
                    self.technique.pulseOverlays()
                }

                // EDR watchdog: if EDR appears disengaged (maxEDR ~ 1.0) while userPercent > 0, aggressively rebuild overlay in fullscreen mode and bump FPS
                if self.userPercent > 0.0 {
                    let bestMaxEDR = targetDisplays().map { Double($0.maximumExtendedDynamicRangeColorComponentValue) }.max() ?? 1.0
                    if bestMaxEDR <= self.edrPolicy.edrLowThreshold {
                        self.edrLowStreak += 1
                    } else {
                        self.edrLowStreak = 0
                    }
                } else {
                    self.edrLowStreak = 0
                }

                if self.edrLowStreak >= self.edrPolicy.edrLowRequiredStreak && !self.edrRecoveryPendingRevert {
                    self.edrRecoveryPendingRevert = true
                    // Force strong overlay presence
                    self.technique.setOverlayConfig(fullsize: true, fps: self.edrPolicy.recoveryOverlayFPS)
                    self.technique.screenUpdate(screens: targetDisplays())
                    self.technique.nudgeEDR()
                    // Revert to user prefs after a short burst
                    self.edrRecoveryTimer?.invalidate()
                    self.edrRecoveryTimer = Timer.scheduledTimer(withTimeInterval: self.edrPolicy.recoveryDurationSeconds, repeats: false) { [weak self] _ in
                        guard let self = self else { return }
                        self.technique.setOverlayConfig(fullsize: self.overlayFullsizeEnabled(), fps: self.overlayFPSValue())
                        self.edrRecoveryPendingRevert = false
                        self.edrRecoveryTimer = nil
                    }
                }
            }
        })
        capPoller?.tolerance = edrPolicy.capPollToleranceSeconds
        if let capPoller {
            RunLoop.main.add(capPoller, forMode: .common)
        }
    }

    private func shouldEvaluateAppPolicyOnIdle() -> Bool {
        BrightnessController.shouldEvaluateAppPolicy(
            scopeRaw: appPolicyScope.rawValue,
            denylistBlocked: denylistBlocked,
            hasDenylistSnapshot: denylistSnapshot != nil
        )
    }

    static func shouldEvaluateAppPolicy(scopeRaw: Int, denylistBlocked: Bool, hasDenylistSnapshot: Bool) -> Bool {
        scopeRaw == AppPolicyScope.apps.rawValue || denylistBlocked || hasDenylistSnapshot
    }

    private func evaluateAppPolicyOverride() {
        let frontmost = HDRAppList.frontmostAppInfoThrottled()
        let denylisted = HDRAppList.isBundleIDDenylisted(frontmost.bundleID)
        let decision = AppPolicy.decide(scope: appPolicyScope, frontmostDenylisted: denylisted)

        appPolicyFrontmostBundleID = frontmost.bundleID ?? "unknown"
        appPolicyDenylisted = denylisted
        appPolicyResult = decision.result
        appPolicyRestorePending = denylistSnapshot != nil

        if decision.isBlocked {
            if !denylistBlocked {
                denylistSnapshot = AppPolicySnapshot(masterEnabled: enabled, userPercent: userPercent)
            }
            denylistBlocked = true
            appPolicyRestorePending = denylistSnapshot != nil
            resetHDRExperimentalState(reason: "Blocked by denylist")
            setEnabledOnMain(false)
            return
        }

        if denylistBlocked, let snapshot = denylistSnapshot {
            denylistBlocked = false
            denylistSnapshot = nil
            appPolicyRestorePending = false

            userPercent = snapshot.userPercent
            let restoreCap = currentGammaCap()
            factor = BrightnessController.factor(forPercent: userPercent, cap: restoreCap)
            Settings.brightnessFactor = factor
            setEnabledOnMain(snapshot.masterEnabled)
            if snapshot.masterEnabled {
                technique.adjust(factor: Float(factor))
            }
        } else {
            denylistBlocked = false
            appPolicyRestorePending = false
        }
    }

    private func stopCapPoller() {
        capPoller?.invalidate()
        capPoller = nil
        edrRecoveryTimer?.invalidate()
        edrRecoveryTimer = nil
    }

    private func startHDRDuckAnimation(to target: Double, fps: Double) {
        let fade = hdrDuckFadeDuration
        hdrDuckEngine.start(to: target, fade: fade, fps: fps, onProgress: { [weak self] (level: Double) in
            guard let self = self else { return }
            // Recompute effective factor and apply
            let details = self.currentGammaCapDetails()
            let cap = details.cap
            let base = BrightnessController.factor(forPercent: self.userPercent, cap: cap)
            let duckTarget = BrightnessController.factor(forPercent: self.hdrAwareDuckPercent, cap: cap)
            var effective = (1.0 - level) * base + level * duckTarget
            effective = Swift.max(1.0, Swift.min(cap, effective))
            if abs(effective - self.factor) > 0.0001 {
                self.factor = effective
                self.technique.adjust(factor: Float(self.factor))
            }
        })
    }

    // MARK: - Guard controls
    func isGuardEnabled() -> Bool { onMainSync { guardEnabled } }
    func guardFactorValue() -> Double { onMainSync { guardFactor } }
    func currentFactorValue() -> Double { onMainSync { factor } }
    func currentUserPercent() -> Double { onMainSync { userPercent } }
    static func factor(forPercent percent: Double, cap: Double) -> Double {
        let p = Swift.max(0.0, Swift.min(100.0, percent))
        let boundedCap = Swift.max(1.0, cap)
        let factor = 1.0 + (boundedCap - 1.0) * (p / 100.0)
        return Swift.max(1.0, Swift.min(boundedCap, factor))
    }

    static func percent(forFactor factor: Double, cap: Double) -> Double {
        let boundedCap = Swift.max(1.0, cap)
        let denom = Swift.max(0.0001, (boundedCap - 1.0))
        let boundedFactor = Swift.max(1.0, Swift.min(boundedCap, factor))
        let pct = (boundedFactor - 1.0) / denom * 100.0
        return Swift.max(0.0, Swift.min(100.0, pct))
    }
    static func effectiveCap(rawCap: Double, guardEnabled: Bool, guardFactor: Double) -> Double {
        let preClamped = Swift.min(Swift.max(1.0, rawCap), 1.70)
        let guardApplied = guardEnabled ? Swift.max(0.70, Swift.min(0.98, guardFactor)) : 1.0
        return Swift.max(1.0, preClamped * guardApplied)
    }

    static func shouldSuspendTileForCurrentMode(masterEnabled: Bool, autoEnabled: Bool, percent: Double) -> Bool {
        guard masterEnabled else { return false }
        guard !autoEnabled else { return false }
        return percent <= 0.0
    }

    private func applyTileRuntimePolicyOnMain() {
        let auto = Settings.alsAutoEnabled
        let suspend = BrightnessController.shouldSuspendTileForCurrentMode(
            masterEnabled: enabled,
            autoEnabled: auto,
            percent: userPercent
        )
        if suspend {
            TileFeature.shared.suspendForALS()
        } else {
            TileFeature.shared.resumeAfterALS()
        }
    }

    func reapplyTileRuntimePolicy() {
        onMainSync {
            applyTileRuntimePolicyOnMain()
        }
    }

    // MARK: - Overlay controls
    func overlayFullsizeEnabled() -> Bool { onMainSync { Settings.overlayFullsize } }
    func setOverlayFullsize(_ enabled: Bool) {
        onMainSync {
            Settings.overlayFullsize = enabled
            technique.setOverlayConfig(fullsize: enabled, fps: overlayFPSValue())
        }
    }
    func overlayFPSValue() -> Int { onMainSync { Settings.overlayFPS } }
    func setOverlayFPS(_ fps: Int) {
        onMainSync {
            Settings.overlayFPS = fps
            technique.setOverlayConfig(fullsize: overlayFullsizeEnabled(), fps: Settings.overlayFPS)
        }
    }
    func edrNudge() {
        onMainSync {
            technique.nudgeEDR()
        }
    }
    // MARK: - HDR-aware controls
    func hdrAwareIsEnabled() -> Bool { onMainSync { hdrAwareEnabled } }
    func setHDRAwareEnabled(_ enabled: Bool) {
        onMainSync {
            hdrAwareEnabled = enabled
            Settings.hdrAwareEnabled = enabled
            if !enabled {
                resetHDRExperimentalState(reason: "Off")
            }
        }
    }
    func hdrAwareDuckPercentValue() -> Double { onMainSync { hdrAwareDuckPercent } }
    func setHDRAwareDuckPercent(_ percent: Double) {
        onMainSync {
            let p = Swift.max(0.0, Swift.min(100.0, percent))
            hdrAwareDuckPercent = p
            Settings.hdrDuckPercent = p
        }
    }
    func hdrAwareThresholdValue() -> Double { onMainSync { hdrAwareThreshold } }
    func setHDRAwareThreshold(_ v: Double) {
        onMainSync {
            let val = Swift.max(1.1, Swift.min(3.0, v))
            hdrAwareThreshold = val
            Settings.hdrThreshold = val
        }
    }
    // 0=Off,2=Auto(app+sampler),3=Apps(app-only)
    func hdrRegionSamplerModeValue() -> Int { onMainSync { max(0, min(3, hdrRegionSamplerMode)) } }
    func setHDRRegionSamplerMode(_ mode: Int) {
        onMainSync {
            hdrRegionSamplerMode = max(0, min(3, mode))
            Settings.hdrRegionSamplerMode = hdrRegionSamplerMode
            if hdrRegionSamplerMode == 0 {
                resetHDRExperimentalState(reason: "Off")
            }
        }
    }
    func hdrAwareFadeDurationValue() -> Double { onMainSync { hdrDuckFadeDuration } }
    func setHDRAwareFadeDuration(_ seconds: Double) {
        onMainSync {
            let v = Swift.max(0.05, Swift.min(2.0, seconds))
            hdrDuckFadeDuration = v
            Settings.hdrFadeDuration = v
        }
    }

    func appPolicyScopeValue() -> Int { onMainSync { appPolicyScope.rawValue } }
    func edrPolicyProfileIDValue() -> EDRPolicyProfileID { onMainSync { edrPolicyProfileID } }
    func setEDRPolicyProfileID(_ id: EDRPolicyProfileID) {
        onMainSync {
            guard edrPolicyProfileID != id else { return }
            edrPolicyProfileID = id
            Settings.edrPolicyProfile = id
            invalidateCapDetailsCacheOnMain()
        }
    }
    func setAppPolicyScope(_ scope: Int) {
        onMainSync {
            appPolicyScope = AppPolicyScope(rawValue: scope) ?? .everywhere
            Settings.appPolicyScope = appPolicyScope.rawValue
            if appPolicyScope == .everywhere {
                denylistBlocked = false
                appPolicyResult = "allowed"
            }
        }
    }
    func isDenylistBlocked() -> Bool { onMainSync { denylistBlocked } }

    private func isHDRContentLikely(bestRatioHint: Double) -> Bool {
        _ = bestRatioHint
        // Use region sampler based on mode; gate by app list in Auto/Apps.
        let mode = hdrRegionSamplerModeValue()
        let frontmost = HDRAppList.frontmostAppInfo()
        let matched = !HDRAppList.isBundleIDDenylisted(frontmost.bundleID)
        hdrLastFrontmostBundleID = frontmost.bundleID ?? "unknown"
        hdrLastMatch = matched

        // Start/stop sampler based on mode/app (Auto only)
        let mainDisplay = NSScreen.main?.displayId ?? 0
        let shouldSample = (mode == 2) && matched
        if shouldSample, mainDisplay != 0 {
            hdrSampler.start(displayID: mainDisplay)
        } else {
            hdrSampler.stop()
        }

        let gate = BrightnessController.hdrGateDecision(mode: mode, appMatched: matched, samplerHDRPresent: hdrSampler.hdrPresent)
        hdrLastGate = gate.gate
        hdrLastSamplerStatus = hdrSampler.status.debugLabel
        return gate.allowed
    }

    private func resetHDRExperimentalState(reason: String) {
        hdrSampler.stop()
        hdrDuckEngine.reset()
        hdrActiveStreak = 0
        hdrInactiveStreak = 0
        let frontmost = HDRAppList.frontmostAppInfo()
        hdrLastFrontmostBundleID = frontmost.bundleID ?? "unknown"
        hdrLastMatch = false
        hdrLastGate = reason
        hdrLastSamplerStatus = hdrSampler.status.debugLabel
    }

    static func modeName(_ mode: Int) -> String {
        switch mode { case 2: return "Auto"; case 3: return "Apps"; default: return "Off" }
    }

    static func hdrGateDecision(mode: Int, appMatched: Bool, samplerHDRPresent: Bool) -> (allowed: Bool, gate: String) {
        switch mode {
        case 0:
            return (false, "Off")
        case 2:
            if !appMatched { return (false, "Auto blocked") }
            if samplerHDRPresent { return (true, "Auto allowed") }
            return (false, "Auto blocked")
        case 3:
            if appMatched { return (true, "Apps allowed") }
            return (false, "Apps blocked")
        default:
            return (false, "Off")
        }
    }

    static func shouldRunExperimentalHDR(mode: Int, hdrAwareEnabled: Bool, denylistBlocked: Bool) -> Bool {
        #if DEBUG
        return hdrAwareEnabled && mode != 0 && !denylistBlocked
        #else
        _ = mode
        _ = hdrAwareEnabled
        _ = denylistBlocked
        return false
        #endif
    }

    func hdrDetectionDiagnostics() -> (frontmostBundleID: String, matched: Bool, gate: String, samplerStatus: String, experimentalEnabled: Bool) {
        onMainSync { (hdrLastFrontmostBundleID, hdrLastMatch, hdrLastGate, hdrLastSamplerStatus, hdrAwareEnabled) }
    }

    func appPolicyDiagnostics() -> (frontmostBundleID: String, denylisted: Bool, scope: String, result: String, restorePending: Bool) {
        onMainSync { (appPolicyFrontmostBundleID, appPolicyDenylisted, appPolicyScope.displayName, appPolicyResult, appPolicyRestorePending) }
    }
    func setGuardEnabled(_ enabled: Bool) {
        onMainSync {
            guardEnabled = enabled
            Settings.guardEnabled = enabled
            invalidateCapDetailsCacheOnMain()
        }
    }
    func setGuardFactor(_ factor: Double) {
        onMainSync {
            let clamped = Swift.max(0.70, Swift.min(0.98, factor))
            guardFactor = clamped
            Settings.guardFactor = clamped
            invalidateCapDetailsCacheOnMain()
        }
    }

    func uiStateSnapshot() -> RuntimeUIState {
        onMainSync {
            uiStateSnapshotOnMain()
        }
    }

    private func uiStateSnapshotOnMain() -> RuntimeUIState {
        let autoEnabled = ALSManager.shared.autoEnabled
        let mode: RuntimeControlMode = autoEnabled ? .auto : (enabled ? .manual : .off)
        let cap = currentGammaCapDetailsCachedOnMain().cap
        let effective = enabled ? BrightnessController.percent(forFactor: factor, cap: cap) : 0.0
        let blockedName: String? = (denylistBlocked && appPolicyFrontmostBundleID != "unknown") ? appPolicyFrontmostBundleID : nil
        return RuntimeUIState(
            masterEnabled: enabled,
            mode: mode,
            scope: appPolicyScope.rawValue,
            effectivePercent: effective,
            manualPercent: userPercent,
            tileEnabled: TileFeature.shared.enabled,
            tileVisibleNow: TileFeature.shared.isCurrentlyVisible,
            denylistBlocked: denylistBlocked,
            blockedAppName: blockedName,
            appPolicyDiagnostics: "",
            experimentalHDRDiagnostics: ""
        )
    }
}
    // MARK: - HDR ducking engine
    private final class HDRDuckEngine {
        private(set) var duckLevel: Double = 0.0 // 0..1
        private var timer: Timer?
        private var animStart: Date?
        private var startLevel: Double = 0.0
        private var targetLevel: Double = 0.0
        private var fadeDuration: Double = EDRPolicyProfileCatalog.defaultConfig.hdrDefaultFadeDuration

        var isAnimating: Bool { timer != nil }

        func stop() { timer?.invalidate(); timer = nil }
        func reset() { stop(); duckLevel = 0.0 }

        func start(
            to target: Double,
            fade: Double,
            fps: Double,
            onProgress: @escaping (Double) -> Void,
            onEnd: (() -> Void)? = nil
        ) {
            stop()
            fadeDuration = max(0.05, fade)
            animStart = Date()
            startLevel = duckLevel
            targetLevel = max(0.0, min(1.0, target))
            let interval = 1.0 / max(1.0, fps)
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] t in
                guard let self = self, let start = self.animStart else { t.invalidate(); return }
                let elapsed = Date().timeIntervalSince(start)
                var tnorm = min(1.0, elapsed / self.fadeDuration)
                // smoothstep
                tnorm = tnorm * tnorm * (3.0 - 2.0 * tnorm)
                self.duckLevel = self.startLevel + (self.targetLevel - self.startLevel) * tnorm
                onProgress(self.duckLevel)
                if tnorm >= 1.0 { t.invalidate(); onEnd?() }
            }
            if let tm = timer { RunLoop.main.add(tm, forMode: .common) }
        }
    }
