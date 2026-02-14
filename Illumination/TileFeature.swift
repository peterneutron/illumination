//
//  TileFeature.swift
//  Illumination
//

import AppKit

final class TileFeature {
    static let shared = TileFeature()

    private var panelController: TilePanelController?
    private var observersInstalled = false
    private var masterSuspended = false
    private var alsSuspended = false

    private init() {
        // Ensure asset availability is scanned at startup
        HDRTileManager.shared.scanAssetAvailability()
        installObservers()
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        // Only bootstrap tile visuals when master is on and not under XCTest.
        // Keep persisted tile preference untouched for later restore.
        if enabled && Settings.masterEnabled && !isRunningTests {
            enable()
        }
    }

    private func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activeSpaceChanged(_:)), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenParamsChanged(_:)), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // MARK: - Public state
    var enabled: Bool {
        get { Settings.tileEnabled }
        set {
            Settings.tileEnabled = newValue
            newValue ? enable() : disable()
        }
    }
    // Fullscreen mode removed; tile is always Corner mode
    var fullOpacity: Bool {
        get { Settings.tileFullOpacity }
        set {
            Settings.tileFullOpacity = newValue
            HDRTileManager.shared.setFullOpacity(newValue)
        }
    }
    var size: Int {
        get { Settings.tileSize }
        set {
            let s = max(1, min(512, newValue))
            Settings.tileSize = s
            HDRTileManager.shared.setTileSize(s)
            panelController?.updateFrame(tileSize: s, fullscreen: false)
        }
    }

    var assetAvailable: Bool { HDRTileManager.shared.assetAvailable }
    var isCurrentlyVisible: Bool {
        enabled && !masterSuspended && !alsSuspended && (panelController?.window?.isVisible == true)
    }

    // MARK: - Control
    func toggleEnabled() { enabled.toggle() }
    func toggleFullOpacity() { fullOpacity.toggle() }

    // MARK: - Internals
    private func ensurePanelIfNeeded() {
        if panelController == nil {
            guard let sc = NSScreen.main ?? NSScreen.screens.first else {
                RuntimeDiagnostics.shared.report(.tilePanelUnavailable, details: "No screen available to attach HDR tile panel.")
                return
            }
            panelController = TilePanelController(screen: sc)
        }
    }

    private func enable() {
        guard !masterSuspended && !alsSuspended else { return }
        ensurePanelIfNeeded()
        guard let panel = panelController else { return }
        panel.open()
        panel.updateFrame(tileSize: size, fullscreen: false)
        if let host = panel.window?.contentView {
            HDRTileManager.shared.attach(to: host)
            HDRTileManager.shared.setTileSize(size)
            HDRTileManager.shared.setFullOpacity(fullOpacity)
        }
        applyCurrentPresentation()
    }

    private func disable() {
        HDRTileManager.shared.detach()
        panelController?.window?.close()
    }

    private func applyCurrentPresentation() {
        if !enabled || masterSuspended || alsSuspended { return }
        panelController?.updateFrame(tileSize: size, fullscreen: false)
        HDRTileManager.shared.presentSmallTile()
    }

    @objc private func activeSpaceChanged(_ note: Notification) {
        guard enabled, let panel = panelController else { return }
        if let sc = NSScreen.main { panel.reposition(to: sc) }
        panel.bringToActiveSpace()
        panel.updateFrame(tileSize: size, fullscreen: false)
        applyCurrentPresentation()
    }

    @objc private func screenParamsChanged(_ note: Notification) {
        guard let panel = panelController else { return }
        if let sc = NSScreen.main { panel.reposition(to: sc) }
        panel.updateFrame(tileSize: size, fullscreen: false)
        applyCurrentPresentation()
    }
}

// MARK: - Master enable/disable integration
extension TileFeature {
    func suspendForMasterDisable() {
        masterSuspended = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Detach visuals without changing the user's enabled preference
            HDRTileManager.shared.detach()
            self.panelController?.window?.close()
        }
    }

    func resumeAfterMasterEnable() {
        masterSuspended = false
        // If user preference is enabled, re-present on main thread
        guard enabled else { return }
        DispatchQueue.main.async { [weak self] in
            self?.enable()
        }
    }

    func suspendForALS() {
        alsSuspended = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            HDRTileManager.shared.detach()
            self.panelController?.window?.close()
        }
    }

    func resumeAfterALS() {
        alsSuspended = false
        guard enabled else { return }
        DispatchQueue.main.async { [weak self] in
            self?.enable()
        }
    }
}
