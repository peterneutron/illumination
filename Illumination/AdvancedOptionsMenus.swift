import SwiftUI

struct AdvancedOptionsMenu: View {
    @ObservedObject var vm: IlluminationViewModel
    let debugUnlocked: Bool
    var onOpenCalibrator: () -> Void
    var onOpenAppPicker: () -> Void

    var body: some View {
        Menu("Advanced Options") {
            Group {
                Text("General").font(.caption).foregroundStyle(.secondary)
                Toggle(
                    "Run at Login",
                    isOn: Binding(
                        get: { vm.runAtLoginEnabled },
                        set: { vm.setRunAtLogin($0) }
                    )
                )
                Text(vm.runAtLoginStatusLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !vm.launchAtLoginError.isEmpty {
                    Text(vm.launchAtLoginError)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Divider()

            Group {
                Text("Brightness & Safety").font(.caption).foregroundStyle(.secondary)
                Toggle("Guard Mode", isOn: Binding(get: { vm.guardEnabled }, set: { vm.setGuardEnabled($0) }))
                Menu(String(format: String(localized: "Guard Factor: %d%%"), Int(round(vm.guardFactor * 100)))) {
                    ForEach([0.75, 0.85, 0.90, 0.95], id: \.self) { factor in
                        Button(action: { vm.setGuardFactor(factor) }) {
                            HStack {
                                Text(String(format: "%.0f%%", factor * 100.0))
                                if abs(vm.guardFactor - factor) < 0.0001 {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
                Button("EDR Nudge") { vm.edrNudge() }
            }
            .disabled(!(vm.enabled || vm.alsAutoEnabled))

            Divider()

            Group {
                Text("ALS Automatic").font(.caption).foregroundStyle(.secondary)
                Menu(String(format: String(localized: "Sensitivity: %@"), vm.alsProfileName)) {
                    Button(action: { vm.setALSProfileTwilight() }) {
                        HStack {
                            Text("Twilight")
                            if ALSManager.shared.getProfile() == .twilight { Image(systemName: "checkmark") }
                        }
                    }
                    Button(action: { vm.setALSProfileDaybreak() }) {
                        HStack {
                            Text("Daybreak")
                            if ALSManager.shared.getProfile() == .daybreak { Image(systemName: "checkmark") }
                        }
                    }
                    Button(action: { vm.setALSProfileMidday() }) {
                        HStack {
                            Text("Midday")
                            if ALSManager.shared.getProfile() == .midday { Image(systemName: "checkmark") }
                        }
                    }
                    Button(action: { vm.setALSProfileSunburst() }) {
                        HStack {
                            Text("Sunburst")
                            if ALSManager.shared.getProfile() == .sunburst { Image(systemName: "checkmark") }
                        }
                    }
                    Button(action: { vm.setALSProfileHighNoon() }) {
                        HStack {
                            Text("High Noon")
                            if ALSManager.shared.getProfile() == .highNoon { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            .disabled(!vm.alsAvailable)

            Divider()
            AppDetectionMenu(vm: vm, onOpenAppPicker: onOpenAppPicker)

            if debugUnlocked {
                Divider()
                DebugMenu(vm: vm, onOpenCalibrator: onOpenCalibrator)
            }
        }
        .accessibilityIdentifier("advanced-options-menu")
    }
}

struct DebugMenu: View {
    @ObservedObject var vm: IlluminationViewModel
    var onOpenCalibrator: () -> Void

    var body: some View {
        Menu("Debug") {
            Menu("Diagnostics") {
                Menu("Live Diagnostics") {
                    ForEach(vm.debugDetails, id: \.self) { line in Text(line) }
                    Divider()
                    Button("Copy Diagnostics") { vm.copyDiagnosticsToPasteboard() }
                }
                Menu("Display Probe") {
                    ForEach(DisplayStateProbe.shared.debugLines(), id: \.self) { line in Text(line) }
                    Divider()
                    Button("Re-probe Displays") { vm.reprobeDisplays() }
                }
                Menu("ALS Trace") {
                    Toggle(
                        "Capture",
                        isOn: Binding(
                            get: { vm.alsTraceCaptureEnabled },
                            set: { vm.setALSTraceCaptureEnabled($0) }
                        )
                    )
                    Button("Copy JSONL") { vm.copyALSTraceJSONL() }
                    Button("Clear Buffer") { vm.clearALSTrace() }
                    Button("Replay Last Export") { vm.replayLastALSTraceExport() }
                    Text(vm.alsTraceReplaySummary).font(.caption).foregroundStyle(.secondary)
                }
            }
            Menu("Profiles") {
                Menu("ALS Hardware Profile: \(vm.alsHardwareProfileName)") {
                    ForEach(ALSHardwareProfileID.allCases, id: \.self) { profile in
                        Button(action: { vm.setALSHardwareProfile(profile) }) {
                            HStack {
                                Text(profile.displayName)
                                if vm.alsHardwareProfileID == profile { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
                Menu("EDR Policy Profile: \(vm.edrPolicyProfileName)") {
                    ForEach(EDRPolicyProfileID.allCases, id: \.self) { profile in
                        Button(action: { vm.setEDRPolicyProfile(profile) }) {
                            HStack {
                                Text(profile.displayName)
                                if vm.edrPolicyProfileID == profile { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }
            Menu("ALS Tools") {
                Menu("Lux Steps") {
                    Button(action: { vm.setLuxStepMode(0) }) { HStack { Text("1 lx"); if vm.luxStepMode == 0 { Image(systemName: "checkmark") } } }
                    Button(action: { vm.setLuxStepMode(1) }) { HStack { Text("0.1 k lx"); if vm.luxStepMode == 1 { Image(systemName: "checkmark") } } }
                    Button(action: { vm.setLuxStepMode(2) }) { HStack { Text("0.5 k lx"); if vm.luxStepMode == 2 { Image(systemName: "checkmark") } } }
                    Button(action: { vm.setLuxStepMode(3) }) { HStack { Text("1 k lx"); if vm.luxStepMode == 3 { Image(systemName: "checkmark") } } }
                }
                Menu("ALS Tuning") {
                    Menu("Entry Min: \(vm.entryMinPercent)%") {
                        ForEach([1, 2, 5, 10], id: \.self) { percent in
                            Button(action: { vm.setEntryMinPercent(percent) }) {
                                HStack { Text("\(percent)%"); if vm.entryMinPercent == percent { Image(systemName: "checkmark") } }
                            }
                        }
                    }
                    Menu(String(format: "Entry Envelope: %.1fs", vm.entryEnvelopeSeconds)) {
                        ForEach([0.5, 1.0, 1.5, 2.0, 3.0], id: \.self) { seconds in
                            Button(action: { vm.setEntryEnvelopeSeconds(seconds) }) {
                                HStack { Text(String(format: "%.1fs", seconds)); if abs(vm.entryEnvelopeSeconds - seconds) < 0.0001 { Image(systemName: "checkmark") } }
                            }
                        }
                    }
                    Menu("Max Slope: \(vm.maxPercentPerSecond)%/s") {
                        ForEach([20, 40, 50, 80, 100], id: \.self) { value in
                            Button(action: { vm.setMaxPercentPerSecond(value) }) {
                                HStack { Text("\(value)%/s"); if vm.maxPercentPerSecond == value { Image(systemName: "checkmark") } }
                            }
                        }
                    }
                    Menu(String(format: "Min On: %.1fs", vm.minOnSeconds)) {
                        ForEach([0.0, 1.0, 1.5, 2.0, 3.0], id: \.self) { seconds in
                            Button(action: { vm.setMinOnSeconds(seconds) }) {
                                HStack { Text(String(format: "%.1fs", seconds)); if abs(vm.minOnSeconds - seconds) < 0.0001 { Image(systemName: "checkmark") } }
                            }
                        }
                    }
                    Menu(String(format: "Min Off: %.1fs", vm.minOffSeconds)) {
                        ForEach([0.0, 1.0, 1.5, 2.0, 3.0], id: \.self) { seconds in
                            Button(action: { vm.setMinOffSeconds(seconds) }) {
                                HStack { Text(String(format: "%.1fs", seconds)); if abs(vm.minOffSeconds - seconds) < 0.0001 { Image(systemName: "checkmark") } }
                            }
                        }
                    }
                }
                Button("Open Calibrator Editor…") { onOpenCalibrator() }
            }
            Menu("HDR & Overlay") {
                Menu("Overlay") {
                    Menu("FPS: \(vm.overlayFPS)") {
                        ForEach([5, 10, 15, 30, 60, 120], id: \.self) { fps in
                            Button(action: { vm.setOverlayFPS(fps) }) {
                                HStack {
                                    Text("\(fps)")
                                    if vm.overlayFPS == fps { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                    Button("EDR Nudge") { vm.edrNudge() }
                }
                Menu("Experimental HDR Detection") {
                    Toggle("Enable Experimental HDR Ducking", isOn: Binding(get: { vm.hdrExperimentalEnabled }, set: { vm.setHDRExperimentalEnabled($0) }))
                    Text("Heuristic only. Non-authoritative and may require Screen Recording permission.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Menu("Detection: \(BrightnessController.modeName(vm.hdrMode))") {
                        ForEach([(0, "Off"), (2, "Auto"), (3, "Apps")], id: \.0) { mode in
                            Button(action: { vm.setHDRMode(mode.0) }) {
                                HStack {
                                    Text(mode.1)
                                    if vm.hdrMode == mode.0 { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                    Menu("Duck Target: \(vm.hdrDuckPercent)%") {
                        ForEach([30, 40, 50], id: \.self) { percent in
                            Button(action: { vm.setHDRDuckPercent(percent) }) {
                                HStack {
                                    Text("\(percent)%")
                                    if vm.hdrDuckPercent == percent { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                    Menu(String(format: "Threshold: %.2f", vm.hdrThreshold)) {
                        ForEach([1.4, 1.5, 1.8, 2.0], id: \.self) { threshold in
                            Button(action: { vm.setHDRThreshold(threshold) }) {
                                HStack {
                                    Text(String(format: "%.2f", threshold))
                                    if abs(vm.hdrThreshold - threshold) < 0.0001 { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                    Menu("Fade: \(vm.hdrFadeMs) ms") {
                        ForEach([200, 300, 500], id: \.self) { milliseconds in
                            Button(action: { vm.setHDRFadeMs(milliseconds) }) {
                                HStack {
                                    Text("\(milliseconds) ms")
                                    if vm.hdrFadeMs == milliseconds { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                }
                Menu("HDR Tile") {
                    Toggle("Enable", isOn: Binding(get: { vm.tileEnabled }, set: { vm.setTileEnabled($0) }))
                        .disabled(!vm.tileAvailable)
                    if !vm.tileAvailable {
                        Text("Asset not found").font(.caption).foregroundStyle(.secondary)
                    }
                    Menu("Size: \(vm.tileSize) px") {
                        ForEach([64, 32, 16, 8, 4, 1], id: \.self) { size in
                            Button(action: { vm.setTileSize(size) }) {
                                HStack {
                                    Text("\(size) px")
                                    if vm.tileSize == size { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                    Menu("Opacity: \(vm.tileFullOpacity ? "Full" : "Low")") {
                        Button(action: { vm.setTileFullOpacity(false) }) { HStack { Text("Low"); if !vm.tileFullOpacity { Image(systemName: "checkmark") } } }
                        Button(action: { vm.setTileFullOpacity(true) }) { HStack { Text("Full"); if vm.tileFullOpacity { Image(systemName: "checkmark") } } }
                    }
                }
            }
        }
    }
}
