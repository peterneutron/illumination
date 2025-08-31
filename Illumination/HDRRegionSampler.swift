//
//  HDRRegionSampler.swift
//  Illumination
//

import AppKit
import AVFoundation
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

final class HDRRegionSampler: NSObject {
    private(set) var hdrPresent: Bool = false
    private var roi: CGRect?

    #if canImport(ScreenCaptureKit)
    @available(macOS 12.3, *)
    private var stream: SCStream?
    @available(macOS 12.3, *)
    private var output: SCStreamOutput?
    #endif

    func setRegionOfInterest(_ rect: CGRect?) { roi = rect }

    func start(displayID: CGDirectDisplayID) {
        hdrPresent = false
        #if canImport(ScreenCaptureKit)
        if #available(macOS 12.3, *) {
            guard stream == nil else { return }
            Task { [weak self] in
                guard let self = self else { return }
                do {
                    let content = try await SCShareableContent.current
                    guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
                        return
                    }
                    let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
                    let cfg = SCStreamConfiguration()
                    cfg.width = 256
                    cfg.height = 144
                    cfg.minimumFrameInterval = CMTime(value: 1, timescale: 4) // ~4 fps
                    if let r = self.roi {
                        cfg.sourceRect = r
                    }
                    let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
                    try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .utility))
                    try await s.startCapture()
                    self.stream = s
                } catch {
                    // Permission or API failure; remain no-op
                }
            }
        }
        #endif
    }

    func stop() {
        hdrPresent = false
        #if canImport(ScreenCaptureKit)
        if #available(macOS 12.3, *) {
            Task { [weak self] in
                guard let self = self else { return }
                do {
                    try await self.stream?.stopCapture()
                } catch { }
                self.stream = nil
            }
        }
        #endif
    }
}

#if canImport(ScreenCaptureKit)
@available(macOS 12.3, *)
extension HDRRegionSampler: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        // BGRA 8-bit sampling heuristic (approximate): consider HDR-like if a small fraction of samples are near peak.
        let stepX = max(1, w / 16)
        let stepY = max(1, h / 9)
        // Exclude bottom-left corner where our tile lives (approximate mapping)
        var exclX = 0
        var exclY = 0
        if let scr = NSScreen.main {
            let tilePts = CGFloat(TileFeature.shared.size + 24)
            let sw = max(1.0, scr.frame.width)
            let sh = max(1.0, scr.frame.height)
            exclX = Int((tilePts / sw) * CGFloat(w))
            exclY = Int((tilePts / sh) * CGFloat(h))
        }
        var brightCount = 0
        var total = 0
        for y in Swift.stride(from: 0, to: h, by: stepY) {
            let row = base.advanced(by: y * bytesPerRow)
            for x in Swift.stride(from: 0, to: w, by: stepX) {
                if x < exclX && y < exclY { continue }
                let px = row.advanced(by: x * 4)
                let b = px.load(as: UInt8.self)
                let g = px.advanced(by: 1).load(as: UInt8.self)
                let r = px.advanced(by: 2).load(as: UInt8.self)
                // Count as highlight if very bright luma or all channels saturated
                let luma = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
                if luma >= 250.0 || (r >= 250 && g >= 250 && b >= 250) { brightCount += 1 }
                total += 1
            }
        }
        // If >2% of samples are near max, treat as HDR-like content present (approximation)
        if total > 0 {
            let ratio = Double(brightCount) / Double(total)
            hdrPresent = ratio > 0.02
        } else {
            hdrPresent = false
        }
    }
}
#endif
