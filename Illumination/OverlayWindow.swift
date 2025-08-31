//
//  OverlayWindow.swift
//  Illumination
//

import AppKit

final class OverlayWindow: NSWindow {
    private(set) var overlay: Overlay?
    private let fullsize: Bool

    init(fullsize: Bool = false) {
        self.fullsize = fullsize
        let rect = NSRect(x: 0, y: 0, width: 1, height: 1)
        if fullsize {
            super.init(contentRect: rect, styleMask: [.fullSizeContentView, .borderless], backing: .buffered, defer: false)
            if #available(macOS 13.0, *) {
                collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle, .canJoinAllApplications, .fullScreenAuxiliary]
            } else {
                collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
            }
            level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        } else {
            super.init(contentRect: rect, styleMask: [], backing: .buffered, defer: false)
            collectionBehavior = [.stationary, .ignoresCycle, .canJoinAllSpaces, .fullScreenAuxiliary]
            level = .screenSaver
            canHide = false
            isMovableByWindowBackground = true
            isReleasedWhenClosed = false
            alphaValue = 1
        }

        isOpaque = false
        hasShadow = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }

    func addMetalOverlay(screen: NSScreen) {
        let ov = Overlay(frame: frame, multiplyCompositing: self.fullsize)
        ov.screenUpdate(screen: screen)
        ov.autoresizingMask = [.width, .height]
        overlay = ov
        contentView = ov
    }
}

final class OverlayWindowController: NSWindowController, NSWindowDelegate {
    private(set) var fullsize: Bool
    let screen: NSScreen

    init(screen: NSScreen, fullsize: Bool = false) {
        self.screen = screen
        self.fullsize = fullsize
        let win = OverlayWindow(fullsize: fullsize)
        super.init(window: win)
        win.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func open(rect: NSRect) {
        guard let ow = window as? OverlayWindow else { return }
        ow.setFrame(rect, display: true)
        if !fullsize { reposition(screen: screen) }
        ow.orderFrontRegardless()
        ow.addMetalOverlay(screen: screen)
    }

    func reposition(screen: NSScreen) {
        guard let win = window else { return }
        var pos = screen.frame.origin
        pos.y += screen.frame.height - 1
        win.setFrameOrigin(pos)
    }

    func setFPS(_ fps: Int) {
        (window as? OverlayWindow)?.overlay?.setFPS(fps)
    }

    func recreate(fullsize: Bool) {
        let rect = NSRect(x: screen.frame.origin.x, y: screen.frame.origin.y, width: 1, height: 1)
        window?.close()
        let newWin = OverlayWindow(fullsize: fullsize)
        self.fullsize = fullsize
        self.window = newWin
        newWin.delegate = self
        open(rect: rect)
    }

    func windowDidMove(_ notification: Notification) {
        guard let win = window, let sc = win.screen else { return }
        var ideal = sc.frame.origin
        ideal.y += sc.frame.height - 1
        if win.frame.origin != ideal { reposition(screen: sc) }
    }
}
