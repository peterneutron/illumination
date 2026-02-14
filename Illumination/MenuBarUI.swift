//
//  MenuBarUI.swift
//  Illumination
//

import SwiftUI
import AppKit
import Combine

final class CalibEditorState: ObservableObject {
    @Published var show: Bool = false
}

final class AppPickerEditorState: ObservableObject {
    @Published var show: Bool = false
}

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
    @StateObject private var calibState = CalibEditorState()
    @StateObject private var appPickerState = AppPickerEditorState()

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
                            .help(String(format: String(localized: "Automatic (%@)"), ALSManager.shared.getProfile().displayName))
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
                        Image(systemName: "app.connected.to.app.below.fill")
                        Text(scopeDisplay(vm: vm))
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "lightspectrum.horizontal")
                        LiveLuxLabel()
                    }
                    if let issue = RuntimeDiagnostics.shared.lastIssue {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text("Issue")
                        }
                        .foregroundStyle(.orange)
                        .help(issue)
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
                        get: { vm.sliderDisplayPercent },
                        set: { vm.setPercent($0) }
                    ),
                    autoEnabled: vm.alsAutoEnabled,
                    masterEnabled: vm.enabled
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
                AdvancedOptionsMenu(vm: vm, debugUnlocked: vm.debugUnlocked) {
                    vm.calibRefreshFields()
                    calibState.show = true
                } onOpenAppPicker: {
                    vm.loadInstalledApps()
                    appPickerState.show = true
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            }
            // Inline Calibrator Editor (Debug-only; appears in main popover)
            if vm.debugUnlocked && calibState.show {
                Divider()
                CalibratorEditor(vm: vm, onClose: { calibState.show = false })
            }
            if appPickerState.show {
                Divider()
                AppPickerPanel(vm: vm, onClose: { appPickerState.show = false })
            }
        }
        .padding(12)
        .frame(width: 320)
        .onAppear {
            vm.refreshNow()
            vm.startBackgroundPolling()
        }
        .onDisappear { vm.refreshNow() }
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

    private func tileModeDisplay(vm: IlluminationViewModel) -> String {
        guard (vm.enabled || vm.alsAutoEnabled), vm.runtimeTileEnabled, vm.tileVisibleNow else { return String(localized: "Off") }
        return vm.tileFullOpacity ? String(localized: "Full") : String(localized: "Low")
    }

    private func scopeDisplay(vm: IlluminationViewModel) -> String {
        guard (vm.enabled || vm.alsAutoEnabled) else { return String(localized: "Off") }
        return vm.appPolicyScopeName
    }

    // luxDisplay removed; using LiveLuxLabel instead
}

// MARK: - Inline Calibrator Editor
private struct CalibratorEditor: View {
    @ObservedObject var vm: IlluminationViewModel
    var onClose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Calibration").font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
            }
            // Compact calibrator values (no prefix)
            let cp = ALSManager.shared.calibratorParams()
            Text(String(format: "a=%.5f, p=%.5f, xDark=%.5f", cp.a, cp.p, cp.xDark))
                .font(.caption)
                .foregroundStyle(.secondary)
            // Vertical inputs for compact width
            VStack(alignment: .leading, spacing: 6) {
                Text("a:")
                TextField("a", text: $vm.calibAString)
                    .textFieldStyle(.roundedBorder)
                Text("p:")
                TextField("p", text: $vm.calibPString)
                    .textFieldStyle(.roundedBorder)
            }
            // Primary actions
            HStack(spacing: 8) {
                Button("Set xDark from Current") { vm.calibSetDarkFromCurrent() }
                Spacer()
                Button("Apply") { vm.calibApplyFields(); vm.calibRefreshFields() }
            }
            // Secondary actions
            HStack(spacing: 8) {
                Button("Copy JSON") { vm.copyCalibratorJSON() }
                Spacer()
                Button("Reset Defaults") { vm.calibResetDefaults(); vm.calibRefreshFields() }
                    .foregroundStyle(.red)
            }
            .font(.caption)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
        .onAppear { vm.calibRefreshFields() }
    }
}

// MARK: - Quick Actions
private enum TileMode: Equatable { case off, low, full }

private struct QuickActionsBar: View {
    @ObservedObject var vm: IlluminationViewModel

    private var masterControlState: Binding<MasterControlState> {
        Binding<MasterControlState>(
            get: { vm.masterControlState },
            set: { vm.setMasterControlState($0) }
        )
    }

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

    private var appScope: Binding<Int> {
        Binding<Int>(get: { vm.appScope }, set: { vm.setAppScope($0) })
    }

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            // Master state: Off / Manual / Auto
            MultiStateActionButton<MasterControlState>(
                title: String(localized: "Master"),
                states: [
                    ActionState(value: .off, imageName: "sun.min", tint: .red, help: String(localized: "Off")),
                    ActionState(value: .manual, imageName: "sun.max.fill", tint: .yellow, help: String(localized: "Manual")),
                    ActionState(value: .auto, imageName: "lightspectrum.horizontal", tint: .green, help: String(localized: "Auto"))
                ],
                selection: masterControlState,
                size: 48,
                enableHaptics: true,
                showsCaption: false,
                isActiveProvider: { $0 != .off }
            )
            Spacer(minLength: 0)

            // Tile modes: Off / Low / Full
            MultiStateActionButton<TileMode>(
                title: String(localized: "Tile"),
                states: [
                    ActionState(value: .off,  imageName: "rectangle",       tint: .gray,   help: String(localized: "Tile Off")),
                    ActionState(value: .low,  imageName: "rectangle.fill",  tint: .yellow, help: String(localized: "Tile Low Opacity")),
                    ActionState(value: .full, imageName: "rectangle.fill",  tint: .green,  help: String(localized: "Tile Full Opacity"))
                ],
                selection: tileMode,
                size: 48,
                enableHaptics: true,
                showsCaption: false,
                isActiveProvider: { $0 != .off }
            )
            .disabled(!(vm.enabled || vm.alsAutoEnabled) || !vm.tileAvailable)
            .opacity((!(vm.enabled || vm.alsAutoEnabled) || !vm.tileAvailable) ? 0.5 : 1.0)
            .help(vm.tileAvailable ? String(localized: "Toggle HDR Tile") : String(localized: "HDR asset not found"))
            Spacer(minLength: 0)

            // Scope: Everywhere / Apps
            MultiStateActionButton<Int>(
                title: String(localized: "Scope"),
                states: [
                    ActionState(value: 0, imageName: "globe",                   tint: .gray,  help: String(localized: "Everywhere")),
                    ActionState(value: 1, imageName: "app.connected.to.app.below.fill", tint: .blue,  help: String(localized: "Apps"))
                ],
                selection: appScope,
                size: 48,
                enableHaptics: true,
                showsCaption: false,
                isActiveProvider: { $0 == 1 }
            )
            .disabled(!(vm.enabled || vm.alsAutoEnabled))
            .opacity((vm.enabled || vm.alsAutoEnabled) ? 1.0 : 0.5)
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
            if let t = timer { RunLoop.main.add(t, forMode: .common) }
        }
        deinit { timer?.invalidate() }
        static func formatLux(_ value: Double) -> String {
            if value < 1000 { return "\(Int(round(value))) lx" }
            let mode = Settings.luxStepMode
            switch mode {
            case 0: // 1 lx steps above 1000
                return "\(Int(round(value))) lx"
            case 1: // 0.1 kLux
                let k = value / 1000.0
                let step = (k * 10.0).rounded() / 10.0
                return String(format: "%.1fk lx", step)
            case 3: // 1 kLux
                let k = value / 1000.0
                let step = k.rounded()
                return String(format: "%.0fk lx", step)
            default: // 0.5 kLux
                let k = value / 1000.0
                let step = (k * 2.0).rounded() / 2.0
                return String(format: "%.1fk lx", step)
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
                let state = bc.uiStateSnapshot()
                let pct = Int(round(IlluminationViewModel.sliderDisplayPercent(
                    autoEnabled: state.mode == .auto,
                    masterEnabled: state.masterEnabled,
                    effectivePercent: state.effectivePercent,
                    manualPercent: state.manualPercent
                )))
                label.stringValue = "\(pct)%"
            }
            if let t = timer { RunLoop.main.add(t, forMode: .common) }
        }
        deinit { timer?.invalidate() }
    }
}

// MARK: - AppKit-backed slider without tick marks
private struct PercentSlider: NSViewRepresentable {
    @Binding var value: Double
    var autoEnabled: Bool = false
    var masterEnabled: Bool = true

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value, minValue: 0.0, maxValue: 100.0, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.isContinuous = true
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
        return slider
    }

    func updateNSView(_ nsView: NSSlider, context: Context) {
        context.coordinator.isAutoEnabled = autoEnabled
        context.coordinator.masterEnabled = masterEnabled
        let displayValue = min(100.0, max(0.0, masterEnabled ? value : 0.0))
        if abs(nsView.doubleValue - displayValue) > 0.0001 {
            nsView.doubleValue = displayValue
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    final class Coordinator: NSObject {
        var value: Binding<Double>
        var isAutoEnabled: Bool = false
        var masterEnabled: Bool = true

        init(value: Binding<Double>) { self.value = value }
        @objc func changed(_ sender: NSSlider) {
            guard !isAutoEnabled, masterEnabled else { return }
            let rounded = round(sender.doubleValue)
            if abs(rounded - value.wrappedValue) > 0.0001 {
                value.wrappedValue = min(100.0, max(0.0, rounded))
            }
        }
    }
}
