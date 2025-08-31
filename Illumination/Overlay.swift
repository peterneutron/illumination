//
//  Overlay.swift
//  Illumination
//

import Cocoa
import MetalKit

final class Overlay: MTKView, MTKViewDelegate {
    private let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)

    private var commandQueue: MTLCommandQueue?

    init(frame: CGRect, multiplyCompositing: Bool = false) {
        super.init(frame: frame, device: MTLCreateSystemDefaultDevice())

        guard let device else { fatalError("No Metal device available") }

        autoResizeDrawable = false
        drawableSize = CGSize(width: 1, height: 1)

        commandQueue = device.makeCommandQueue()
        precondition(commandQueue != nil, "Could not create command queue")

        delegate = self
        colorPixelFormat = .rgba16Float
        colorspace = colorSpace
        clearColor = MTLClearColorMake(1.0, 1.0, 1.0, 1.0)
        preferredFramesPerSecond = 5

        if let layer = self.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
            layer.isOpaque = false
            layer.pixelFormat = .rgba16Float
            if multiplyCompositing {
                layer.compositingFilter = "multiply"
            }
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func screenUpdate(screen: NSScreen) {
        let maxEdr = screen.maximumExtendedDynamicRangeColorComponentValue
        let maxRendered = screen.maximumReferenceExtendedDynamicRangeColorComponentValue
        let factor = max(maxEdr / max(maxRendered, 1.0) - 1.0, 1.0)
        clearColor = MTLClearColorMake(factor, factor, factor, 1.0)
    }

    func draw(in view: MTKView) {
        guard let commandQueue,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }
        renderEncoder.endEncoding()
        if let drawable = view.currentDrawable {
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }

    func setFPS(_ fps: Int) {
        preferredFramesPerSecond = fps
    }
}
