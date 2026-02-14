import SwiftUI

struct AppDetectionMenu: View {
    @ObservedObject var vm: IlluminationViewModel
    var onOpenAppPicker: () -> Void

    var body: some View {
        Group {
            Text("App Overrides").font(.caption).foregroundStyle(.secondary)
            Text(String(localized: "Blocked Apps are the production gate. Experimental HDR detection is Debug-only."))
                .font(.caption2)
                .foregroundStyle(.secondary)

            Menu(String(format: String(localized: "Mode: %@"), vm.modeIsAuto ? String(localized: "Auto") : String(localized: "Manual"))) {
                Button(action: { vm.setModeIsAuto(false) }) {
                    HStack {
                        Text("Manual")
                        if !vm.modeIsAuto { Image(systemName: "checkmark") }
                    }
                }
                Button(action: { vm.setModeIsAuto(true) }) {
                    HStack {
                        Text("Auto")
                        if vm.modeIsAuto { Image(systemName: "checkmark") }
                    }
                }
            }
            .accessibilityIdentifier("app-policy-mode-menu")

            Menu(String(format: String(localized: "Scope: %@"), vm.appPolicyScopeName)) {
                ForEach([(0, String(localized: "Everywhere")), (1, String(localized: "Apps"))], id: \.0) { scope in
                    Button(action: { vm.setAppScope(scope.0) }) {
                        HStack {
                            Text(scope.1)
                            if vm.appScope == scope.0 { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            .accessibilityIdentifier("app-policy-scope-menu")

            if vm.appPolicyBlocked {
                Text(String(format: String(localized: "Blocked by app: %@"), vm.appPolicyBlockedLabel))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("app-policy-blocked-label")
            }

            Button(String(format: String(localized: "Add Frontmost Blocked App (%@)"), vm.frontmostAppDisplayLabel)) {
                vm.addFrontmostBlockedApp()
            }
            .accessibilityIdentifier("app-policy-add-frontmost")
            .disabled(!vm.canAddFrontmostBlockedApp)
            .help(vm.canAddFrontmostBlockedApp ? String(localized: "Add the frontmost app to blocked apps.") : vm.addFrontmostDisabledReason)

            Button("Add from Installed Apps…") {
                onOpenAppPicker()
            }
            .accessibilityIdentifier("app-policy-add-installed")

            Menu("Blocked Apps") {
                let entries = vm.blockedApps
                if entries.isEmpty {
                    Text("No blocked apps configured.")
                } else {
                    ForEach(entries, id: \.bundleID) { entry in
                        Menu(entry.displayName ?? entry.bundleID) {
                            let isBlocked = entry.isEnabled
                            Button(isBlocked ? String(localized: "Unblock") : String(localized: "Block")) {
                                vm.setBlockedAppEnabled(bundleID: entry.bundleID, enabled: !isBlocked)
                            }
                            if !entry.isDefault {
                                Divider()
                                Button("Remove") {
                                    vm.removeBlockedApp(bundleID: entry.bundleID)
                                }
                            }
                        }
                    }
                }
            }
            .accessibilityIdentifier("app-policy-blocked-apps")

            Button("Reset Blocked App Defaults") {
                vm.resetBlockedAppDefaults()
            }
            .accessibilityIdentifier("app-policy-reset-defaults")
        }
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
                                vm.addBlockedApp(bundleID: app.bundleID, displayName: app.displayName)
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
