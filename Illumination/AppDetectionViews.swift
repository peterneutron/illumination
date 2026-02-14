import SwiftUI

struct AppDetectionMenu: View {
    @ObservedObject var vm: IlluminationViewModel
    var onOpenAppPicker: () -> Void

    var body: some View {
        Group {
            Text("App Detection").font(.caption).foregroundStyle(.secondary)

            Menu("Detection: \(modeName(vm.hdrMode))") {
                ForEach([(0, "Off"), (3, "Apps")], id: \.0) { mode in
                    Button(action: { vm.setHDRMode(mode.0) }) {
                        HStack {
                            Text(mode.1)
                            if vm.hdrMode == mode.0 { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            .accessibilityIdentifier("app-detection-mode-menu")

            Button("Add Frontmost App (\(vm.frontmostAppDisplayLabel))") {
                vm.addFrontmostHDRApp()
            }
            .accessibilityIdentifier("app-detection-add-frontmost")
            .disabled(!vm.canAddFrontmostHDRApp)
            .help(vm.canAddFrontmostHDRApp ? "Add the frontmost app to App Detection." : vm.addFrontmostDisabledReason)

            Button("Add from Installed Apps…") {
                onOpenAppPicker()
            }
            .accessibilityIdentifier("app-detection-add-installed")

            Menu("Managed Apps") {
                let entries = vm.hdrManagedApps
                if entries.isEmpty {
                    Text("No managed apps yet.")
                } else {
                    ForEach(entries, id: \.bundleID) { entry in
                        Menu(entry.displayName ?? entry.bundleID) {
                            let isEnabled = entry.isEnabled
                            Button(isEnabled ? "Disable" : "Enable") {
                                vm.setHDRAppEnabled(bundleID: entry.bundleID, enabled: !isEnabled)
                            }
                            if !entry.isDefault {
                                Divider()
                                Button("Remove") {
                                    vm.removeHDRApp(bundleID: entry.bundleID)
                                }
                            }
                        }
                    }
                }
            }
            .accessibilityIdentifier("app-detection-managed-apps")

            Button("Reset App Defaults") {
                vm.resetHDRAppDefaults()
            }
            .accessibilityIdentifier("app-detection-reset-defaults")
        }
    }

    private func modeName(_ mode: Int) -> String {
        BrightnessController.modeName(mode)
    }
}

struct AppPickerPanel: View {
    @ObservedObject var vm: IlluminationViewModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Installed Apps").font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("app-picker-close")
            }

            TextField("Search apps or bundle IDs", text: $vm.appPickerQuery)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("app-picker-search")

            if vm.appPickerLoading {
                Text("Scanning installed apps…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("app-picker-loading")
            } else if vm.filteredInstalledApps.isEmpty {
                Text("No matching apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("app-picker-empty")
            } else {
                let visibleApps = Array(vm.filteredInstalledApps.prefix(80))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(visibleApps, id: \.bundleID) { app in
                            Button(action: {
                                vm.addHDRApp(bundleID: app.bundleID, displayName: app.displayName)
                            }) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.displayName)
                                        Text(app.bundleID)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle")
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("app-picker-row-\(app.bundleID)")
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 220)
                .accessibilityIdentifier("app-picker-list")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
        .onAppear { vm.loadInstalledApps() }
    }
}
