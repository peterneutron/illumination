import Foundation
import SwiftUI
import Combine
import AppKit

@MainActor
final class IlluminationViewModel: ObservableObject {
    @Published var enabled: Bool
    @Published var userPercent: Double
    @Published var debugUnlocked: Bool = false
    @Published var alsAutoEnabled: Bool = false
    @Published var alsAvailable: Bool = ALSManager.shared.available
    @Published var edrUnsupportedConfirmed: Bool = false

    private let controller = BrightnessController.shared
    private var timer: Timer?
    private var pollingActive = false

    init() {
        enabled = controller.appIsEnabled()
        userPercent = controller.currentUserPercent()
        alsAutoEnabled = ALSManager.shared.autoEnabled
        controller.setEnabled(enabled)
        // Initial capability probe with retry before gating
        performEDRCheckWithRetry()
    }

    deinit { timer?.invalidate() }

    // MARK: - Intents
    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "illumination.enabled")
        controller.setEnabled(on)
        enabled = on
    }

    func setEnabledFromUser(_ on: Bool) {
        ALSManager.shared.noteManualOverride()
        setEnabled(on)
    }

    func setPercent(_ p: Double) {
        let clamped = max(0.0, min(100.0, p))
        controller.setUserPercent(clamped)
        userPercent = clamped
    }

    // ALS Auto
    func setALSMode(_ on: Bool) {
        alsAutoEnabled = on
        ALSManager.shared.setAutoEnabled(on)
    }

    // ALS Profile
    var alsProfileName: String { ALSManager.shared.getProfile().displayName }
    func setALSProfileTwilight() { ALSManager.shared.setProfile(.twilight); objectWillChange.send() }
    func setALSProfileDaybreak() { ALSManager.shared.setProfile(.daybreak); objectWillChange.send() }
    func setALSProfileMidday() { ALSManager.shared.setProfile(.midday); objectWillChange.send() }
    func setALSProfileSunburst() { ALSManager.shared.setProfile(.sunburst); objectWillChange.send() }
    func setALSProfileHighNoon() { ALSManager.shared.setProfile(.highNoon); objectWillChange.send() }

    // MARK: - Polling control
    func startBackgroundPolling() {
        guard !pollingActive else { return }
        pollingActive = true
        timer?.invalidate(); timer = nil
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.enabled = self.controller.appIsEnabled()
                self.userPercent = self.controller.currentUserPercent()
                self.alsAvailable = ALSManager.shared.available
                self.alsAutoEnabled = ALSManager.shared.autoEnabled
                // Keep capability in sync when polling is active
                if self.controller.currentGammaCapDetails().sawEDR {
                    if self.edrUnsupportedConfirmed { self.edrUnsupportedConfirmed = false }
                }
            }
        }
        if let t = timer { RunLoop.main.add(t, forMode: .common) }
    }

    func stopBackgroundPolling() {
        pollingActive = false
        timer?.invalidate(); timer = nil
    }

    // MARK: - Derived status
    var statusText: String {
        if alsAutoEnabled { return "Automatic" }
        return enabled ? "Enabled" : "Disabled"
    }

    var alsProfileSymbolName: String {
        switch ALSManager.shared.getProfile() {
        case .twilight: return "airplane"
        case .daybreak: return "car.fill"
        case .midday: return "hare.fill"
        case .sunburst: return "figure.walk"
        case .highNoon: return "tortoise.fill"
        }
    }

    var debugDetails: [String] {
        let d = controller.currentGammaCapDetails()
        let currentFactor = controller.currentFactorValue()
        let targetPct = Int(round(userPercent))
        let effectivePct = Int(round(BrightnessController.percent(forFactor: currentFactor, cap: d.cap)))
        let luxLine: String = {
            if let lux = ALSManager.shared.currentLux { return "ALS: \(Int(round(lux))) lx @ \(String(format: "%.1f", ALSManager.shared.sampleHz)) Hz" }
            return "ALS: — lx"
        }()
        var lines: [String] = [
            luxLine,
            String(format: "Target %%: %d%%, Effective %%: %d%%", targetPct, effectivePct),
            String(format: "Current Factor: %.3f • Guard: %@ (%.0f%%)", currentFactor, controller.isGuardEnabled() ? "On" : "Off", controller.guardFactorValue() * 100.0),
            "Profile: \(alsProfileName)"
        ]
        if let x = ALSManager.shared.debugDecodedX,
           let dx = ALSManager.shared.debugDx,
           let lfit = ALSManager.shared.debugLfit,
           let lrel = ALSManager.shared.debugLrel,
           let w = ALSManager.shared.debugBlendW {
            lines.append(String(format: "ALS X: %.3f (Δx: %.3f)", x, dx))
            lines.append(String(format: "ALS Lfit: %.0f lx, Lrel: %.0f lx, w=%.2f", lfit, lrel, w))
            if let rmax = ALSManager.shared.debugRollingMaxDx { lines.append(String(format: "ALS Rolling Δx max: %.1f", rmax)) }
        }
        let cp = ALSManager.shared.calibratorParams()
        lines.append(String(format: "Calibrator: a=%.5f, p=%.5f, xDark=%.5f", cp.a, cp.p, cp.xDark))
        return lines
    }

    func reprobeDisplays() {
        _ = DisplayStateProbe.shared.probe()
        objectWillChange.send()
    }

    // MARK: - Debug Tuners (ALS)
    var entryMinPercent: Int { Int(round(ALSManager.shared.entryMinPercentValue())) }
    func setEntryMinPercent(_ p: Int) { ALSManager.shared.setEntryMinPercent(Double(p)); objectWillChange.send() }
    var entryEnvelopeSeconds: Double { ALSManager.shared.entryEnvelopeSecondsValue() }
    func setEntryEnvelopeSeconds(_ s: Double) { ALSManager.shared.setEntryEnvelopeSeconds(s); objectWillChange.send() }
    var maxPercentPerSecond: Int { Int(round(ALSManager.shared.maxPercentPerSecondValue())) }
    func setMaxPercentPerSecond(_ v: Int) { ALSManager.shared.setMaxPercentPerSecond(Double(v)); objectWillChange.send() }
    var minOnSeconds: Double { ALSManager.shared.minOnSecondsValue() }
    func setMinOnSeconds(_ s: Double) { ALSManager.shared.setMinOnSeconds(s); objectWillChange.send() }
    var minOffSeconds: Double { ALSManager.shared.minOffSecondsValue() }
    func setMinOffSeconds(_ s: Double) { ALSManager.shared.setMinOffSeconds(s); objectWillChange.send() }
    // Removed tuners: sunDxTrigger, relative blend, clamp/knee, hill

    // MARK: - Calibration Helper
    var calibA: ALSManager.CalibAnchor? { ALSManager.shared.calibAnchorA() }
    var calibB: ALSManager.CalibAnchor? { ALSManager.shared.calibAnchorB() }
    func calibSetDarkFromCurrent() { ALSManager.shared.setDarkFromCurrent(); objectWillChange.send() }
    func calibSetAnchorA(_ lux: Double) { ALSManager.shared.setAnchorAFromCurrent(lux: lux); objectWillChange.send() }
    func calibSetAnchorB(_ lux: Double) { ALSManager.shared.setAnchorBFromCurrent(lux: lux); objectWillChange.send() }
    func calibFitAndSave() { ALSManager.shared.fitCalibrationFromAnchors(); objectWillChange.send() }
    func calibClearAnchors() { ALSManager.shared.clearAnchors(); objectWillChange.send() }
    func calibResetDefaults() { ALSManager.shared.resetCalibration(); objectWillChange.send() }

    // Removed Hill calibration hooks

    // MARK: - Utilities
    func copyDiagnosticsToPasteboard() {
        let s = debugDetails.joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    // MARK: - Lux label steps
    var luxStepMode: Int { Settings.luxStepMode }
    func setLuxStepMode(_ mode: Int) { Settings.luxStepMode = max(0, min(3, mode)); objectWillChange.send() }

    // Removed algorithm selection and SunMax presets

    // MARK: - Advanced Options wrappers
    var supportsEDR: Bool { controller.currentGammaCapDetails().sawEDR }
    var guardEnabled: Bool { controller.isGuardEnabled() }
    var guardFactor: Double { controller.guardFactorValue() }
    func setGuardEnabled(_ on: Bool) { controller.setGuardEnabled(on); objectWillChange.send() }
    func setGuardFactor(_ factor: Double) { controller.setGuardFactor(factor); objectWillChange.send() }

    var overlayFullsize: Bool { controller.overlayFullsizeEnabled() }
    func setOverlayFullsize(_ on: Bool) { controller.setOverlayFullsize(on); objectWillChange.send() }
    var overlayFPS: Int { controller.overlayFPSValue() }
    func setOverlayFPS(_ fps: Int) { controller.setOverlayFPS(fps); objectWillChange.send() }
    func edrNudge() { controller.edrNudge() }

    var hdrMode: Int { controller.hdrRegionSamplerModeValue() } // 0 Off, 2 Auto (Debug), 3 Apps
    func setHDRMode(_ mode: Int) { controller.setHDRRegionSamplerMode(mode); objectWillChange.send() }
    var hdrDuckPercent: Int { Int(round(controller.hdrAwareDuckPercentValue())) }
    func setHDRDuckPercent(_ p: Int) { controller.setHDRAwareDuckPercent(Double(p)); objectWillChange.send() }
    var hdrThreshold: Double { controller.hdrAwareThresholdValue() }
    func setHDRThreshold(_ v: Double) { controller.setHDRAwareThreshold(v); objectWillChange.send() }
    var hdrFadeMs: Int { Int(round(controller.hdrAwareFadeDurationValue() * 1000.0)) }
    func setHDRFadeMs(_ ms: Int) { controller.setHDRAwareFadeDuration(Double(ms) / 1000.0); objectWillChange.send() }

    var tileAvailable: Bool { TileFeature.shared.assetAvailable }
    var tileEnabled: Bool { TileFeature.shared.enabled }
    func setTileEnabled(_ on: Bool) { TileFeature.shared.enabled = on; objectWillChange.send() }
    var tileFullOpacity: Bool { TileFeature.shared.fullOpacity }
    func setTileFullOpacity(_ on: Bool) { TileFeature.shared.fullOpacity = on; objectWillChange.send() }
    var tileSize: Int { TileFeature.shared.size }
    func setTileSize(_ px: Int) { TileFeature.shared.size = px; objectWillChange.send() }
}

// MARK: - EDR capability with retry
extension IlluminationViewModel {
    private func performEDRCheckWithRetry() {
        let saw = controller.currentGammaCapDetails().sawEDR
        if saw {
            edrUnsupportedConfirmed = false
            return
        }
        // Retry once after a short delay to avoid transient 1.0 reads
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self = self else { return }
            let saw2 = self.controller.currentGammaCapDetails().sawEDR
            self.edrUnsupportedConfirmed = !saw2
        }
    }
}

// MARK: - Debug helpers
extension IlluminationViewModel {
    var debugScreenLines: [String] {
        return NSScreen.screens.enumerated().map { (i, s) in
            let did = s.displayId ?? 0
            let builtIn = (did != 0) ? (CGDisplayIsBuiltin(did) != 0) : false
            let isMain = (s == NSScreen.main)
            let cur = s.maximumExtendedDynamicRangeColorComponentValue
            let ref = s.maximumReferenceExtendedDynamicRangeColorComponentValue
            let potStr: String = {
                if #available(macOS 14.0, *) {
                    return String(format: "%.3f", s.maximumPotentialExtendedDynamicRangeColorComponentValue)
                } else {
                    return "n/a"
                }
            }()
            return String(
                format: "#%d id=%u builtin=%@ main=%@ cur=%.3f pot=%@ ref=%.3f",
                i,
                did,
                builtIn ? "true" : "false",
                isMain ? "true" : "false",
                cur,
                potStr,
                ref
            )
        }
    }
}
