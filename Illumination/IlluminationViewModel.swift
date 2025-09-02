import Foundation
import SwiftUI
import Combine

@MainActor
final class IlluminationViewModel: ObservableObject {
    @Published var enabled: Bool
    @Published var userPercent: Double
    @Published var debugUnlocked: Bool = false
    @Published var alsAutoEnabled: Bool = false
    @Published var alsAvailable: Bool = ALSManager.shared.available

    private let controller = BrightnessController.shared
    private var timer: Timer?
    private var pollingActive = false

    init() {
        enabled = controller.appIsEnabled()
        userPercent = controller.currentUserPercent()
        alsAutoEnabled = ALSManager.shared.autoEnabled
        controller.setEnabled(enabled)
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
    func setALSProfileAggressive() { ALSManager.shared.setProfile(.aggressive); objectWillChange.send() }
    func setALSProfileNormal() { ALSManager.shared.setProfile(.normal); objectWillChange.send() }
    func setALSProfileConservative() { ALSManager.shared.setProfile(.conservative); objectWillChange.send() }

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
        case .aggressive: return "hare.fill"
        case .normal: return "figure.walk"
        case .conservative: return "tortoise.fill"
        }
    }

    var debugDetails: [String] {
        let d = controller.currentGammaCapDetails()
        let model = SystemInfo.getModelIdentifier() ?? "—"
        let overlayFull = controller.overlayFullsizeEnabled()
        let fps = controller.overlayFPSValue()
        let currentFactor = controller.currentFactorValue()
        let targetPct = Int(round(userPercent))
        let effectivePct = Int(round(BrightnessController.percent(forFactor: currentFactor, cap: d.cap)))
        let luxLine: String = {
            if let lux = ALSManager.shared.currentLux { return "ALS: \(Int(round(lux))) lx @ \(String(format: "%.1f", ALSManager.shared.sampleHz)) Hz" }
            return "ALS: — lx"
        }()
        return [
            "Model: \(model)",
            String(format: "Gamma Cap: %.3f", d.cap),
            String(format: "Raw Cap: %.3f (%@)", d.rawCap, (d.rawCap > d.cap + 0.0005) ? "clamped" : "not clamped"),
            String(format: "EDR Ratio: %.3f", d.bestRatio),
            String(format: "Safety Margin: %.2f", d.adaptiveMargin),
            String(format: "Ref Gain: %.3f (alpha: %.2f)", d.refGain, d.refAlpha),
            String(format: "Guard Mode: %@, Factor: %.0f%%", controller.isGuardEnabled() ? "On" : "Off", controller.guardFactorValue() * 100.0),
            "Overlay Fullsize: \(overlayFull ? "On" : "Off")",
            "Overlay FPS: \(fps)",
            String(format: "Current Factor: %.3f", currentFactor),
            "Target %: \(targetPct)%, Effective %: \(effectivePct)%",
            luxLine,
            "ALS Auto: \(alsAutoEnabled ? "On" : "Off")",
            "Enabled: \(enabled ? "Yes" : "No")"
        ]
    }

    // MARK: - Advanced Options wrappers
    var supportsEDR: Bool { controller.currentGammaCapDetails().sawEDR }
    var guardEnabled: Bool { controller.isGuardEnabled() }
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
