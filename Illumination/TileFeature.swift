//
//  TileFeature.swift
//  Illumination
//

import AppKit

final class TileFeature {
    static let shared = TileFeature()

    // Persistence keys (tile-only)
    private let keyEnabled = "illumination.overlay.hdrtile"
    private let keyFullOpacity = "illumination.overlay.hdrtile.fullopacity"
    private let keySize = "illumination.overlay.hdrtile.size"

    private var panelController: TilePanelController?
    private var observersInstalled = false

    private init() {
        // Ensure asset availability is scanned at startup
        HDRTileManager.shared.scanAssetAvailability()
        installObservers()
        // Apply persisted state without altering any overlay logic
        if enabled { ensurePanelIfNeeded(); applyCurrentPresentation() }
    }

    private func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activeSpaceChanged(_:)), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenParamsChanged(_:)), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // MARK: - Public state
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: keyEnabled) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: keyEnabled); newValue ? enable() : disable() }
    }
    // Fullscreen mode removed; tile is always Corner mode
    var fullOpacity: Bool {
        get { UserDefaults.standard.object(forKey: keyFullOpacity) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: keyFullOpacity); HDRTileManager.shared.setFullOpacity(newValue) }
    }
    var size: Int {
        get { max(1, min(512, UserDefaults.standard.object(forKey: keySize) as? Int ?? 64)) }
        set {
            let s = max(1, min(512, newValue))
            UserDefaults.standard.set(s, forKey: keySize)
            HDRTileManager.shared.setTileSize(s)
            panelController?.updateFrame(tileSize: s, fullscreen: false)
        }
    }

    var assetAvailable: Bool { HDRTileManager.shared.assetAvailable }

    // MARK: - Control
    func toggleEnabled() { enabled.toggle() }
    func toggleFullOpacity() { fullOpacity.toggle() }

    // MARK: - Internals
    private func ensurePanelIfNeeded() {
        if panelController == nil {
            let sc = NSScreen.main ?? NSScreen.screens.first!
            panelController = TilePanelController(screen: sc)
        }
    }

    private func enable() {
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
        if !enabled { return }
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
