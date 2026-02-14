import Foundation
import AppKit

extension NSScreen {
    var displayId: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? CGDirectDisplayID
    }
}

private func isBuiltInScreen(_ screen: NSScreen) -> Bool {
    guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
    return CGDisplayIsBuiltin(num) != 0
}

func targetDisplays() -> [NSScreen] {
    // Minimal: affect built-in display(s) only
    NSScreen.screens.filter { isBuiltInScreen($0) }
}

private class GammaTable {
    static let tableSize: UInt32 = 256
    var red: [CGGammaValue] = .init(repeating: 0, count: Int(tableSize))
    var green: [CGGammaValue] = .init(repeating: 0, count: Int(tableSize))
    var blue: [CGGammaValue] = .init(repeating: 0, count: Int(tableSize))

    static func capture(displayId: CGDirectDisplayID) -> GammaTable? {
        let t = GammaTable()
        var sampleCount: UInt32 = 0
        let res = CGGetDisplayTransferByTable(displayId, tableSize, &t.red, &t.green, &t.blue, &sampleCount)
        return res == .success ? t : nil
    }

    func apply(displayId: CGDirectDisplayID, factor: Float) {
        var r = red
        var g = green
        var b = blue
        if factor != 1.0 {
            for i in 0..<r.count { r[i] *= factor }
            for i in 0..<g.count { g[i] *= factor }
            for i in 0..<b.count { b[i] *= factor }
        }
        CGSetDisplayTransferByTable(displayId, GammaTable.tableSize, &r, &g, &b)
    }
}

final class GammaTechnique {
    private(set) var isEnabled = false
    private var gammaTables: [CGDirectDisplayID: GammaTable] = [:]
    private var overlayWindowControllers: [CGDirectDisplayID: OverlayWindowController] = [:]
    private var desiredFullsize: Bool = true
    private var desiredFPS: Int = 30
    private var nudgeTimer: Timer?

    func enable() {
        for screen in targetDisplays() {
            enableScreen(screen: screen)
        }
        isEnabled = true
    }

    private func enableScreen(screen: NSScreen) {
        guard let id = screen.displayId else { return }
        if gammaTables[id] == nil {
            gammaTables[id] = GammaTable.capture(displayId: id)
        }
        if overlayWindowControllers[id] == nil {
            let controller = OverlayWindowController(screen: screen, fullsize: desiredFullsize)
            overlayWindowControllers[id] = controller
            let rect = NSRect(x: screen.frame.origin.x, y: screen.frame.origin.y, width: 1, height: 1)
            controller.open(rect: rect)
            controller.setFPS(desiredFPS)
        }
    }

    func disable() {
        isEnabled = false
        overlayWindowControllers.values.forEach { $0.window?.close() }
        overlayWindowControllers.removeAll()
        gammaTables.removeAll()
        CGDisplayRestoreColorSyncSettings()
    }

    func adjust(factor: Float) {
        guard isEnabled else { return }
        for screen in targetDisplays() {
            if let id = screen.displayId {
                if gammaTables[id] == nil {
                    gammaTables[id] = GammaTable.capture(displayId: id)
                }
                gammaTables[id]?.apply(displayId: id, factor: factor)
            }
        }
    }

    func screenUpdate(screens: [NSScreen]) {
        let currentIds = Set(screens.compactMap { $0.displayId })
        let knownIds = Set(overlayWindowControllers.keys)
        for id in knownIds.subtracting(currentIds) {
            overlayWindowControllers[id]?.window?.close()
            overlayWindowControllers.removeValue(forKey: id)
            gammaTables.removeValue(forKey: id)
        }
        for screen in screens {
            guard let id = screen.displayId else { continue }
            if let ctrl = overlayWindowControllers[id] {
                ctrl.reposition(screen: screen)
            } else {
                enableScreen(screen: screen)
            }
        }
    }

    func setOverlayConfig(fullsize: Bool, fps: Int) {
        desiredFullsize = fullsize
        desiredFPS = fps
        for (id, ctrl) in overlayWindowControllers {
            if ctrl.fullsize != fullsize, NSScreen.screens.first(where: { $0.displayId == id }) != nil {
                ctrl.recreate(fullsize: fullsize)
                ctrl.setFPS(fps)
                ctrl.setPausedDrawLoop(true)
            } else {
                ctrl.setFPS(fps)
                ctrl.setPausedDrawLoop(true)
            }
            ctrl.requestRedraw()
        }
    }

    func nudgeEDR() {
        for (_, ctrl) in overlayWindowControllers { ctrl.setPausedDrawLoop(false) }
        setOverlayConfig(fullsize: desiredFullsize, fps: max(desiredFPS, 60))
        nudgeTimer?.invalidate()
        nudgeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.setOverlayConfig(fullsize: self.desiredFullsize, fps: self.desiredFPS)
            for (_, ctrl) in self.overlayWindowControllers { ctrl.setPausedDrawLoop(true) }
        }
    }

    func pulseOverlays() {
        for (_, ctrl) in overlayWindowControllers { ctrl.requestRedraw() }
    }
}
