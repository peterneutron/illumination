import Foundation
import SwiftUI
import Combine
import AppKit

enum MasterControlState: Equatable {
    case off
    case manual
    case auto
}

@MainActor
final class IlluminationViewModel: ObservableObject {
    @Published var enabled: Bool
    @Published var userPercent: Double
    @Published private(set) var effectivePercent: Double
    @Published private(set) var tileVisibleNow: Bool
    @Published private(set) var runtimeMode: RuntimeControlMode
    @Published var debugUnlocked: Bool = false
    @Published var alsAutoEnabled: Bool = false
    @Published var alsAvailable: Bool = ALSManager.shared.available
    @Published var edrUnsupportedConfirmed: Bool = false
    @Published var appPickerQuery: String = ""
    @Published private(set) var installedApps: [InstalledHDRApp] = []
    @Published private(set) var appPickerLoading: Bool = false
    @Published private(set) var alsTraceReplaySummary: String = "ALS replay: no trace events"
    @Published private(set) var launchAtLoginError: String = ""

    private let controller = BrightnessController.shared
    private var timer: Timer?
    private var autoModeBeforeMasterOff: Bool = false

    private func applyRuntimeState(_ state: RuntimeUIState) {
        enabled = state.masterEnabled
        userPercent = state.manualPercent
        effectivePercent = state.effectivePercent
        tileVisibleNow = state.tileVisibleNow
        runtimeMode = state.mode
        alsAutoEnabled = state.mode == .auto
    }

    private func syncFromController() {
        let snapshot = controller.uiStateSnapshot()
        let nextALSAvailable = ALSManager.shared.available
        applyRuntimeState(snapshot)
        if alsAvailable != nextALSAvailable {
            alsAvailable = nextALSAvailable
        }
        if controller.currentGammaCapDetails().sawEDR && edrUnsupportedConfirmed {
            edrUnsupportedConfirmed = false
        }
    }

    // Calibrator editing (Debug)
    @Published var calibAString: String = ""
    @Published var calibPString: String = ""

    init() {
        let snapshot = controller.uiStateSnapshot()
        enabled = snapshot.masterEnabled
        userPercent = snapshot.manualPercent
        effectivePercent = snapshot.effectivePercent
        tileVisibleNow = snapshot.tileVisibleNow
        runtimeMode = snapshot.mode
        alsAutoEnabled = snapshot.mode == .auto
        controller.setEnabled(enabled)
        startBackgroundPolling()
        // Initial capability probe with retry before gating
        performEDRCheckWithRetry()
    }

    deinit { timer?.invalidate() }

    // MARK: - Intents
    func setEnabled(_ on: Bool) {
        Settings.masterEnabled = on
        controller.setEnabled(on)
        syncFromController()
    }

    func setEnabledFromUser(_ on: Bool) {
        ALSManager.shared.noteManualOverride()
        if !on {
            autoModeBeforeMasterOff = alsAutoEnabled
        }
        setEnabled(on)
        if on, autoModeBeforeMasterOff {
            setALSMode(true, ensureMasterOn: false)
        }
    }

    func setPercent(_ p: Double) {
        let clamped = max(0.0, min(100.0, p))
        controller.setUserPercent(clamped)
        syncFromController()
    }

    // ALS Auto
    func setALSMode(_ on: Bool) {
        setALSMode(on, ensureMasterOn: true)
    }

    private func setALSMode(_ on: Bool, ensureMasterOn: Bool) {
        if on && ensureMasterOn && !controller.appIsEnabled() {
            setEnabled(true)
        }
        alsAutoEnabled = on
        ALSManager.shared.setAutoEnabled(on)
        controller.reapplyTileRuntimePolicy()
        syncFromController()
    }

    var modeIsAuto: Bool { alsAutoEnabled }
    func setModeIsAuto(_ on: Bool) { setALSMode(on) }
    var masterControlState: MasterControlState {
        IlluminationViewModel.resolveMasterControlState(masterEnabled: enabled, autoEnabled: alsAutoEnabled)
    }
    func setMasterControlState(_ state: MasterControlState) {
        switch state {
        case .off:
            setALSMode(false, ensureMasterOn: false)
            setEnabledFromUser(false)
        case .manual:
            setALSMode(false, ensureMasterOn: false)
            setEnabledFromUser(true)
        case .auto:
            setALSMode(true)
        }
    }

    var appScope: Int { controller.appPolicyScopeValue() }
    func setAppScope(_ scope: Int) {
        controller.setAppPolicyScope(scope)
        syncFromController()
    }
    var appPolicyScopeName: String {
        switch controller.uiStateSnapshot().scope {
        case 0: return String(localized: "Everywhere")
        default: return String(localized: "Apps")
        }
    }
    var appPolicyBlocked: Bool { controller.uiStateSnapshot().denylistBlocked }
    var appPolicyBlockedLabel: String {
        let state = controller.uiStateSnapshot()
        return state.denylistBlocked ? (state.blockedAppName ?? "") : ""
    }
    var sliderDisplayPercent: Double {
        IlluminationViewModel.sliderDisplayPercent(
            autoEnabled: alsAutoEnabled,
            masterEnabled: enabled,
            effectivePercent: effectivePercent,
            manualPercent: userPercent
        )
    }
    var runtimeTileEnabled: Bool { controller.uiStateSnapshot().tileEnabled }

    // ALS Profile
    var alsProfileName: String { ALSManager.shared.getProfile().displayName }
    func setALSProfileTwilight() { ALSManager.shared.setProfile(.twilight); objectWillChange.send() }
    func setALSProfileDaybreak() { ALSManager.shared.setProfile(.daybreak); objectWillChange.send() }
    func setALSProfileMidday() { ALSManager.shared.setProfile(.midday); objectWillChange.send() }
    func setALSProfileSunburst() { ALSManager.shared.setProfile(.sunburst); objectWillChange.send() }
    func setALSProfileHighNoon() { ALSManager.shared.setProfile(.highNoon); objectWillChange.send() }
    var alsHardwareProfileID: ALSHardwareProfileID { ALSManager.shared.getHardwareProfileID() }
    var alsHardwareProfileName: String { alsHardwareProfileID.displayName }
    func setALSHardwareProfile(_ id: ALSHardwareProfileID) { ALSManager.shared.setHardwareProfileID(id); objectWillChange.send() }
    var edrPolicyProfileID: EDRPolicyProfileID { controller.edrPolicyProfileIDValue() }
    var edrPolicyProfileName: String { edrPolicyProfileID.displayName }
    func setEDRPolicyProfile(_ id: EDRPolicyProfileID) { controller.setEDRPolicyProfileID(id); objectWillChange.send() }

    // MARK: - Polling control
    func startBackgroundPolling() {
        guard timer == nil else { return }
        syncFromController()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncFromController()
            }
        }
        timer?.tolerance = 0.2
        if let t = timer { RunLoop.main.add(t, forMode: .common) }
    }

    func stopBackgroundPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refreshNow() {
        syncFromController()
    }

    // MARK: - Derived status
    var statusText: String {
        let state = controller.uiStateSnapshot()
        if state.denylistBlocked {
            let label = state.blockedAppName ?? String(localized: "app")
            return String(format: String(localized: "Blocked by app: %@"), label)
        }
        if state.mode == .auto { return String(localized: "Automatic") }
        return state.masterEnabled ? String(localized: "Enabled") : String(localized: "Disabled")
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
        lines.append("ALS HW Profile: \(alsHardwareProfileName)")
        lines.append("EDR Policy Profile: \(edrPolicyProfileName)")
        let policy = controller.appPolicyDiagnostics()
        lines.append("App Policy Frontmost: \(policy.frontmostBundleID)")
        lines.append("App Policy Denylisted: \(policy.denylisted ? "yes" : "no")")
        lines.append("App Policy Scope: \(policy.scope)")
        lines.append("App Policy Result: \(policy.result)")
        lines.append("App Policy Restore Pending: \(policy.restorePending ? "yes" : "no")")
        lines.append("ALS Trace Capture: \(ALSManager.shared.traceCaptureEnabled() ? "on" : "off")")
        lines.append("ALS Trace Events: \(ALSManager.shared.traceEventCount())")
        lines.append(alsTraceReplaySummary)

        let detection = controller.hdrDetectionDiagnostics()
        lines.append("Experimental HDR Enabled: \(detection.experimentalEnabled ? "yes" : "no")")
        lines.append("Experimental HDR Frontmost: \(detection.frontmostBundleID)")
        lines.append("Experimental HDR Match: \(detection.matched ? "matched" : "unmatched")")
        lines.append("Experimental HDR Gate: \(detection.gate)")
        lines.append("Experimental HDR Sampler: \(detection.samplerStatus)")
        if let issue = RuntimeDiagnostics.shared.lastIssue {
            lines.append("Runtime: \(issue)")
        }
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

    // New: manual a/p editing
    func calibRefreshFields() {
        let cp = ALSManager.shared.calibratorParams()
        calibAString = String(format: "%.8f", cp.a)
        calibPString = String(format: "%.8f", cp.p)
    }
    func calibApplyFields() {
        guard let a = Double(calibAString.trimmingCharacters(in: .whitespaces)), a > 0, a.isFinite else { return }
        guard let p = Double(calibPString.trimmingCharacters(in: .whitespaces)), p > 0, p.isFinite else { return }
        ALSManager.shared.setCalibrator(a: a, p: p)
        objectWillChange.send()
    }
    func copyCalibratorJSON() {
        if let s = ALSManager.shared.calibratorJSON() {
            let pb = NSPasteboard.general
            pb.clearContents(); pb.setString(s, forType: .string)
        }
    }

    // Removed Hill calibration hooks

    // MARK: - Utilities
    func copyDiagnosticsToPasteboard() {
        let s = debugDetails.joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    func copyALSTraceJSONL() {
        let trace = ALSManager.shared.exportTraceJSONL()
        guard !trace.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(trace, forType: .string)
        alsTraceReplaySummary = "ALS replay: export copied (\(ALSManager.shared.traceEventCount()) events)"
        objectWillChange.send()
    }

    func clearALSTrace() {
        ALSManager.shared.clearTrace()
        alsTraceReplaySummary = "ALS replay: no trace events"
        objectWillChange.send()
    }

    var alsTraceCaptureEnabled: Bool { ALSManager.shared.traceCaptureEnabled() }
    func setALSTraceCaptureEnabled(_ enabled: Bool) {
        ALSManager.shared.setTraceCaptureEnabled(enabled)
        objectWillChange.send()
    }

    func replayLastALSTraceExport() {
        alsTraceReplaySummary = ALSManager.shared.replayLastTraceSummary()
        objectWillChange.send()
    }

    // MARK: - Lux label steps
    var luxStepMode: Int { Settings.luxStepMode }
    func setLuxStepMode(_ mode: Int) { Settings.luxStepMode = max(0, min(3, mode)); objectWillChange.send() }

    // Removed algorithm selection and SunMax presets

    // MARK: - Advanced Options wrappers
    var supportsEDR: Bool { controller.currentGammaCapDetails().sawEDR }
    var runAtLoginEnabled: Bool { LaunchAtLoginManager.shared.isEnabled }
    var runAtLoginStatusLabel: String { LaunchAtLoginManager.shared.statusLabel }
    func setRunAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginManager.shared.setEnabled(enabled)
            launchAtLoginError = ""
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        objectWillChange.send()
    }
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
    var hdrExperimentalEnabled: Bool { controller.hdrAwareIsEnabled() }
    func setHDRExperimentalEnabled(_ enabled: Bool) { controller.setHDRAwareEnabled(enabled); objectWillChange.send() }
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

    var blockedApps: [HDRAppEntry] { HDRAppList.allDenylistedEntries() }

    var canAddFrontmostBlockedApp: Bool {
        HDRAppList.frontmostAppInfo().bundleID != nil
    }

    var addFrontmostDisabledReason: String {
        if canAddFrontmostBlockedApp { return "" }
        return String(localized: "Frontmost app has no bundle identifier.")
    }

    var frontmostAppDisplayLabel: String {
        let info = HDRAppList.frontmostAppInfo()
        if let name = info.displayName, !name.isEmpty { return name }
        if let bundleID = info.bundleID, !bundleID.isEmpty { return bundleID }
        return String(localized: "Unavailable")
    }

    func addFrontmostBlockedApp() {
        let info = HDRAppList.frontmostAppInfo()
        guard let bundleID = info.bundleID else { return }
        HDRAppList.addDenylistedApp(bundleID: bundleID, displayName: info.displayName)
        objectWillChange.send()
    }

    func setBlockedAppEnabled(bundleID: String, enabled: Bool) {
        HDRAppList.setDenylistedEnabled(bundleID: bundleID, isEnabled: enabled)
        objectWillChange.send()
    }

    func removeBlockedApp(bundleID: String) {
        HDRAppList.removeDenylistedApp(bundleID: bundleID)
        objectWillChange.send()
    }

    func resetBlockedAppDefaults() {
        HDRAppList.resetDenylistDefaults(keepUserAdded: true)
        objectWillChange.send()
    }

    func addBlockedApp(bundleID: String, displayName: String?) {
        HDRAppList.addDenylistedApp(bundleID: bundleID, displayName: displayName)
        objectWillChange.send()
    }

    func loadInstalledApps() {
        guard !appPickerLoading else { return }
        appPickerLoading = true
        Task.detached(priority: .userInitiated) {
            let apps = InstalledAppDiscovery.discoverInstalledApps()
            await MainActor.run {
                self.installedApps = apps
                self.appPickerLoading = false
            }
        }
    }

    var filteredInstalledApps: [InstalledHDRApp] {
        let query = appPickerQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty { return installedApps }
        return installedApps.filter { app in
            app.displayName.lowercased().contains(query) || app.bundleID.lowercased().contains(query)
        }
    }
}

extension IlluminationViewModel {
    nonisolated static func resolveMasterControlState(masterEnabled: Bool, autoEnabled: Bool) -> MasterControlState {
        if autoEnabled { return .auto }
        return masterEnabled ? .manual : .off
    }

    nonisolated static func sliderDisplayPercent(
        autoEnabled: Bool,
        masterEnabled: Bool,
        effectivePercent: Double,
        manualPercent: Double
    ) -> Double {
        guard masterEnabled else { return 0.0 }
        let raw = autoEnabled ? effectivePercent : manualPercent
        return min(100.0, max(0.0, raw))
    }
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
