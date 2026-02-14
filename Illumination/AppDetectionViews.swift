import SwiftUI

struct AppDetectionMenu: View {
    @ObservedObject var vm: IlluminationViewModel
    var onOpenAppPicker: () -> Void

    var body: some View {
        Group {
            Text(L("App Overrides")).font(.caption).foregroundStyle(.secondary)

            Menu(LF("Mode: %@", vm.modeIsAuto ? L("Auto") : L("Manual"))) {
                Button(action: { vm.setModeIsAuto(false) }) {
                    HStack {
                        Text(L("Manual"))
                        if !vm.modeIsAuto { Image(systemName: "checkmark") }
                    }
                }
                Button(action: { vm.setModeIsAuto(true) }) {
                    HStack {
                        Text(L("Auto"))
                        if vm.modeIsAuto { Image(systemName: "checkmark") }
                    }
                }
            }
            .accessibilityIdentifier("app-policy-mode-menu")

            Menu(LF("Scope: %@", vm.appPolicyScopeName)) {
                ForEach([(0, L("Everywhere")), (1, L("Apps"))], id: \.0) { scope in
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
                Text(LF("Blocked by app: %@", vm.appPolicyBlockedLabel))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("app-policy-blocked-label")
            }

            Button(LF("Add Frontmost Blocked App (%@)", vm.frontmostAppDisplayLabel)) {
                vm.addFrontmostBlockedApp()
            }
            .accessibilityIdentifier("app-policy-add-frontmost")
            .disabled(!vm.canAddFrontmostBlockedApp)
            .help(vm.canAddFrontmostBlockedApp ? L("Add the frontmost app to blocked apps.") : vm.addFrontmostDisabledReason)

            Button(L("Add from Installed Apps…")) {
                onOpenAppPicker()
            }
            .accessibilityIdentifier("app-policy-add-installed")

            Menu(L("Blocked Apps")) {
                let entries = vm.blockedApps
                if entries.isEmpty {
                    Text(L("No blocked apps configured."))
                } else {
                    ForEach(entries, id: \.bundleID) { entry in
                        Menu(entry.displayName ?? entry.bundleID) {
                            let isBlocked = entry.isEnabled
                            Button(isBlocked ? L("Unblock") : L("Block")) {
                                vm.setBlockedAppEnabled(bundleID: entry.bundleID, enabled: !isBlocked)
                            }
                            if !entry.isDefault {
                                Divider()
                                Button(L("Remove")) {
                                    vm.removeBlockedApp(bundleID: entry.bundleID)
                                }
                            }
                        }
                    }
                }
            }
            .accessibilityIdentifier("app-policy-blocked-apps")

            Button(L("Reset Blocked App Defaults")) {
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
                Text(L("Installed Apps")).font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("app-picker-close")
            }

            TextField(L("Search apps or bundle IDs"), text: $vm.appPickerQuery)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("app-picker-search")

            if vm.appPickerLoading {
                Text(L("Scanning installed apps…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("app-picker-loading")
            } else if vm.filteredInstalledApps.isEmpty {
                Text(L("No matching apps."))
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
