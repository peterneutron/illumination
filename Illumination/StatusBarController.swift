//
//  StatusBarController.swift
//  Illumination
//

import AppKit

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private var toggleItem: NSMenuItem!
    private var enableCheckbox: NSButton!
    private var sliderItem: NSMenuItem!
    private var slider: NSSlider!
    private var valueField: NSTextField!

    private let controller = BrightnessController.shared
    private let debugMenu = NSMenu()
    private var debugItem: NSMenuItem!
    private var debugPoller: Timer?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        menu.delegate = self
        menu.minimumWidth = 280

        // Title item opens website (placeholder: does nothing for now)
        let titleItem = NSMenuItem(title: "Illumination", action: nil, keyEquivalent: "")
        menu.addItem(titleItem)

        // Toggle item with a real checkbox + label
        let toggleContainer = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 28))
        enableCheckbox = NSButton(checkboxWithTitle: "Enabled", target: self, action: #selector(toggleEnabledCheckbox(_:)))
        enableCheckbox.state = UserDefaults.standard.bool(forKey: "illumination.enabled") ? .on : .off
        enableCheckbox.setFrameOrigin(NSPoint(x: 15, y: (toggleContainer.frame.height - enableCheckbox.intrinsicContentSize.height) / 2))
        toggleContainer.addSubview(enableCheckbox)
        toggleItem = NSMenuItem()
        toggleItem.view = toggleContainer
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Brightness:", action: nil, keyEquivalent: ""))

        // Slider item with custom view
        let sliderContainer = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 36))
        let sliderWidth: CGFloat = 180
        let sliderX: CGFloat = 15
        let sliderY: CGFloat = (sliderContainer.frame.height - 24) / 2

        // Slider now controls userPercent (0...100)
        let initialPercent = BrightnessController.shared.currentUserPercent()
        slider = NSSlider(value: initialPercent, minValue: 0.0, maxValue: 100.0, target: self, action: #selector(sliderChanged(_:)))
        slider.frame = NSRect(x: sliderX, y: sliderY, width: sliderWidth, height: 24)
        slider.isContinuous = true

        valueField = NSTextField(labelWithString: percentString(forPercent: slider.doubleValue))
        valueField.alignment = .right
        valueField.frame = NSRect(x: sliderContainer.frame.width - 50, y: sliderY, width: 40, height: 24)

        sliderContainer.addSubview(slider)
        sliderContainer.addSubview(valueField)
        sliderItem = NSMenuItem()
        sliderItem.view = sliderContainer
        menu.addItem(sliderItem)

        menu.addItem(NSMenuItem.separator())

        // Debug submenu placeholder; populated on open
        debugItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        debugItem.submenu = debugMenu
        menu.addItem(debugItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        let enabled = UserDefaults.standard.bool(forKey: "illumination.enabled")
        statusItem.button?.image = NSImage(systemSymbolName: enabled ? "sun.max.fill" : "sun.min", accessibilityDescription: "Illumination")
        statusItem.button?.toolTip = "Illumination"
    }

    private func syncUIFromDefaults() {
        let enabled = UserDefaults.standard.bool(forKey: "illumination.enabled")
        let percent = BrightnessController.shared.currentUserPercent()
        enableCheckbox.state = enabled ? .on : .off
        slider.minValue = 0.0
        slider.maxValue = 100.0
        slider.doubleValue = percent
        valueField.stringValue = percentString(forPercent: percent)
        updateStatusIcon()
    }

    // MARK: - Actions

    @objc private func toggleEnabledCheckbox(_ sender: NSButton) {
        let newValue = sender.state == .on
        UserDefaults.standard.set(newValue, forKey: "illumination.enabled")
        controller.setEnabled(newValue)
        updateStatusIcon()
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let percent = sender.doubleValue
        valueField.stringValue = percentString(forPercent: percent)
        controller.setUserPercent(percent)
    }

    private func percentString(forPercent percent: Double) -> String {
        return "\(Int(round(percent)))%"
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        syncUIFromDefaults()
        updateDebugMenu()
        startDebugPoller()
    }

    private func updateDebugMenu() {
        debugMenu.removeAllItems()
        let model = getModelIdentifier() ?? "Unknown"
        let details = BrightnessController.shared.currentGammaCapDetails()
        let gammaCap = details.cap

        // Current factor and percents
        let currentFactor: Double = BrightnessController.shared.currentFactorValue()
        let targetPct = BrightnessController.shared.currentUserPercent()
        let effectivePct = BrightnessController.percent(forFactor: currentFactor, cap: gammaCap)
        let enabled = UserDefaults.standard.bool(forKey: "illumination.enabled")

        debugMenu.addItem(withTitle: "Model: \(model)", action: nil, keyEquivalent: "")
        debugMenu.addItem(withTitle: String(format: "Gamma Cap: %.3f", gammaCap), action: nil, keyEquivalent: "")
        let wasClamped = details.rawCap > gammaCap + 0.0005
        debugMenu.addItem(withTitle: String(format: "Raw Cap: %.3f (%@)", details.rawCap, wasClamped ? "clamped" : "not clamped"), action: nil, keyEquivalent: "")
        debugMenu.addItem(withTitle: String(format: "EDR Ratio: %.3f", details.bestRatio), action: nil, keyEquivalent: "")
        debugMenu.addItem(withTitle: String(format: "Safety Margin: %.2f", details.adaptiveMargin), action: nil, keyEquivalent: "")
        debugMenu.addItem(withTitle: String(format: "Ref Gain: %.3f (alpha: %.2f)", details.refGain, details.refAlpha), action: nil, keyEquivalent: "")
        debugMenu.addItem(withTitle: String(format: "Guard Mode: %@, Factor: %.0f%%", details.abStaticMode ? "On" : "Off", details.guardFactor * 100.0), action: nil, keyEquivalent: "")

        // Guard controls
        let guardToggle = NSMenuItem(title: "Toggle Guard Mode", action: #selector(toggleGuardMode), keyEquivalent: "")
        guardToggle.target = self
        debugMenu.addItem(guardToggle)

        let setFactorItem = NSMenuItem(title: "Set Guard Factor", action: nil, keyEquivalent: "")
        let factorMenu = NSMenu()
        let presets: [Double] = [0.75, 0.85, 0.90, 0.95]
        for p in presets {
            let title = String(format: "%.0f%%", p * 100.0)
            let item = NSMenuItem(title: title, action: #selector(setGuardFactorPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = p
            if abs(p - BrightnessController.shared.guardFactorValue()) < 0.001 {
                item.state = .on
            }
            factorMenu.addItem(item)
        }
        setFactorItem.submenu = factorMenu
        debugMenu.addItem(setFactorItem)

        debugMenu.addItem(NSMenuItem.separator())
        // Overlay controls
        let overlayFull = BrightnessController.shared.overlayFullsizeEnabled()
        debugMenu.addItem(withTitle: "Overlay Fullsize: \(overlayFull ? "On" : "Off")", action: nil, keyEquivalent: "")
        let toggleOverlayItem = NSMenuItem(title: "Toggle Overlay Fullsize", action: #selector(toggleOverlayFullsize), keyEquivalent: "")
        toggleOverlayItem.target = self
        debugMenu.addItem(toggleOverlayItem)

        let fpsItem = NSMenuItem(title: "Overlay FPS", action: nil, keyEquivalent: "")
        let fpsMenu = NSMenu()
        for fps in [5, 15, 30, 60] {
            let item = NSMenuItem(title: "\(fps) fps", action: #selector(setOverlayFPSPreset(_:)), keyEquivalent: "")
            item.target = self
            item.tag = fps
            if fps == BrightnessController.shared.overlayFPSValue() { item.state = .on }
            fpsMenu.addItem(item)
        }
        fpsItem.submenu = fpsMenu
        debugMenu.addItem(fpsItem)

        let nudgeItem = NSMenuItem(title: "EDR Nudge", action: #selector(edrNudge), keyEquivalent: "")
        nudgeItem.target = self
        debugMenu.addItem(nudgeItem)

        // --- HDR Tile controls ---
        debugMenu.addItem(NSMenuItem.separator())
        HDRTileManager.shared.scanAssetAvailability()
        let tileAvail = HDRTileManager.shared.assetAvailable
        let tileEnabled = TileFeature.shared.enabled
        debugMenu.addItem(withTitle: "HDR Tile: \(tileEnabled ? "On" : "Off") (Asset: \(tileAvail ? "Found" : "Missing"))", action: nil, keyEquivalent: "")
        let toggleTile = NSMenuItem(title: "Toggle HDR Tile", action: #selector(toggleHDRTile), keyEquivalent: "")
        toggleTile.target = self
        debugMenu.addItem(toggleTile)

        // Tile Mode: Corner only (fullscreen removed)

        let currentSize = TileFeature.shared.size
        debugMenu.addItem(withTitle: "Tile Size: \(currentSize)x\(currentSize)", action: nil, keyEquivalent: "")
        let sizeItem = NSMenuItem(title: "Set Tile Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for size in [64, 32, 16, 8, 4, 1] {
            let item = NSMenuItem(title: "\(size) px", action: #selector(setTileSizePreset(_:)), keyEquivalent: "")
            item.target = self
            item.tag = size
            if size == currentSize { item.state = .on }
            sizeMenu.addItem(item)
        }
        sizeItem.submenu = sizeMenu
        debugMenu.addItem(sizeItem)

        let fullOpacity = TileFeature.shared.fullOpacity
        debugMenu.addItem(withTitle: "Tile Opacity: \(fullOpacity ? "Full" : "Low")", action: nil, keyEquivalent: "")
        let toggleOpacity = NSMenuItem(title: "Toggle Tile Opacity", action: #selector(toggleTileOpacity), keyEquivalent: "")
        toggleOpacity.target = self
        debugMenu.addItem(toggleOpacity)

        // --- HDR-aware (auto-duck) ---
        debugMenu.addItem(NSMenuItem.separator())
        let detectionMode = BrightnessController.shared.hdrRegionSamplerModeValue()
        let detTitle: String = {
            switch detectionMode {
            case 0: return "Off"
            case 1: return "On"
            case 2: return "Auto"
            case 3: return "Apps"
            default: return "Off"
            }
        }()
        debugMenu.addItem(withTitle: "HDR Detection: \(detTitle)", action: nil, keyEquivalent: "")
        let detItem = NSMenuItem(title: "Set HDR Detection", action: nil, keyEquivalent: "")
        let detMenu = NSMenu()
        let detModes = [(0, "Off"), (1, "On"), (2, "Auto"), (3, "Apps")]
        for (val, name) in detModes {
            let item = NSMenuItem(title: name, action: #selector(setHDRRegionSamplerModePreset(_:)), keyEquivalent: "")
            item.target = self
            item.tag = val
            if val == detectionMode { item.state = .on }
            detMenu.addItem(item)
        }
        detItem.submenu = detMenu
        debugMenu.addItem(detItem)
        let duckPct = Int(round(BrightnessController.shared.hdrAwareDuckPercentValue()))
        debugMenu.addItem(withTitle: "HDR Duck Target: \(duckPct)%", action: nil, keyEquivalent: "")
        let duckMenuItem = NSMenuItem(title: "Set HDR Duck Target", action: nil, keyEquivalent: "")
        let duckMenu = NSMenu()
        for p in [30, 40, 50] {
            let item = NSMenuItem(title: "\(p)%", action: #selector(setHDRAwareDuckPreset(_:)), keyEquivalent: "")
            item.target = self
            item.tag = p
            if p == duckPct { item.state = .on }
            duckMenu.addItem(item)
        }
        duckMenuItem.submenu = duckMenu
        debugMenu.addItem(duckMenuItem)
        let thr = BrightnessController.shared.hdrAwareThresholdValue()
        debugMenu.addItem(withTitle: String(format: "HDR Threshold: %.2f", thr), action: nil, keyEquivalent: "")
        let thrItem = NSMenuItem(title: "Set HDR Threshold", action: nil, keyEquivalent: "")
        let thrMenu = NSMenu()
        for t in [1.4, 1.5, 1.8, 2.0] {
            let item = NSMenuItem(title: String(format: "%.2f", t), action: #selector(setHDRAwareThresholdPreset(_:)), keyEquivalent: "")
            item.representedObject = t
            item.target = self
            if abs(t - thr) < 0.001 { item.state = .on }
            thrMenu.addItem(item)
        }
        thrItem.submenu = thrMenu
        debugMenu.addItem(thrItem)
        let fade = BrightnessController.shared.hdrAwareFadeDurationValue()
        debugMenu.addItem(withTitle: String(format: "HDR Fade: %.0f ms", fade * 1000.0), action: nil, keyEquivalent: "")
        let fadeItem = NSMenuItem(title: "Set HDR Fade", action: nil, keyEquivalent: "")
        let fadeMenu = NSMenu()
        for ms in [200, 300, 500] {
            let item = NSMenuItem(title: "\(ms) ms", action: #selector(setHDRAwareFadePreset(_:)), keyEquivalent: "")
            item.target = self
            item.tag = ms
            if abs(Double(ms)/1000.0 - fade) < 0.01 { item.state = .on }
            fadeMenu.addItem(item)
        }
        fadeItem.submenu = fadeMenu
        debugMenu.addItem(fadeItem)
        // HDR Region Sampler options are unified under HDR Detection above
        debugMenu.addItem(withTitle: String(format: "Current Factor: %.3f", currentFactor), action: nil, keyEquivalent: "")
        debugMenu.addItem(withTitle: String(format: "Target %%: %.0f%%, Effective %%: %.0f%%", targetPct, effectivePct), action: nil, keyEquivalent: "")
        debugMenu.addItem(withTitle: "Enabled: \(enabled ? "Yes" : "No")", action: nil, keyEquivalent: "")

        debugMenu.addItem(NSMenuItem.separator())
        debugMenu.addItem(withTitle: "Screens:", action: nil, keyEquivalent: "")
        for screen in NSScreen.screens {
            let maxEDR = screen.maximumExtendedDynamicRangeColorComponentValue
            let refEDR = screen.maximumReferenceExtendedDynamicRangeColorComponentValue
            let supportsEDR = maxEDR > 1.0
            let title = String(format: "• %@ — EDR max: %.3f, ref: %.3f, supportsEDR: %@",
                               screen.localizedName,
                               maxEDR,
                               refEDR,
                               supportsEDR ? "Yes" : "No")
            debugMenu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        }
    }

    private func startDebugPoller() {
        stopDebugPoller()
        debugPoller = Timer(fire: Date.now, interval: 1.0, repeats: true, block: { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                // Keep label in sync with current percent; slider range stays 0..100
                self.valueField.stringValue = self.percentString(forPercent: self.slider.doubleValue)
            }
        })
        RunLoop.main.add(debugPoller!, forMode: .eventTracking)
    }

    private func stopDebugPoller() {
        debugPoller?.invalidate()
        debugPoller = nil
    }

    func menuDidClose(_ menu: NSMenu) {
        stopDebugPoller()
    }

    // MARK: - Debug actions
    @objc private func toggleGuardMode() {
        let enabled = BrightnessController.shared.isGuardEnabled()
        BrightnessController.shared.setGuardEnabled(!enabled)
    }

    @objc private func setGuardFactorPreset(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? Double {
            BrightnessController.shared.setGuardFactor(p)
        }
    }

    @objc private func toggleOverlayFullsize() {
        let on = BrightnessController.shared.overlayFullsizeEnabled()
        BrightnessController.shared.setOverlayFullsize(!on)
    }

    @objc private func setOverlayFPSPreset(_ sender: NSMenuItem) {
        BrightnessController.shared.setOverlayFPS(sender.tag)
    }

    @objc private func edrNudge() {
        BrightnessController.shared.edrNudge()
    }

    // MARK: - Tile actions
    @objc private func toggleHDRTile() {
        TileFeature.shared.toggleEnabled()
    }

    // Tile fullscreen mode removed

    @objc private func toggleTileOpacity() {
        TileFeature.shared.toggleFullOpacity()
    }

    @objc private func setTileSizePreset(_ sender: NSMenuItem) { TileFeature.shared.size = sender.tag }

    // MARK: - HDR-aware actions
    // No direct HDR-Aware toggle; use HDR Detection mode instead
    @objc private func setHDRAwareDuckPreset(_ sender: NSMenuItem) {
        BrightnessController.shared.setHDRAwareDuckPercent(Double(sender.tag))
    }
    @objc private func setHDRAwareThresholdPreset(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Double { BrightnessController.shared.setHDRAwareThreshold(v) }
    }
    @objc private func setHDRAwareFadePreset(_ sender: NSMenuItem) {
        BrightnessController.shared.setHDRAwareFadeDuration(Double(sender.tag) / 1000.0)
    }
    @objc private func setHDRRegionSamplerModePreset(_ sender: NSMenuItem) {
        BrightnessController.shared.setHDRRegionSamplerMode(sender.tag)
    }
}
