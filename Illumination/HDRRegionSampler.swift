//
//  HDRRegionSampler.swift
//  Illumination
//

import AppKit
import AVFoundation
import CoreGraphics
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

enum HDRSamplerStatus: Equatable {
    case inactive
    case starting
    case running
    case permissionDenied
    case failed(String)

    var debugLabel: String {
        switch self {
        case .inactive: return "inactive"
        case .starting: return "starting"
        case .running: return "running"
        case .permissionDenied: return "permission_denied"
        case .failed(let reason): return "failed(\(reason))"
        }
    }
}

final class HDRRegionSampler: NSObject {
    private let stateQueue = DispatchQueue(label: "illumination.hdrsampler.state")
    private var hdrPresentState: Bool = false
    private var statusState: HDRSamplerStatus = .inactive
    private var roiState: CGRect?
    private var requestedDisplayID: CGDirectDisplayID?
    private var startGeneration: UInt64 = 0

    #if canImport(ScreenCaptureKit)
    @available(macOS 12.3, *)
    private var stream: SCStream?
    #endif

    var hdrPresent: Bool {
        stateQueue.sync { hdrPresentState }
    }

    var status: HDRSamplerStatus {
        stateQueue.sync { statusState }
    }

    func setRegionOfInterest(_ rect: CGRect?) {
        stateQueue.async { self.roiState = rect }
    }

    func start(displayID: CGDirectDisplayID) {
        #if canImport(ScreenCaptureKit)
        if #available(macOS 12.3, *) {
            guard CGPreflightScreenCaptureAccess() else {
                setState(hdrPresent: false, status: .permissionDenied)
                return
            }

            let generation = stateQueue.sync { () -> UInt64 in
                startGeneration += 1
                requestedDisplayID = displayID
                hdrPresentState = false
                statusState = .starting
                return startGeneration
            }

            Task { [weak self] in
                guard let self else { return }

                do {
                    let content = try await SCShareableContent.current
                    let resolvedDisplayID = stateQueue.sync { self.requestedDisplayID ?? displayID }
                    guard let scDisplay = content.displays.first(where: { $0.displayID == resolvedDisplayID }) ?? content.displays.first else {
                        self.transitionToFailure(generation: generation, reason: "display_unavailable")
                        return
                    }

                    let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
                    let cfg = SCStreamConfiguration()
                    cfg.width = 256
                    cfg.height = 144
                    cfg.minimumFrameInterval = CMTime(value: 1, timescale: 4) // ~4 fps
                    if let r = stateQueue.sync(execute: { self.roiState }) {
                        cfg.sourceRect = r
                    }

                    let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
                    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .utility))
                    try await stream.startCapture()

                    await self.swapToRunningStream(stream, generation: generation)
                } catch {
                    self.transitionToFailure(generation: generation, reason: "stream_start_failed")
                }
            }
            return
        }
        #endif

        setState(hdrPresent: false, status: .failed("unsupported_os"))
    }

    func stop() {
        let generation = stateQueue.sync { () -> UInt64 in
            startGeneration += 1
            requestedDisplayID = nil
            hdrPresentState = false
            statusState = .inactive
            return startGeneration
        }

        #if canImport(ScreenCaptureKit)
        if #available(macOS 12.3, *) {
            Task { [weak self] in
                guard let self else { return }
                await self.stopStreamForGeneration(generation)
            }
        }
        #endif
    }

    private func setState(hdrPresent: Bool, status: HDRSamplerStatus) {
        stateQueue.async {
            self.hdrPresentState = hdrPresent
            self.statusState = status
        }
    }

    private func transitionToFailure(generation: UInt64, reason: String) {
        stateQueue.async {
            guard generation == self.startGeneration else { return }
            self.hdrPresentState = false
            self.statusState = .failed(reason)
        }
    }

    #if canImport(ScreenCaptureKit)
    @available(macOS 12.3, *)
    @MainActor
    private func swapToRunningStream(_ newStream: SCStream, generation: UInt64) async {
        let oldStream: SCStream? = stateQueue.sync {
            guard generation == startGeneration else { return nil }
            let existing = stream
            stream = newStream
            hdrPresentState = false
            statusState = .running
            return existing
        }

        if let oldStream {
            try? await oldStream.stopCapture()
        }

        let shouldStopNew = stateQueue.sync { generation != startGeneration }
        if shouldStopNew {
            try? await newStream.stopCapture()
        }
    }

    @available(macOS 12.3, *)
    @MainActor
    private func stopStreamForGeneration(_ generation: UInt64) async {
        let currentStream: SCStream? = stateQueue.sync {
            guard generation == startGeneration else { return nil }
            let existing = stream
            stream = nil
            return existing
        }
        if let currentStream {
            try? await currentStream.stopCapture()
        }
    }

    private func setSampleHDRPresent(_ present: Bool) {
        stateQueue.async {
            guard case .running = self.statusState else { return }
            self.hdrPresentState = present
        }
    }
    #endif
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
            setSampleHDRPresent(ratio > 0.02)
        } else {
            setSampleHDRPresent(false)
        }
    }
}
#endif
