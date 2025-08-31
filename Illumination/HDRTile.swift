//
//  HDRTile.swift
//  Illumination
//

import AppKit
import AVFoundation

final class HDRTileManager {
    static let shared = HDRTileManager()

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var layer: AVPlayerLayer?
    private var attachedView: NSView?
    private(set) var assetAvailable: Bool = false

    private var fullscreen: Bool = false
    private var forceFullOpacity: Bool = false
    private var tileSize: CGFloat = 64.0

    private init() {
        scanAssetAvailability()
    }

    // Scan for an HDR asset in the bundle without creating players
    func scanAssetAvailability() {
        let bundle = Bundle.main
        let candidates = ["HDRTile", "hdr_tile", "HDR_Sample", "hdr"]
        let exts = ["mp4", "mov", "m4v"]
        var found = false
        for name in candidates where !found {
            for ext in exts {
                if bundle.url(forResource: name, withExtension: ext) != nil {
                    found = true
                    break
                }
            }
        }
        assetAvailable = found
    }

    private func loadAssetIfNeeded() {
        guard player == nil || layer == nil else { return }
        scanAssetAvailability()
        guard assetAvailable else { return }

        let bundle = Bundle.main
        let candidates = ["HDRTile", "hdr_tile", "HDR_Sample", "hdr"]
        let exts = ["mp4", "mov", "m4v"]
        var url: URL? = nil
        for name in candidates {
            for ext in exts {
                if let u = bundle.url(forResource: name, withExtension: ext) { url = u; break }
            }
            if url != nil { break }
        }
        guard let assetURL = url else { assetAvailable = false; return }

        let asset = AVURLAsset(url: assetURL)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 0
        let q = AVQueuePlayer(items: [item])
        q.automaticallyWaitsToMinimizeStalling = false
        let l = AVPlayerLayer(player: q)
        l.videoGravity = .resizeAspectFill
        l.isOpaque = false
        l.opacity = 0.001

        self.player = q
        self.layer = l
        self.looper = AVPlayerLooper(player: q, templateItem: item)
        q.volume = 0
        q.play()
        assetAvailable = true
    }

    func attach(to view: NSView) {
        loadAssetIfNeeded()
        guard let layer = layer else { return }
        guard attachedView !== view else { return }
        detach()
        DispatchQueue.main.async {
            view.wantsLayer = true
            view.layer?.addSublayer(layer)
        }
        attachedView = view
    }

    func presentSmallTile() {
        guard attachedView != nil, let l = layer else { return }
        fullscreen = false
        let size = tileSize
        DispatchQueue.main.async {
            l.opacity = self.forceFullOpacity ? 1.0 : 0.01
            l.frame = CGRect(x: 12, y: 12, width: size, height: size)
        }
    }

    func presentFullScreen() {
        guard let v = attachedView, let l = layer else { return }
        fullscreen = true
        DispatchQueue.main.async {
            l.opacity = 1.0
            l.frame = v.bounds
        }
    }

    func detach() {
        if attachedView != nil, let l = layer {
            l.removeFromSuperlayer()
            attachedView = nil
        }
    }

    func setFullOpacity(_ enabled: Bool) {
        forceFullOpacity = enabled
        if fullscreen { presentFullScreen() } else { presentSmallTile() }
    }

    func setTileSize(_ size: Int) {
        tileSize = max(1, min(512, CGFloat(size)))
        if !fullscreen { presentSmallTile() }
    }
}
