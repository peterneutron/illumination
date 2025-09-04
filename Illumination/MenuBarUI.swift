//
//  MenuBarUI.swift
//  Illumination
//

import SwiftUI
import AppKit
import Combine

// MARK: - Views

struct IlluminationMenuBarLabel: View {
    @ObservedObject var vm: IlluminationViewModel
    var body: some View {
        HStack(spacing: 4) {
            let symbol: String = {
                if vm.alsAutoEnabled { return "lightspectrum.horizontal" }
                return vm.enabled ? "sun.max.fill" : "sun.min"
            }()
            Image(systemName: symbol)
        }
        .task { vm.startBackgroundPolling() }
    }
}

struct IlluminationMenuView: View {
    @ObservedObject var vm: IlluminationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if vm.edrUnsupportedConfirmed {
                NotSupportedView()
            } else {
            // Header with hidden debug unlock on the 'o'
            HStack(spacing: 0) {
                Text("Illuminati")
                Button(action: { vm.debugUnlocked.toggle() }) { Text("o") }
                    .buttonStyle(.plain)
                Text("n")
            }
            .font(.title).bold()

            // Status line
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                HStack(spacing: 6) {
                    Text(vm.statusText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if vm.alsAutoEnabled {
                        Image(systemName: vm.alsProfileSymbolName)
                            .help("Automatic (\(ALSManager.shared.getProfile().displayName))")
                    }
                }
                .font(.caption)

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

            Divider()

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
                    // Brightness & Safety
                    Group {
                        Text("Brightness & Safety").font(.caption).foregroundStyle(.secondary)
                        Toggle("Guard Mode", isOn: Binding(get: { vm.guardEnabled }, set: { vm.setGuardEnabled($0) }))
                        Menu("Guard Factor: \(Int(round(vm.guardFactor * 100)))%") {
                            ForEach([0.75, 0.85, 0.90, 0.95], id: \.self) { f in
                                Button(action: { vm.setGuardFactor(f) }) {
                                    HStack {
                                        Text(String(format: "%.0f%%", f * 100.0))
                                        if abs(vm.guardFactor - f) < 0.0001 { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        }
                        Button("EDR Nudge") { vm.edrNudge() }
                    }
                    .disabled(!(vm.enabled || vm.alsAutoEnabled))

                    Divider()

                    // ALS Automatic
                    Group {
                        Text("ALS Automatic").font(.caption).foregroundStyle(.secondary)
                        Menu("Sensitivity: \(vm.alsProfileName)") {
                            Button(action: { vm.setALSProfileEarliest() }) { HStack { Text("Earliest"); if ALSManager.shared.getProfile() == .earliest { Image(systemName: "checkmark") } } }
                            Button(action: { vm.setALSProfileEarlier() }) { HStack { Text("Earlier"); if ALSManager.shared.getProfile() == .earlier { Image(systemName: "checkmark") } } }
                            Button(action: { vm.setALSProfileAggressive() }) { HStack { Text("Aggressive"); if ALSManager.shared.getProfile() == .aggressive { Image(systemName: "checkmark") } } }
                            Button(action: { vm.setALSProfileNormal() }) { HStack { Text("Normal"); if ALSManager.shared.getProfile() == .normal { Image(systemName: "checkmark") } } }
                            Button(action: { vm.setALSProfileConservative() }) { HStack { Text("Conservative"); if ALSManager.shared.getProfile() == .conservative { Image(systemName: "checkmark") } } }
                        }
                    }
                    .disabled(!vm.alsAvailable)

                    Divider()

                    // Debug (hidden unlock via title 'o')
                    if vm.debugUnlocked {
                        Menu("Debug") {
                            Menu("Live Diagnostics") { ForEach(vm.debugDetails, id: \.self) { line in Text(line) }; Divider(); Button("Copy Diagnostics") { vm.copyDiagnosticsToPasteboard() } }
                            Divider()
                        Menu("Display Probe") { ForEach(DisplayStateProbe.shared.debugLines(), id: \.self) { line in Text(line) }; Divider(); Button("Re-probe Displays") { vm.reprobeDisplays() } }
                        Divider()
                        // Overlay settings (moved from Advanced)
                        Menu("Overlay") {
                            Menu("FPS: \(vm.overlayFPS)") {
                                ForEach([5, 10, 15, 30, 60, 120], id: \.self) { f in
                                    Button(action: { vm.setOverlayFPS(f) }) { HStack { Text("\(f)"); if vm.overlayFPS == f { Image(systemName: "checkmark") } } }
                                }
                            }
                            Button("EDR Nudge") { vm.edrNudge() }
                        }
                        Divider()
                        // HDR settings (moved from Advanced)
                        Menu("HDR Settings") {
                            Menu("Detection: \(modeName(vm.hdrMode))") {
                                ForEach([(0,"Off"),(3,"Apps")], id: \.0) { m in
                                    Button(action: { vm.setHDRMode(m.0) }) { HStack { Text(m.1); if vm.hdrMode == m.0 { Image(systemName: "checkmark") } } }
                                }
                            }
                            Menu("Duck Target: \(vm.hdrDuckPercent)%") {
                                ForEach([30, 40, 50], id: \.self) { p in
                                    Button(action: { vm.setHDRDuckPercent(p) }) { HStack { Text("\(p)%"); if vm.hdrDuckPercent == p { Image(systemName: "checkmark") } } }
                                }
                            }
                            Menu(String(format: "Threshold: %.2f", vm.hdrThreshold)) {
                                ForEach([1.4, 1.5, 1.8, 2.0], id: \.self) { t in
                                    Button(action: { vm.setHDRThreshold(t) }) { HStack { Text(String(format: "%.2f", t)); if abs(vm.hdrThreshold - t) < 0.0001 { Image(systemName: "checkmark") } } }
                                }
                            }
                            Menu("Fade: \(vm.hdrFadeMs) ms") {
                                ForEach([200, 300, 500], id: \.self) { ms in
                                    Button(action: { vm.setHDRFadeMs(ms) }) { HStack { Text("\(ms) ms"); if vm.hdrFadeMs == ms { Image(systemName: "checkmark") } } }
                                }
                            }
                        }
                        Divider()
                        // HDR Tile (moved from Advanced)
                        Menu("HDR Tile") {
                            Toggle("Enable", isOn: Binding(get: { vm.tileEnabled }, set: { vm.setTileEnabled($0) }))
                                .disabled(!vm.tileAvailable)
                            if !vm.tileAvailable { Text("Asset not found").font(.caption).foregroundStyle(.secondary) }
                            Menu("Size: \(vm.tileSize) px") {
                                ForEach([64, 32, 16, 8, 4, 1], id: \.self) { s in
                                    Button(action: { vm.setTileSize(s) }) { HStack { Text("\(s) px"); if vm.tileSize == s { Image(systemName: "checkmark") } } }
                                }
                            }
                            Menu("Opacity: \(vm.tileFullOpacity ? "Full" : "Low")") {
                                Button(action: { vm.setTileFullOpacity(false) }) { HStack { Text("Low"); if !vm.tileFullOpacity { Image(systemName: "checkmark") } } }
                                Button(action: { vm.setTileFullOpacity(true) }) { HStack { Text("Full"); if vm.tileFullOpacity { Image(systemName: "checkmark") } } }
                            }
                        }
                            Divider()
                            Menu("ALS Tuning") {
                                Menu("Entry Min: \(vm.entryMinPercent)%") { ForEach([1,2,5,10], id: \.self) { p in Button("\(p)%") { vm.setEntryMinPercent(p) } } }
                                Menu(String(format: "Entry Envelope: %.1fs", vm.entryEnvelopeSeconds)) { ForEach([0.5, 1.0, 1.5, 2.0, 3.0], id: \.self) { s in Button(String(format: "%.1fs", s)) { vm.setEntryEnvelopeSeconds(s) } } }
                                Menu("Max Slope: \(vm.maxPercentPerSecond)%/s") { ForEach([20, 40, 50, 80, 100], id: \.self) { v in Button("\(v)%/s") { vm.setMaxPercentPerSecond(v) } } }
                                Menu(String(format: "Min On: %.1fs", vm.minOnSeconds)) { ForEach([0.0, 1.0, 1.5, 2.0, 3.0], id: \.self) { s in Button(String(format: "%.1fs", s)) { vm.setMinOnSeconds(s) } } }
                                Menu(String(format: "Min Off: %.1fs", vm.minOffSeconds)) { ForEach([0.0, 1.0, 1.5, 2.0, 3.0], id: \.self) { s in Button(String(format: "%.1fs", s)) { vm.setMinOffSeconds(s) } } }
                                Menu(String(format: "Sun Trigger: %.0f", vm.sunDxTrigger)) { ForEach([800.0, 1000.0, 1200.0, 1500.0, 1800.0], id: \.self) { v in Button(String(format: "%.0f", v)) { vm.setSunDxTrigger(v) } } }
                                Menu(String(format: "Rel Blend Max: %.2f", vm.relativeBlendMax)) { ForEach([0.00, 0.10, 0.20, 0.25, 0.30, 0.40, 0.50], id: \.self) { v in Button(String(format: "%.2f", v)) { vm.setRelativeBlendMax(v) } } }
                            }
                            Divider()
                            Menu("Calibration") {
                                Group { Text("Quick Fit").font(.caption).foregroundStyle(.secondary); Button("Set xDark from Current") { vm.calibSetDarkFromCurrent() } }
                                Divider()
                                Group { Text("Anchor A (indoors)").font(.caption).foregroundStyle(.secondary); ForEach([200.0, 500.0, 1000.0], id: \.self) { L in Button(String(format: "Set Current → %.0f lx", L)) { vm.calibSetAnchorA(L) } } }
                                Group { Text("Anchor B (bright)").font(.caption).foregroundStyle(.secondary); ForEach([5000.0, 20000.0, 50000.0], id: \.self) { L in Button(String(format: "Set Current → %.0f lx", L)) { vm.calibSetAnchorB(L) } } }
                                Divider()
                                Button("Fit and Save") { vm.calibFitAndSave() }
                                Button("Clear Anchors") { vm.calibClearAnchors() }
                                Button("Reset Defaults") { vm.calibResetDefaults() }.foregroundStyle(.red)
                            }
                            Divider()
                            Menu("Experimental") { Button("HDR Detection: Auto") { vm.setHDRMode(2) } }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            }
        }
        .padding(12)
        .frame(width: 320)
        .onAppear { vm.stopBackgroundPolling() }
        .onDisappear { vm.startBackgroundPolling() }
    }

    private struct NotSupportedView: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("Display Not Supported")
                    .font(.title2).bold()
                Text("This Mac/display does not report Extended Dynamic Range (EDR). Illumination targets XDR-capable displays only.")
                    .font(.callout)
                Button("Quit App") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 6)
            }
        }
    }

    private func modeName(_ mode: Int) -> String { BrightnessController.modeName(mode) }

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

            // HDR Detection: Off / Apps (Auto moved to Debug, On removed)
            MultiStateActionButton<Int>(
                title: "Detection",
                states: [
                    ActionState(value: 0, imageName: "sparkles.tv",      tint: .gray,   help: "Detection Off"),
                    ActionState(value: 3, imageName: "sparkles.tv.fill", tint: .blue,   help: "Detection Apps")
                ],
                selection: hdrMode,
                size: 48,
                enableHaptics: true,
                showsCaption: false,
                isActiveProvider: { $0 != 0 }
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
                let bc = BrightnessController.shared
                let pct = bc.appIsEnabled() ? Int(round(bc.currentUserPercent())) : 0
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
