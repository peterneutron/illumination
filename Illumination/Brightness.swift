//
//  Brightness.swift
//  Illumination
//
//  Minimal port of BrightIntosh core brightness logic.
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
    private var factor: Double = Double(getDeviceMaxBrightness())
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
    // AB (Auto-Brightness) mode heuristics
    private let abEnterThreshold: Double = 0.02
    private let abExitThreshold: Double = 0.05
    private let abStreakRequired: Int = 2
    private let abGuardFactor: Double = 0.95
    private let staticSafetyMargin: Double = 0.98
    private var abOffStreak: Int = 0
    private var abOnStreak: Int = 0
    private var abStaticMode: Bool = false

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
        self.enabled = enabled
        if enabled {
            technique.enable()
            technique.adjust(factor: Float(factor))
            technique.setOverlayConfig(fullsize: overlayFullsizeEnabled(), fps: overlayFPSValue())
        } else {
            technique.disable()
        }
    }

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
    }

    @objc private func screensDidWake(_ note: Notification) {
        if enabled {
            let cap = currentGammaCap()
            let target = 1.0 + (cap - 1.0) * (userPercent / 100.0)
            factor = Swift.min(target, cap)
            technique.adjust(factor: Float(factor))
        }
    }

    // MARK: - Cap computation

    func currentGammaCap() -> Double {
        // Inspect target displays for EDR capabilities, derive cap from ratio of max/reference EDR.
        return currentGammaCapDetails().cap
    }

    func currentGammaCapDetails() -> (cap: Double, rawCap: Double, bestRatio: Double, adaptiveMargin: Double, refGain: Double, refAlpha: Double, sawEDR: Bool, abStaticMode: Bool, guardFactor: Double) {
        // Inspect target displays for EDR capabilities, derive cap from ratio of max/reference EDR.
        let screens = targetDisplays()
        var bestRatio: Double = 1.0
        var bestRef: Double = 1.0
        var bestMaxEDR: Double = 1.0
        var sawEDR = false
        for screen in screens {
            let maxEDR = Double(screen.maximumExtendedDynamicRangeColorComponentValue)
            let refEDR = Double(screen.maximumReferenceExtendedDynamicRangeColorComponentValue)
            if maxEDR > 1.0 {
                sawEDR = true
                let denom = Swift.max(refEDR, 1.0)
                let ratio = maxEDR / denom
                if maxEDR > bestMaxEDR {
                    bestMaxEDR = maxEDR
                    bestRatio = ratio
                    bestRef = denom
                }
            }
        }
        if sawEDR {
            let adaptiveMargin: Double = safetyMargin
            // Reference gain (legacy; kept for debug visibility)
            let refGain = Swift.max(0.0, Swift.min(1.0, (bestRef - 1.0) / Swift.max(0.0001, refSpan)))
            let rawCap = 1.0 + (bestMaxEDR - 1.0) * adaptiveMargin
            let guardApplied = guardEnabled ? guardFactor : 1.0
            // Apply ceiling first, then guard, so guard can reduce below the ceiling
            let preClamped = Swift.min(rawCap, 1.70)
            let effectiveCap = preClamped * guardApplied
            let capped = Swift.max(1.0, effectiveCap)
            // Map abStaticMode to guardEnabled for compatibility with Debug UI
            return (capped, rawCap, bestRatio, adaptiveMargin, refGain, refAlpha, true, guardEnabled, guardApplied)
        }
        // Fallback to model-based cap if EDR not reported/available
        let fallback = Double(getDeviceMaxBrightness())
        let guardApplied = guardEnabled ? guardFactor : 1.0
        let effective = fallback * guardApplied
        return (effective, fallback, 1.0, safetyMargin, 0.0, refAlpha, false, guardEnabled, guardApplied)
    }

    // MARK: - Poller
    private func startCapPoller() {
        stopCapPoller()
        capPoller = Timer(fire: Date.now, interval: 1.0, repeats: true, block: { [weak self] _ in
            guard let self = self else { return }
            let cap = self.currentGammaCap()
            if self.enabled {
                let target = 1.0 + (cap - 1.0) * (self.userPercent / 100.0)
                let newFactor = Swift.max(1.0, Swift.min(cap, target))
                if abs(newFactor - self.factor) > 0.0001 {
                    self.factor = newFactor
                    self.technique.adjust(factor: Float(self.factor))
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
