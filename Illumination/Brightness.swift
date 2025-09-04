//
//  Brightness.swift
//  Illumination
//

import Foundation
import AppKit

extension NSScreen {
    var displayId: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? CGDirectDisplayID
    }
}

private func isBuiltInScreen(_ screen: NSScreen) -> Bool {
    guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
    return CGDisplayIsBuiltin(num) != 0
}

private func targetDisplays() -> [NSScreen] {
    // Minimal: affect built-in display(s) only
    NSScreen.screens.filter { isBuiltInScreen($0) }
}

private class GammaTable {
    static let tableSize: UInt32 = 256
    var red: [CGGammaValue] = .init(repeating: 0, count: Int(tableSize))
    var green: [CGGammaValue] = .init(repeating: 0, count: Int(tableSize))
    var blue: [CGGammaValue] = .init(repeating: 0, count: Int(tableSize))

    static func capture(displayId: CGDirectDisplayID) -> GammaTable? {
        let t = GammaTable()
        var sampleCount: UInt32 = 0
        let res = CGGetDisplayTransferByTable(displayId, tableSize, &t.red, &t.green, &t.blue, &sampleCount)
        return res == .success ? t : nil
    }

    func apply(displayId: CGDirectDisplayID, factor: Float) {
        var r = red, g = green, b = blue
        if factor != 1.0 {
            for i in 0..<r.count { r[i] *= factor }
            for i in 0..<g.count { g[i] *= factor }
            for i in 0..<b.count { b[i] *= factor }
        }
        CGSetDisplayTransferByTable(displayId, GammaTable.tableSize, &r, &g, &b)
    }
}

final class GammaTechnique {
    private(set) var isEnabled = false
    private var gammaTables: [CGDirectDisplayID: GammaTable] = [:]
    private var overlayWindowControllers: [CGDirectDisplayID: OverlayWindowController] = [:]
    private var desiredFullsize: Bool = true
    private var desiredFPS: Int = 30
    private var nudgeTimer: Timer?
    private var overlaysPaused: Bool = true

    func enable() {
        for screen in targetDisplays() {
            enableScreen(screen: screen)
        }
        isEnabled = true
    }

    private func enableScreen(screen: NSScreen) {
        guard let id = screen.displayId else { return }
        if gammaTables[id] == nil {
            gammaTables[id] = GammaTable.capture(displayId: id)
        }
        if overlayWindowControllers[id] == nil {
            let controller = OverlayWindowController(screen: screen, fullsize: desiredFullsize)
            overlayWindowControllers[id] = controller
            let rect = NSRect(x: screen.frame.origin.x, y: screen.frame.origin.y, width: 1, height: 1)
            controller.open(rect: rect)
            controller.setFPS(desiredFPS)
        }
    }

    func disable() {
        isEnabled = false
        overlayWindowControllers.values.forEach { $0.window?.close() }
        overlayWindowControllers.removeAll()
        gammaTables.removeAll()
        CGDisplayRestoreColorSyncSettings()
    }

    func adjust(factor: Float) {
        guard isEnabled else { return }
        for screen in targetDisplays() {
            if let id = screen.displayId {
                if gammaTables[id] == nil {
                    gammaTables[id] = GammaTable.capture(displayId: id)
                }
                gammaTables[id]?.apply(displayId: id, factor: factor)
            }
        }
    }

    func screenUpdate(screens: [NSScreen]) {
        let currentIds = Set(screens.compactMap { $0.displayId })
        let knownIds = Set(overlayWindowControllers.keys)
        // Close overlays no longer needed
        for id in knownIds.subtracting(currentIds) {
            overlayWindowControllers[id]?.window?.close()
            overlayWindowControllers.removeValue(forKey: id)
            gammaTables.removeValue(forKey: id)
        }
        // Add or reposition overlays for current screens
        for screen in screens {
            guard let id = screen.displayId else { continue }
            if let ctrl = overlayWindowControllers[id] {
                ctrl.reposition(screen: screen)
            } else {
                enableScreen(screen: screen)
            }
        }
    }

    func setOverlayConfig(fullsize: Bool, fps: Int) {
        desiredFullsize = fullsize
        desiredFPS = fps
        for (id, ctrl) in overlayWindowControllers {
            if ctrl.fullsize != fullsize, NSScreen.screens.first(where: { $0.displayId == id }) != nil {
                ctrl.recreate(fullsize: fullsize)
                ctrl.setFPS(fps)
                ctrl.setPausedDrawLoop(true)
            } else {
                ctrl.setFPS(fps)
                ctrl.setPausedDrawLoop(true)
            }
            ctrl.requestRedraw()
        }
        overlaysPaused = true
    }

    func nudgeEDR() {
        // Temporarily unpause and bump FPS to strongly refresh EDR
        // Temporarily unpause and bump FPS to strongly refresh EDR
        for (_, ctrl) in overlayWindowControllers { ctrl.setPausedDrawLoop(false) }
        setOverlayConfig(fullsize: desiredFullsize, fps: max(desiredFPS, 60))
        nudgeTimer?.invalidate()
        nudgeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.setOverlayConfig(fullsize: self.desiredFullsize, fps: self.desiredFPS)
            for (_, ctrl) in self.overlayWindowControllers { ctrl.setPausedDrawLoop(true) }
        }
    }

    func pulseOverlays() {
        for (_, ctrl) in overlayWindowControllers { ctrl.requestRedraw() }
    }
}

final class BrightnessController {
    static let shared = BrightnessController()

    private let technique = GammaTechnique()
    private var enabled: Bool = false
    private var factor: Double = 1.0
    private var userPercent: Double = 100.0 // 0...100 user intent
    private let safetyMargin: Double = 0.98 // base margin aimed to allow near-maximum when AB is on
    private let refSpan: Double = 0.6 // scale for reference EDR lift normalization
    private let refAlpha: Double = 1.0 // exponent for reference gain impact
    private var capPoller: Timer?
    private var edrLowStreak: Int = 0
    private var edrRecoveryPendingRevert: Bool = false
    // Guard mode controls (user-configurable)
    private let guardEnabledKey = "illumination.guard.enabled"
    private let guardFactorKey = "illumination.guard.factor"
    private var guardEnabled: Bool = false
    private var guardFactor: Double = 0.90
    // Removed legacy AB (Auto-Brightness) heuristics
    // HDR-aware auto-duck
    private let hdrAwareEnabledKey = "illumination.hdraware.enabled"
    private let hdrAwareDuckPercentKey = "illumination.hdraware.duck.percent"
    private let hdrAwareThresholdKey = "illumination.hdraware.threshold"
    private let hdrRegionSamplerModeKey = "illumination.hdraware.regionsampler.mode" // 0=Off,1=On,2=Auto,3=Apps
    private let hdrAwareFadeDurationKey = "illumination.hdraware.fade.duration"
    private var hdrAwareEnabled: Bool = false
    private var hdrAwareDuckPercent: Double = 50.0 // lower target percent during HDR
    private var hdrAwareThreshold: Double = 1.5    // EDR ratio threshold to consider HDR present
    private var hdrRegionSamplerMode: Int = 0 // 0=Off,1=Auto,2=Always
    private var hdrActiveStreak: Int = 0
    private var hdrInactiveStreak: Int = 0
    private var hdrDuckLevel: Double = 0.0 // 0..1 ramp
    private var hdrDuckAnimating: Bool = false
    private var hdrDuckTimer: Timer?
    private var hdrDuckAnimStart: Date?
    private var hdrDuckStartLevel: Double = 0.0
    private var hdrDuckTargetLevel: Double = 0.0
    private var hdrDuckFadeDuration: Double = 0.25 // seconds
    private let hdrSampler = HDRRegionSampler()

    init() {
        // Restore persisted state
        let defaults = UserDefaults.standard
        let storedEnabled = defaults.object(forKey: "illumination.enabled") as? Bool ?? false
        let storedValue = defaults.object(forKey: "illumination.brightness") as? Double
        let maxCap = currentGammaCap()
        // Load guard settings
        self.guardEnabled = defaults.object(forKey: guardEnabledKey) as? Bool ?? false
        let gf = defaults.object(forKey: guardFactorKey) as? Double ?? 0.90
        self.guardFactor = Swift.max(0.70, Swift.min(0.98, gf))
        // Load HDR-aware settings
        self.hdrAwareEnabled = defaults.object(forKey: hdrAwareEnabledKey) as? Bool ?? false
        self.hdrAwareDuckPercent = defaults.object(forKey: hdrAwareDuckPercentKey) as? Double ?? 50.0
        self.hdrAwareThreshold = defaults.object(forKey: hdrAwareThresholdKey) as? Double ?? 1.5
        var storedMode = defaults.object(forKey: hdrRegionSamplerModeKey) as? Int ?? 0
        // Migration: remove "On" (1); map to "Apps" (3). Keep Auto (2) but hidden in UI.
        if storedMode == 1 { storedMode = 3; defaults.set(storedMode, forKey: hdrRegionSamplerModeKey) }
        self.hdrRegionSamplerMode = storedMode
        self.hdrDuckFadeDuration = defaults.object(forKey: hdrAwareFadeDurationKey) as? Double ?? 0.25
        // Migrate: if previous value looked like percentage (e.g. > 2.0), map to factor
        if let v = storedValue {
            if v >= 1.0 && v <= 2.0 {
                factor = Swift.max(1.0, Swift.min(maxCap, v))
                // derive percent from factor for sticky behavior
                userPercent = BrightnessController.percent(forFactor: factor, cap: maxCap)
            } else { // assume 0..100 percent
                let p = Swift.max(0.0, Swift.min(100.0, v)) / 100.0
                userPercent = p * 100.0
                factor = 1.0 + (maxCap - 1.0) * p
                defaults.set(factor, forKey: "illumination.brightness")
            }
        } else {
            factor = maxCap // default to max capability
            userPercent = 100.0
            defaults.set(factor, forKey: "illumination.brightness")
        }
        enabled = storedEnabled

        // Apply initial state
        if enabled {
            technique.enable()
            technique.adjust(factor: Float(factor))
            technique.setOverlayConfig(fullsize: overlayFullsizeEnabled(), fps: overlayFPSValue())
        }

        // Listen for screen and wake events
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged(_:)), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screensDidWake(_:)), name: NSWorkspace.screensDidWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activeSpaceChanged(_:)), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        // Periodically adapt to runtime EDR changes (e.g., Auto-Brightness effects)
        startCapPoller()
    }

    @objc private func activeSpaceChanged(_ note: Notification) {
        // Refresh overlays on Space changes and nudge EDR to re-engage
        technique.screenUpdate(screens: targetDisplays())
        technique.setOverlayConfig(fullsize: overlayFullsizeEnabled(), fps: overlayFPSValue())
        technique.nudgeEDR()
    }

    func setEnabled(_ enabled: Bool) {
        // If EDR not supported, force disabled
        let supportsEDR = currentGammaCapDetails().sawEDR
        let request = enabled && supportsEDR
        self.enabled = request
        // Persist master state so UI reflects changes from Auto as well
        UserDefaults.standard.set(request, forKey: "illumination.enabled")
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
            technique.disable()
        }
    }

    // Expose current master-enabled state for collaborators
    func appIsEnabled() -> Bool { enabled }

    func setBrightnessFactor(_ factor: Double) {
        let maxCap = currentGammaCap()
        self.factor = Swift.max(1.0, Swift.min(maxCap, factor))
        // Update user intent based on current cap
        self.userPercent = BrightnessController.percent(forFactor: self.factor, cap: maxCap)
        UserDefaults.standard.set(self.factor, forKey: "illumination.brightness")
        if enabled {
            technique.adjust(factor: Float(self.factor))
        }
    }

    // Backward-compat helper if any caller still passes percent
    func setBrightnessPercent(_ percent: Double) {
        setUserPercent(percent)
    }

    func setUserPercent(_ percent: Double) {
        let p = Swift.max(0.0, Swift.min(100.0, percent))
        userPercent = p
        let cap = currentGammaCap()
        let f = 1.0 + (cap - 1.0) * (p / 100.0)
        self.factor = Swift.max(1.0, Swift.min(cap, f))
        UserDefaults.standard.set(self.factor, forKey: "illumination.brightness")
        if enabled {
            technique.adjust(factor: Float(self.factor))
        }
    }

    @objc private func screensChanged(_ note: Notification) {
        if enabled {
            technique.screenUpdate(screens: targetDisplays())
            // Recompute factor from user intent with new cap
            let cap = currentGammaCap()
            let target = 1.0 + (cap - 1.0) * (userPercent / 100.0)
            factor = Swift.min(target, cap)
            technique.adjust(factor: Float(factor))
        }
        // Refresh display capability/probe info on topology changes
        _ = DisplayStateProbe.shared.probe()
    }

    @objc private func screensDidWake(_ note: Notification) {
        if enabled {
            let cap = currentGammaCap()
            let target = 1.0 + (cap - 1.0) * (userPercent / 100.0)
            factor = Swift.min(target, cap)
            technique.adjust(factor: Float(factor))
        }
        // Refresh display capability after wake
        _ = DisplayStateProbe.shared.probe()
    }

    // MARK: - Cap computation

    func currentGammaCap() -> Double {
        // Inspect target displays for EDR capabilities, derive cap from ratio of max/reference EDR.
        return currentGammaCapDetails().cap
    }

    func currentGammaCapDetails() -> (cap: Double, rawCap: Double, bestRatio: Double, adaptiveMargin: Double, refGain: Double, refAlpha: Double, sawEDR: Bool, abStaticMode: Bool, guardFactor: Double) {
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
            // Apply ceiling first, then guard, so guard can reduce below the ceiling
            let preClamped = Swift.min(rawCap, 1.70)
            let effectiveCap = preClamped * guardApplied
            let capped = Swift.max(1.0, effectiveCap)
            // Map abStaticMode to guardEnabled for compatibility with Debug UI
            return (capped, rawCap, bestRatio, adaptiveMargin, refGain, refAlpha, anyScreenHasPotentialEDR, guardEnabled, guardApplied)
        }
        // Fallback if EDR not reported/available: treat as SDR-only (cap = 1.0)
        let fallback = 1.0
        let guardApplied = guardEnabled ? guardFactor : 1.0
        let effective = fallback * guardApplied
        return (effective, fallback, 1.0, safetyMargin, 0.0, refAlpha, anyScreenHasPotentialEDR, guardEnabled, guardApplied)
    }

    // MARK: - Poller
    private func startCapPoller() {
        stopCapPoller()
        capPoller = Timer(fire: Date.now, interval: 1.0, repeats: true, block: { [weak self] _ in
            guard let self = self else { return }
            let details = self.currentGammaCapDetails()
            let cap = details.cap
            if self.enabled {
                let target = 1.0 + (cap - 1.0) * (self.userPercent / 100.0)
                let newFactor = Swift.max(1.0, Swift.min(cap, target))
                var effective = newFactor
                // HDR-aware auto-duck (driven by detection mode)
                if self.hdrRegionSamplerModeValue() != 0 {
                    if self.isHDRContentLikely(bestRatioHint: details.bestRatio) {
                        self.hdrActiveStreak = min(10, self.hdrActiveStreak + 1)
                        self.hdrInactiveStreak = 0
                    } else {
                        self.hdrInactiveStreak = min(10, self.hdrInactiveStreak + 1)
                        self.hdrActiveStreak = 0
                    }
                    // Trigger tween when state flips
                    var desired: Double? = nil
                    if self.hdrActiveStreak >= 2 { desired = 1.0 }
                    else if self.hdrInactiveStreak >= 3 { desired = 0.0 }
                    if let d = desired, abs(d - self.hdrDuckLevel) > 0.001, !self.hdrDuckAnimating {
                        self.startHDRDuckAnimation(to: d)
                    }
                    if !self.hdrDuckAnimating && self.hdrDuckLevel > 0.0001 {
                        let duckTarget = 1.0 + (cap - 1.0) * (self.hdrAwareDuckPercent / 100.0)
                        effective = (1.0 - self.hdrDuckLevel) * effective + self.hdrDuckLevel * duckTarget
                    }
                }
                if !self.hdrDuckAnimating {
                    if abs(effective - self.factor) > 0.0001 {
                        self.factor = effective
                        self.technique.adjust(factor: Float(self.factor))
                    }
                }
                // In paused mode, drive an occasional present to keep EDR alive without a tight loop
                // Skip pulses if the HDR tile is enabled; tile maintains EDR by itself.
                if !TileFeature.shared.enabled {
                    self.technique.pulseOverlays()
                }

                // EDR watchdog: if EDR appears disengaged (maxEDR ~ 1.0) while userPercent > 0, aggressively rebuild overlay in fullscreen mode and bump FPS
                let bestMaxEDR = targetDisplays().map { Double($0.maximumExtendedDynamicRangeColorComponentValue) }.max() ?? 1.0
                if self.userPercent > 0.0 && bestMaxEDR <= 1.05 {
                    self.edrLowStreak += 1
                } else {
                    self.edrLowStreak = 0
                }

                if self.edrLowStreak >= 2 && !self.edrRecoveryPendingRevert { // sustained low for ~2s
                    self.edrRecoveryPendingRevert = true
                    // Force strong overlay presence
                    self.technique.setOverlayConfig(fullsize: true, fps: 60)
                    self.technique.screenUpdate(screens: targetDisplays())
                    self.technique.nudgeEDR()
                    // Revert to user prefs after a short burst
                    Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                        guard let self = self else { return }
                        self.technique.setOverlayConfig(fullsize: self.overlayFullsizeEnabled(), fps: self.overlayFPSValue())
                        self.edrRecoveryPendingRevert = false
                    }
                }
            }
        })
        RunLoop.main.add(capPoller!, forMode: .common)
    }

    private func stopCapPoller() {
        capPoller?.invalidate()
        capPoller = nil
    }

    private func startHDRDuckAnimation(to target: Double) {
        hdrDuckTimer?.invalidate(); hdrDuckTimer = nil
        hdrDuckAnimating = true
        hdrDuckAnimStart = Date()
        hdrDuckStartLevel = hdrDuckLevel
        hdrDuckTargetLevel = target
        let interval = 1.0 / 30.0 // 30 Hz
        hdrDuckTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true, block: { [weak self] timer in
            guard let self = self, let start = self.hdrDuckAnimStart else { timer.invalidate(); return }
            let elapsed = Date().timeIntervalSince(start)
            let dur = max(0.05, self.hdrDuckFadeDuration)
            var t = min(1.0, elapsed / dur)
            // Smoothstep ease-in-out
            t = t * t * (3.0 - 2.0 * t)
            self.hdrDuckLevel = self.hdrDuckStartLevel + (self.hdrDuckTargetLevel - self.hdrDuckStartLevel) * t
            // Recompute effective factor and apply
            let details = self.currentGammaCapDetails()
            let cap = details.cap
            let base = 1.0 + (cap - 1.0) * (self.userPercent / 100.0)
            let duckTarget = 1.0 + (cap - 1.0) * (self.hdrAwareDuckPercent / 100.0)
            var effective = (1.0 - self.hdrDuckLevel) * base + self.hdrDuckLevel * duckTarget
            effective = Swift.max(1.0, Swift.min(cap, effective))
            if abs(effective - self.factor) > 0.0001 {
                self.factor = effective
                self.technique.adjust(factor: Float(self.factor))
            }
            if t >= 1.0 {
                self.hdrDuckAnimating = false
                timer.invalidate()
            }
        })
        RunLoop.main.add(hdrDuckTimer!, forMode: .common)
    }

    // MARK: - Guard controls
    func isGuardEnabled() -> Bool { guardEnabled }
    func guardFactorValue() -> Double { guardFactor }
    func currentFactorValue() -> Double { factor }
    func currentUserPercent() -> Double { userPercent }
    static func percent(forFactor factor: Double, cap: Double) -> Double {
        let denom = Swift.max(0.0001, (cap - 1.0))
        let pct = (factor - 1.0) / denom * 100.0
        return Swift.max(0.0, Swift.min(100.0, pct))
    }

    // MARK: - Overlay controls
    private let overlayFullsizeKey = "illumination.overlay.fullsize"
    private let overlayFPSKey = "illumination.overlay.fps"
    func overlayFullsizeEnabled() -> Bool {
        UserDefaults.standard.object(forKey: overlayFullsizeKey) as? Bool ?? true
    }
    func setOverlayFullsize(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: overlayFullsizeKey)
        technique.setOverlayConfig(fullsize: enabled, fps: overlayFPSValue())
    }
    func overlayFPSValue() -> Int {
        let v = UserDefaults.standard.object(forKey: overlayFPSKey) as? Int ?? 30
        return max(5, min(120, v))
    }
    func setOverlayFPS(_ fps: Int) {
        let clamped = max(5, min(120, fps))
        UserDefaults.standard.set(clamped, forKey: overlayFPSKey)
        technique.setOverlayConfig(fullsize: overlayFullsizeEnabled(), fps: clamped)
    }
    func edrNudge() {
        technique.nudgeEDR()
    }
    // MARK: - HDR-aware controls
    func hdrAwareIsEnabled() -> Bool { hdrAwareEnabled }
    func setHDRAwareEnabled(_ enabled: Bool) {
        hdrAwareEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: hdrAwareEnabledKey)
        if !enabled { hdrDuckLevel = 0.0; hdrActiveStreak = 0; hdrInactiveStreak = 0 }
    }
    func hdrAwareDuckPercentValue() -> Double { hdrAwareDuckPercent }
    func setHDRAwareDuckPercent(_ percent: Double) {
        let p = Swift.max(0.0, Swift.min(100.0, percent))
        hdrAwareDuckPercent = p
        UserDefaults.standard.set(p, forKey: hdrAwareDuckPercentKey)
    }
    func hdrAwareThresholdValue() -> Double { hdrAwareThreshold }
    func setHDRAwareThreshold(_ v: Double) {
        let val = Swift.max(1.1, Swift.min(3.0, v))
        hdrAwareThreshold = val
        UserDefaults.standard.set(val, forKey: hdrAwareThresholdKey)
    }
    // 0=Off,1=On(always),2=Auto(app+sampler),3=Apps(app-only)
    func hdrRegionSamplerModeValue() -> Int { max(0, min(3, hdrRegionSamplerMode)) }
    func setHDRRegionSamplerMode(_ mode: Int) {
        hdrRegionSamplerMode = max(0, min(3, mode))
        UserDefaults.standard.set(hdrRegionSamplerMode, forKey: hdrRegionSamplerModeKey)
    }
    func hdrAwareFadeDurationValue() -> Double { hdrDuckFadeDuration }
    func setHDRAwareFadeDuration(_ seconds: Double) {
        let v = Swift.max(0.05, Swift.min(2.0, seconds))
        hdrDuckFadeDuration = v
        UserDefaults.standard.set(v, forKey: hdrAwareFadeDurationKey)
    }

    private func isHDRContentLikely(bestRatioHint: Double) -> Bool {
        // Use region sampler based on mode; gate by app list in Auto/Apps.
        let mode = hdrRegionSamplerModeValue()
        // Start/stop sampler based on mode/app (Auto only)
        let mainDisplay = NSScreen.main?.displayId ?? 0
        let shouldSample: Bool = {
            if mode == 2 { return HDRAppList.isFrontmostHDRApp() }
            return false
        }()
        if shouldSample, mainDisplay != 0 {
            hdrSampler.start(displayID: mainDisplay)
        } else {
            hdrSampler.stop()
        }
        switch mode {
        case 0: // Off
            return false
        case 2: // Auto (app-gated + sampler evidence) [Debug/Experimental]
            return HDRAppList.isFrontmostHDRApp() && hdrSampler.hdrPresent
        case 3: // Apps (app-gated only)
            return HDRAppList.isFrontmostHDRApp()
        default:
            return false
        }
    }

    static func modeName(_ mode: Int) -> String {
        switch mode { case 2: return "Auto"; case 3: return "Apps"; default: return "Off" }
    }
    func setGuardEnabled(_ enabled: Bool) {
        guardEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: guardEnabledKey)
    }
    func setGuardFactor(_ factor: Double) {
        let clamped = Swift.max(0.70, Swift.min(0.98, factor))
        guardFactor = clamped
        UserDefaults.standard.set(clamped, forKey: guardFactorKey)
    }
}
