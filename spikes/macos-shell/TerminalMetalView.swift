import AppKit
import Metal
import MetalKit
import QuartzCore

final class TerminalMetalView: MTKView, CAMetalDisplayLinkDelegate, MTKViewDelegate {
    weak var contextMenuProvider: TerminalContextMenuProvider?
    var renderProvider: ((MTLTexture, UnsafeMutableRawPointer?) -> Bool)?

    private let commandQueue: MTLCommandQueue
    private let usesSmokeFrameFallback: Bool = {
        let scenario = ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_SCENARIO"]
        return nativeSmokeUsesDeterministicFrames(scenario)
    }()
    private var skiaRenderer: UnsafeMutableRawPointer?
    private var skiaFrameCount = 0
    private var nextFrameWorkItem: DispatchWorkItem?
    private var frameDisplayLink: CAMetalDisplayLink?
    private var displayRefreshInterval: CFTimeInterval?
    private let frameRequestLock = NSLock()
    private var frameRequestRevision: UInt64 = 0
    private var renderedFrameRequestRevision: UInt64 = 0
    private var lastRenderedTextureSize: (width: Int, height: Int)?
    private var rejectedDrawableCount = 0

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    init(frame frameRect: NSRect) {
        guard let device = MTLCreateSystemDefaultDevice(),
            let commandQueue = device.makeCommandQueue(),
            let skiaRenderer = satinSkiaMetalCreate(
                metalObjectPointer(device),
                metalObjectPointer(commandQueue)
            )
        else {
            fatalError("Metal/Skia initialization failed after capability preflight")
        }

        self.commandQueue = commandQueue
        self.skiaRenderer = skiaRenderer
        super.init(frame: frameRect, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.078, green: 0.086, blue: 0.102, alpha: 1.0)
        delegate = self
        if usesSmokeFrameFallback {
            enableSetNeedsDisplay = true
            isPaused = true
            needsDisplay = true
            return
        }
        enableSetNeedsDisplay = false
        isPaused = true
        guard let metalLayer = layer as? CAMetalLayer else {
            fatalError("MTKView did not create a CAMetalLayer")
        }
        let displayLink = CAMetalDisplayLink(metalLayer: metalLayer)
        displayLink.delegate = self
        displayLink.preferredFrameLatency = 1
        displayLink.isPaused = true
        displayLink.add(to: .main, forMode: .common)
        frameDisplayLink = displayLink
    }

    static func isAvailable() -> Bool {
        guard let device = MTLCreateSystemDefaultDevice(),
            let commandQueue = device.makeCommandQueue(),
            let renderer = satinSkiaMetalCreate(
                metalObjectPointer(device),
                metalObjectPointer(commandQueue)
            )
        else {
            return false
        }
        satinSkiaMetalDestroy(renderer)
        return true
    }

    deinit {
        nextFrameWorkItem?.cancel()
        frameDisplayLink?.invalidate()
        satinSkiaMetalDestroy(skiaRenderer)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if usesSmokeFrameFallback {
            requestFrame()
            return
        }
        guard let window else {
            frameDisplayLink?.isPaused = true
            return
        }
        let displayRate = min(120, max(30, window.screen?.maximumFramesPerSecond ?? 60))
        let rate = Float(displayRate)
        displayRefreshInterval = 1 / CFTimeInterval(displayRate)
        frameDisplayLink?.preferredFrameRateRange = CAFrameRateRange(
            minimum: rate,
            maximum: rate,
            preferred: rate
        )
        requestFrame()
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenuProvider?.terminalContextMenu(tabIndex: nil) else {
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    func metalDisplayLink(
        _ link: CAMetalDisplayLink,
        needsUpdate update: CAMetalDisplayLink.Update
    ) {
        renderFrame(
            update.drawable,
            displayLink: link,
            targetTimestamp: update.targetTimestamp,
            targetPresentationTimestamp: update.targetPresentationTimestamp
        )
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        if let metalLayer = view.layer as? CAMetalLayer,
            roundedSize(metalLayer.drawableSize) != roundedSize(size)
        {
            metalLayer.drawableSize = size
        }
        requestFrame()
    }

    func draw(in view: MTKView) {
        guard usesSmokeFrameFallback, let drawable = currentDrawable else {
            return
        }
        renderFrame(
            drawable,
            displayLink: nil,
            targetTimestamp: nil,
            targetPresentationTimestamp: nil
        )
    }

    private func renderFrame(
        _ drawable: CAMetalDrawable,
        displayLink: CAMetalDisplayLink?,
        targetTimestamp: CFTimeInterval?,
        targetPresentationTimestamp: CFTimeInterval?
    ) {
        guard prepareDrawableForRendering(drawable.texture) else {
            requestFrame()
            return
        }
        let renderedRequestRevision = currentFrameRequestRevision()
        let performanceRecorder = NativePerformanceRecorder.shared
        let frameStartedAt = performanceRecorder.isEnabled ? CACurrentMediaTime() : 0
        let performanceToken = performanceRecorder.beginFrame(
            at: frameStartedAt,
            targetTimestamp: targetTimestamp,
            targetPresentationTimestamp: targetPresentationTimestamp,
            expectedInterval: displayRefreshInterval
        )
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            displayLink?.isPaused = true
            return
        }

        if renderProvider?(drawable.texture, skiaRenderer) == true {
            skiaFrameCount += 1
        } else {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = drawable.texture
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].storeAction = .store
            descriptor.colorAttachments[0].clearColor = clearColor
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
            encoder?.endEncoding()
        }
        let rendererFinishedAt = performanceToken == nil ? 0 : CACurrentMediaTime()
        updateFrameScheduling(
            commandBuffer,
            renderedRequestRevision: renderedRequestRevision
        )
        commandBuffer.present(drawable)
        let committedAt = performanceToken == nil ? 0 : CACurrentMediaTime()
        performanceRecorder.observeCommandBuffer(
            commandBuffer,
            drawable: drawable,
            token: performanceToken,
            committedAt: committedAt
        )
        commandBuffer.commit()
        let submissionFinishedAt = performanceToken == nil ? 0 : CACurrentMediaTime()
        performanceRecorder.recordFrameSubmission(
            performanceToken,
            rendererFinishedAt: rendererFinishedAt,
            committedAt: submissionFinishedAt
        )
    }

    func requestFrame() {
        NativePerformanceRecorder.shared.recordFrameRequest()
        markFrameRequested()
        nextFrameWorkItem?.cancel()
        nextFrameWorkItem = nil
        if usesSmokeFrameFallback {
            needsDisplay = true
            return
        }
        frameDisplayLink?.isPaused = false
    }

    func hasSkiaFrames() -> Bool {
        skiaFrameCount > 0
    }

    func skiaFrames() -> Int {
        skiaFrameCount
    }

    func resetSkiaFrameCount() {
        skiaFrameCount = 0
    }

    func resetResizeDiagnostics() {
        lastRenderedTextureSize = nil
        rejectedDrawableCount = 0
    }

    func resizeDiagnosticsSummary() -> String {
        let viewSize = expectedDrawableSize()
        let mtkSize = roundedSize(drawableSize)
        let layerSize = roundedSize((layer as? CAMetalLayer)?.drawableSize ?? .zero)
        let textureSize = lastRenderedTextureSize ?? (0, 0)
        return "view=\(viewSize.width)x\(viewSize.height) "
            + "mtk=\(mtkSize.width)x\(mtkSize.height) "
            + "layer=\(layerSize.width)x\(layerSize.height) "
            + "texture=\(textureSize.width)x\(textureSize.height) "
            + "rejected=\(rejectedDrawableCount)"
    }

    func frameRequestDiagnosticsSummary() -> String {
        let revisions = frameRequestRevisions()
        return "requested=\(revisions.requested) rendered=\(revisions.rendered) "
            + "pending=\(revisions.requested == revisions.rendered ? "no" : "yes")"
    }

    func hasPendingFrameRequest() -> Bool {
        let revisions = frameRequestRevisions()
        return revisions.requested != revisions.rendered
    }

    func drawableSizesMatchView() -> Bool {
        guard let lastRenderedTextureSize else {
            return false
        }
        let expected = expectedDrawableSize()
        guard roundedSize(drawableSize) == expected,
            let metalLayer = layer as? CAMetalLayer
        else {
            return false
        }
        return roundedSize(metalLayer.drawableSize) == expected
            && lastRenderedTextureSize == expected
    }

    func hasPendingSkiaFrame() -> Bool {
        satinSkiaMetalNeedsAnimationFrame(skiaRenderer) != 0
    }

    func pendingSkiaFrameDelayMs() -> UInt64 {
        satinSkiaMetalNextFrameDelayMs(skiaRenderer)
    }

    func forgetRuntime(_ runtime: UnsafeMutableRawPointer?) {
        satinSkiaMetalForgetRuntime(skiaRenderer, runtime)
    }

    func setFontFamily(_ family: String) {
        family.withCString { value in
            _ = satinSkiaMetalSetFontFamily(skiaRenderer, value)
        }
        requestFrame()
    }

    private func updateFrameScheduling(
        _ commandBuffer: MTLCommandBuffer,
        renderedRequestRevision: UInt64
    ) {
        nextFrameWorkItem?.cancel()
        nextFrameWorkItem = nil
        markFrameRequestRendered(renderedRequestRevision)
        if currentFrameRequestRevision() != renderedRequestRevision {
            if usesSmokeFrameFallback {
                needsDisplay = true
            } else {
                frameDisplayLink?.isPaused = false
            }
            return
        }
        let delayMs = satinSkiaMetalNextFrameDelayMs(skiaRenderer)
        guard delayMs != UInt64.max else {
            if !usesSmokeFrameFallback {
                frameDisplayLink?.isPaused = true
            }
            return
        }
        if usesSmokeFrameFallback {
            commandBuffer.addCompletedHandler { [weak self] _ in
                let milliseconds = Int(min(delayMs, UInt64(Int.max)))
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                    self?.requestFrame()
                }
            }
            return
        }
        guard delayMs > 0 else {
            requestFrame()
            return
        }

        frameDisplayLink?.isPaused = true
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.nextFrameWorkItem = nil
            self.requestFrame()
        }
        nextFrameWorkItem = workItem
        let milliseconds = Int(min(delayMs, UInt64(Int.max)))
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(milliseconds),
            execute: workItem
        )
    }

    private func markFrameRequested() {
        frameRequestLock.lock()
        frameRequestRevision &+= 1
        frameRequestLock.unlock()
    }

    private func currentFrameRequestRevision() -> UInt64 {
        frameRequestRevisions().requested
    }

    private func markFrameRequestRendered(_ revision: UInt64) {
        frameRequestLock.lock()
        renderedFrameRequestRevision = max(renderedFrameRequestRevision, revision)
        frameRequestLock.unlock()
    }

    private func frameRequestRevisions() -> (requested: UInt64, rendered: UInt64) {
        frameRequestLock.lock()
        let revisions = (frameRequestRevision, renderedFrameRequestRevision)
        frameRequestLock.unlock()
        return revisions
    }

    private func prepareDrawableForRendering(_ texture: MTLTexture) -> Bool {
        let textureSize = (texture.width, texture.height)
        if textureSize != expectedDrawableSize() {
            rejectedDrawableCount += 1
            return false
        }
        lastRenderedTextureSize = textureSize
        return true
    }

    private func expectedDrawableSize() -> (width: Int, height: Int) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        return (
            max(1, Int((bounds.width * scale).rounded())),
            max(1, Int((bounds.height * scale).rounded()))
        )
    }

    private func roundedSize(_ size: CGSize) -> (width: Int, height: Int) {
        (max(1, Int(size.width.rounded())), max(1, Int(size.height.rounded())))
    }
}
