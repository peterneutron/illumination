//
//  MenuBarUI.swift
//  Illumination
//

import SwiftUI
import AppKit
import Combine

// ViewModel bridging BrightnessController to SwiftUI
final class IlluminationViewModel: ObservableObject {
    @Published var enabled: Bool
    @Published var userPercent: Double
    @Published var debugUnlocked: Bool = false
    @Published var alsAutoEnabled: Bool = false
    @Published var alsAvailable: Bool = ALSManager.shared.available
    // Note: Avoid binding lux directly to SwiftUI while menu is open to prevent menu rebuilds.
    // Live lux is shown via an NSViewRepresentable that updates without triggering SwiftUI diffs.

    private let controller = BrightnessController.shared
    private var timer: Timer?
    private var pollingActive = false

    init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: "illumination.enabled") as? Bool ?? false
        userPercent = controller.currentUserPercent()
        // Kick controller to apply stored state as needed
        controller.setEnabled(enabled)
        // Background polling is started externally to avoid redrawing while menu is open
    }

    deinit { timer?.invalidate() }

    // MARK: - Intents
    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "illumination.enabled")
        controller.setEnabled(on)
        enabled = on
    }

    // Manual toggle from UI (sets ALS grace)
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

    // MARK: - Polling control
    func startBackgroundPolling() {
        guard !pollingActive else { return }
        pollingActive = true
        timer?.invalidate(); timer = nil
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.enabled = UserDefaults.standard.bool(forKey: "illumination.enabled")
                self.userPercent = self.controller.currentUserPercent()
                self.alsAvailable = ALSManager.shared.available
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

    var debugDetails: [String] {
        let d = controller.currentGammaCapDetails()
        let model = getModelIdentifier() ?? "—"
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
    // Guard
    var guardEnabled: Bool { controller.isGuardEnabled() }
    func setGuardEnabled(_ on: Bool) { controller.setGuardEnabled(on); objectWillChange.send() }
    func setGuardFactor(_ factor: Double) { controller.setGuardFactor(factor); objectWillChange.send() }

    // Overlay
    var overlayFullsize: Bool { controller.overlayFullsizeEnabled() }
    func setOverlayFullsize(_ on: Bool) { controller.setOverlayFullsize(on); objectWillChange.send() }
    var overlayFPS: Int { controller.overlayFPSValue() }
    func setOverlayFPS(_ fps: Int) { controller.setOverlayFPS(fps); objectWillChange.send() }
    func edrNudge() { controller.edrNudge() }

    // HDR
    var hdrMode: Int { controller.hdrRegionSamplerModeValue() } // 0 Off, 1 On, 2 Auto, 3 Apps
    func setHDRMode(_ mode: Int) { controller.setHDRRegionSamplerMode(mode); objectWillChange.send() }
    var hdrDuckPercent: Int { Int(round(controller.hdrAwareDuckPercentValue())) }
    func setHDRDuckPercent(_ p: Int) { controller.setHDRAwareDuckPercent(Double(p)); objectWillChange.send() }
    var hdrThreshold: Double { controller.hdrAwareThresholdValue() }
    func setHDRThreshold(_ v: Double) { controller.setHDRAwareThreshold(v); objectWillChange.send() }
    var hdrFadeMs: Int { Int(round(controller.hdrAwareFadeDurationValue() * 1000.0)) }
    func setHDRFadeMs(_ ms: Int) { controller.setHDRAwareFadeDuration(Double(ms) / 1000.0); objectWillChange.send() }

    // Tile
    var tileAvailable: Bool { TileFeature.shared.assetAvailable }
    var tileEnabled: Bool { TileFeature.shared.enabled }
    func setTileEnabled(_ on: Bool) { TileFeature.shared.enabled = on; objectWillChange.send() }
    var tileFullOpacity: Bool { TileFeature.shared.fullOpacity }
    func setTileFullOpacity(_ on: Bool) { TileFeature.shared.fullOpacity = on; objectWillChange.send() }
    var tileSize: Int { TileFeature.shared.size }
    func setTileSize(_ px: Int) { TileFeature.shared.size = px; objectWillChange.send() }
}

// MARK: - Views

struct IlluminationMenuBarLabel: View {
    @ObservedObject var vm: IlluminationViewModel
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: vm.enabled ? "sun.max.fill" : "sun.min")
        }
        .task { vm.startBackgroundPolling() }
    }
}

struct IlluminationMenuView: View {
    @ObservedObject var vm: IlluminationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 0) {
                Text("Illumination") // or keep your 'Illuminati' + 'o' + 'n' trick
                    .font(.title).bold()
            }

            // Status line
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(vm.statusText)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                // Right-aligned status symbols (won’t compress)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.fill")
                        Text(tileModeDisplay(vm: vm))
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles.tv.fill")
                        Text(hdrModeDisplay(vm: vm))
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "lightspectrum.horizontal")
                        LiveLuxLabel()
                    }
                }
                .font(.caption)
                .fixedSize(horizontal: true, vertical: false) // keep icons from squeezing
            }

            Divider().padding(.vertical, 2)

            VStack(alignment: .leading) {
                HStack {
                    Text("Brightness")
                    Spacer()
                    LivePercentLabel()
                        .frame(minWidth: 32, alignment: .trailing)
                }
                PercentSlider(
                    value: Binding(
                    get: { vm.userPercent },
                    set: { vm.setPercent($0) }
                    ),
                    autoEnabled: vm.alsAutoEnabled
                )
                .disabled(!vm.enabled || vm.alsAutoEnabled)
            .opacity((!vm.enabled || vm.alsAutoEnabled) ? 0.5 : 1.0)
            }
            .opacity(vm.enabled && !vm.alsAutoEnabled ? 1.0 : 0.5)

            // Divider below slider
            Divider()

            // Quick actions (centered and evenly spaced)
            QuickActionsBar(vm: vm)

            // Divider above Advanced
            Divider()

            // Footer with Advanced Options dropdown and Quit on the right
            HStack {
                Menu("Advanced Options") {
                    Group {
                    // Guard
                    Text("Guard").font(.caption).foregroundStyle(.secondary)
                    Toggle("Guard Mode", isOn: Binding(get: { vm.guardEnabled }, set: { vm.setGuardEnabled($0) }))
                    Menu("Guard Factor") {
                        ForEach([0.75, 0.85, 0.90, 0.95], id: \.self) { f in
                            Button(String(format: "%.0f%%", f * 100.0)) { vm.setGuardFactor(f) }
                        }
                    }

                    Divider()

                    // Overlay
                    Text("Overlay").font(.caption).foregroundStyle(.secondary)
                    Toggle("Fullsize", isOn: Binding(get: { vm.overlayFullsize }, set: { vm.setOverlayFullsize($0) }))
                    Menu("FPS: \(vm.overlayFPS)") {
                        ForEach([5, 15, 30, 60], id: \.self) { fps in
                            Button("\(fps) fps") { vm.setOverlayFPS(fps) }
                        }
                    }
                    Button("EDR Nudge") { vm.edrNudge() }

                    Divider()

                    // HDR
                    Text("HDR").font(.caption).foregroundStyle(.secondary)
                    Menu("Detection: \(modeName(vm.hdrMode))") {
                        ForEach([(0,"Off"),(1,"On"),(2,"Auto"),(3,"Apps")], id: \.0) { m in
                            Button(m.1) { vm.setHDRMode(m.0) }
                        }
                    }
                    Menu("Duck Target: \(vm.hdrDuckPercent)%") {
                        ForEach([30, 40, 50], id: \.self) { p in
                            Button("\(p)%") { vm.setHDRDuckPercent(p) }
                        }
                    }
                    Menu(String(format: "Threshold: %.2f", vm.hdrThreshold)) {
                        ForEach([1.4, 1.5, 1.8, 2.0], id: \.self) { t in
                            Button(String(format: "%.2f", t)) { vm.setHDRThreshold(t) }
                        }
                    }
                    Menu("Fade: \(vm.hdrFadeMs) ms") {
                        ForEach([200, 300, 500], id: \.self) { ms in
                            Button("\(ms) ms") { vm.setHDRFadeMs(ms) }
                        }
                    }

                    Divider()

                    // HDR Tile
                    Text("HDR Tile").font(.caption).foregroundStyle(.secondary)
                    Toggle("Enable", isOn: Binding(get: { vm.tileEnabled }, set: { vm.setTileEnabled($0) }))
                        .disabled(!vm.tileAvailable)
                    if !vm.tileAvailable { Text("Asset not found").font(.caption).foregroundStyle(.secondary) }
                    Menu("Size: \(vm.tileSize) px") {
                        ForEach([64, 32, 16, 8, 4, 1], id: \.self) { s in
                            Button("\(s) px") { vm.setTileSize(s) }
                        }
                    }
                    Toggle("Full Opacity", isOn: Binding(get: { vm.tileFullOpacity }, set: { vm.setTileFullOpacity($0) }))

                    Divider()

                    // Debug (hidden unlock via title 'o')
                    if vm.debugUnlocked {
                        Menu("Debug") {
                            ForEach(vm.debugDetails, id: \.self) { line in
                                Text(line)
                            }
                        }
                    }
                    }
                    .disabled(!vm.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(12)
        .frame(width: 320)
        .onAppear { vm.stopBackgroundPolling() }
        .onDisappear { vm.startBackgroundPolling() }
    }

    private func modeName(_ mode: Int) -> String {
        switch mode { case 1: return "On"; case 2: return "Auto"; case 3: return "Apps"; default: return "Off" }
    }

    private func tileModeDisplay(vm: IlluminationViewModel) -> String {
        guard (vm.enabled || vm.alsAutoEnabled) else { return "Off" }
        return vm.tileEnabled ? (vm.tileFullOpacity ? "Full" : "Low") : "Off"
    }

    private func hdrModeDisplay(vm: IlluminationViewModel) -> String {
        guard (vm.enabled || vm.alsAutoEnabled) else { return "Off" }
        return modeName(vm.hdrMode)
    }

    // luxDisplay removed; using LiveLuxLabel instead
}

// MARK: - Quick Actions
private enum TileMode: Equatable { case off, low, full }

private struct QuickActionsBar: View {
    @ObservedObject var vm: IlluminationViewModel

    private var tileMode: Binding<TileMode> {
        Binding<TileMode>(
            get: {
                guard vm.tileEnabled else { return .off }
                return vm.tileFullOpacity ? .full : .low
            },
            set: { mode in
                switch mode {
                case .off:
                    vm.setTileEnabled(false)
                case .low:
                    vm.setTileEnabled(true)
                    vm.setTileFullOpacity(false)
                case .full:
                    vm.setTileEnabled(true)
                    vm.setTileFullOpacity(true)
                }
            }
        )
    }

    private var hdrMode: Binding<Int> {
        Binding<Int>(get: { vm.hdrMode }, set: { vm.setHDRMode($0) })
    }

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            // Master enable/disable (disabled while ALS Auto is on; visually off under ALS)
            MultiStateActionButton<Bool>(
                title: "Master",
                states: [
                    ActionState(value: false, imageName: "sun.min",      tint: .red,   help: "Disable Illumination"),
                    ActionState(value: true,  imageName: "sun.max.fill", tint: .green, help: "Enable Illumination")
                ],
                selection: Binding(
                    get: { vm.alsAutoEnabled ? false : vm.enabled },
                    set: { vm.setEnabledFromUser($0) }
                ),
                size: 48,
                enableHaptics: true,
                showsCaption: false,
                isActiveProvider: { $0 }
            )
            .disabled(vm.alsAutoEnabled)
            .opacity(vm.alsAutoEnabled ? 0.5 : 1.0)
            Spacer(minLength: 0)

            // Tile modes: Off / Low / Full
            MultiStateActionButton<TileMode>(
                title: "Tile",
                states: [
                    ActionState(value: .off,  imageName: "rectangle",       tint: .gray,   help: "Tile Off"),
                    ActionState(value: .low,  imageName: "rectangle.fill",  tint: .yellow, help: "Tile Low Opacity"),
                    ActionState(value: .full, imageName: "rectangle.fill",  tint: .green,  help: "Tile Full Opacity")
                ],
                selection: tileMode,
                size: 48,
                enableHaptics: true,
                showsCaption: false,
                isActiveProvider: { $0 != .off }
            )
            .disabled(!(vm.enabled || vm.alsAutoEnabled) || !vm.tileAvailable)
            .opacity((!(vm.enabled || vm.alsAutoEnabled) || !vm.tileAvailable) ? 0.5 : 1.0)
            .help(vm.tileAvailable ? "Toggle HDR Tile" : "HDR asset not found")
            Spacer(minLength: 0)

            // HDR Detection: Off / On / (Auto skipped) / Apps
            MultiStateActionButton<Int>(
                title: "Detection",
                states: [
                    ActionState(value: 0, imageName: "sparkles.tv",      tint: .gray,   help: "Detection Off"),
                    ActionState(value: 1, imageName: "sparkles.tv.fill", tint: .green,  help: "Detection On"),
                    ActionState(value: 2, imageName: "sparkles.tv.fill", tint: .yellow, help: "Detection Auto (skipped)"),
                    ActionState(value: 3, imageName: "sparkles.tv.fill", tint: .blue,   help: "Detection Apps")
                ],
                selection: hdrMode,
                size: 48,
                enableHaptics: true,
                showsCaption: false,
                isActiveProvider: { $0 != 0 },
                onChange: { _ in },
                shouldSkip: { $0 == 2 }
            )
            .disabled(!(vm.enabled || vm.alsAutoEnabled))
            .opacity((vm.enabled || vm.alsAutoEnabled) ? 1.0 : 0.5)
            Spacer(minLength: 0)

            // ALS Auto: Off / On
            MultiStateActionButton<Bool>(
                title: "ALS Auto",
                states: [
                    ActionState(value: false, imageName: "lightspectrum.horizontal", tint: .gray,  help: "ALS Auto Off"),
                    ActionState(value: true,  imageName: "lightspectrum.horizontal", tint: .green, help: "ALS Auto On")
                ],
                selection: Binding(get: { vm.alsAutoEnabled }, set: { vm.setALSMode($0) }),
                size: 48,
                enableHaptics: true,
                showsCaption: false,
                isActiveProvider: { $0 }
            )
            .disabled(!vm.alsAvailable)
            .opacity(vm.alsAvailable ? 1.0 : 0.5)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Live Labels (avoid SwiftUI body updates while menu is open)
private struct LiveLuxLabel: NSViewRepresentable {
    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField(labelWithString: "— lx")
        let base = NSFont.preferredFont(forTextStyle: .caption1)
        tf.font = NSFont.monospacedDigitSystemFont(ofSize: base.pointSize, weight: .regular)
        context.coordinator.start(label: tf)
        return tf
    }
    func updateNSView(_ nsView: NSTextField, context: Context) { }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var timer: Timer?
        func start(label: NSTextField) {
            timer?.invalidate(); timer = nil
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                let lux = ALSManager.shared.currentLux
                let text = lux.map { Self.formatLux($0) } ?? "— lx"
                label.stringValue = text
            }
            if let t = timer { RunLoop.main.add(t, forMode: .eventTracking) }
        }
        deinit { timer?.invalidate() }
        static func formatLux(_ value: Double) -> String {
            if value < 1000 {
                return "\(Int(round(value))) lx"
            } else {
                let k = value / 1000.0
                let halfStep = (k * 2.0).rounded() / 2.0 // 0.5 kLux steps
                return String(format: "%.1fk lx", halfStep)
            }
        }
    }
}

private struct LivePercentLabel: NSViewRepresentable {
    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField(labelWithString: "—%")
        tf.font = NSFont.preferredFont(forTextStyle: .body)
        tf.alignment = .right
        context.coordinator.start(label: tf)
        return tf
    }
    func updateNSView(_ nsView: NSTextField, context: Context) { }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var timer: Timer?
        func start(label: NSTextField) {
            timer?.invalidate(); timer = nil
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                let pct = Int(round(BrightnessController.shared.currentUserPercent()))
                label.stringValue = "\(pct)%"
            }
            if let t = timer { RunLoop.main.add(t, forMode: .eventTracking) }
        }
        deinit { timer?.invalidate() }
    }
}

// MARK: - AppKit-backed slider without tick marks
private struct PercentSlider: NSViewRepresentable {
    @Binding var value: Double
    var autoEnabled: Bool = false

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value, minValue: 0.0, maxValue: 100.0, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.isContinuous = true
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
        context.coordinator.start(slider: slider)
        return slider
    }

    func updateNSView(_ nsView: NSSlider, context: Context) {
        context.coordinator.isAutoEnabled = autoEnabled
        if abs(nsView.doubleValue - value) > 0.0001 {
            nsView.doubleValue = value
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    final class Coordinator: NSObject {
        var value: Binding<Double>
        var timer: Timer?
        var isAutoEnabled: Bool = false
        weak var sliderRef: NSSlider?

        init(value: Binding<Double>) { self.value = value }

        func start(slider: NSSlider) {
            sliderRef = slider
            timer?.invalidate(); timer = nil
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self = self, self.isAutoEnabled, let slider = self.sliderRef else { return }
                let pct = BrightnessController.shared.currentUserPercent()
                let rounded = round(pct)
                if abs(slider.doubleValue - rounded) > 0.0001 {
                    slider.doubleValue = rounded
                }
            }
            if let t = timer { RunLoop.main.add(t, forMode: .eventTracking) }
        }

        deinit { timer?.invalidate() }
        @objc func changed(_ sender: NSSlider) {
            let rounded = round(sender.doubleValue)
            if abs(rounded - value.wrappedValue) > 0.0001 {
                value.wrappedValue = min(100.0, max(0.0, rounded))
            }
        }
    }
}
