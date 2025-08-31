//
//  TilePanel.swift
//  Illumination
//

import AppKit

final class TilePanel: NSPanel {
    init() {
        let rect = NSRect(x: 0, y: 0, width: 100, height: 100)
        super.init(contentRect: rect, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        isFloatingPanel = true
        worksWhenModal = true
        becomesKeyOnlyIfNeeded = true
        level = .statusBar
        collectionBehavior = [.stationary, .moveToActiveSpace, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = false
        hasShadow = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        isReleasedWhenClosed = false

        let v = NSView(frame: rect)
        v.autoresizingMask = [.width, .height]
        v.wantsLayer = true
        v.layer?.backgroundColor = .clear
        contentView = v
    }
}

final class TilePanelController: NSWindowController {
    private(set) var screen: NSScreen

    init(screen: NSScreen) {
        self.screen = screen
        let panel = TilePanel()
        super.init(window: panel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func open() {
        guard let w = window else { return }
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
    }

    func reposition(to screen: NSScreen) {
        self.screen = screen
        window?.setFrame(screen.frame, display: true)
    }

    func bringToActiveSpace() { window?.orderFrontRegardless() }
}

