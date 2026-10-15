import AppKit
import Metal
import MetalKit
import QuartzCore

/// Where the renderer's pixels go: memory the CPU and the GPU share, which
/// the GPU then copies to the drawable. The core writes a frame with the one
/// texture message it knows, and this answers it with a plain copy. Writing
/// into a drawable itself re-encodes the GPU-private layout of its texture.
final class NativeFrameBuffer: NSObject {
    let texture: MTLTexture
    let width: Int
    let height: Int
    private let buffer: MTLBuffer
    private let rowBytes: Int

    init?(matching target: MTLTexture) {
        let device = target.device
        let alignment = max(1, device.minimumLinearTextureAlignment(for: target.pixelFormat))
        let rowBytes = (target.width * 4 + alignment - 1) / alignment * alignment
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: target.pixelFormat,
            width: target.width,
            height: target.height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard
            let buffer = device.makeBuffer(
                length: rowBytes * target.height, options: .storageModeShared),
            let texture = buffer.makeTexture(
                descriptor: descriptor, offset: 0, bytesPerRow: rowBytes)
        else {
            return nil
        }
        self.buffer = buffer
        self.texture = texture
        self.rowBytes = rowBytes
        width = target.width
        height = target.height
    }

    func matches(_ target: MTLTexture) -> Bool {
        width == target.width && height == target.height
            && texture.pixelFormat == target.pixelFormat
    }

    @objc(replaceRegion:mipmapLevel:withBytes:bytesPerRow:)
    func replace(
        region: MTLRegion,
        mipmapLevel: Int,
        withBytes bytes: UnsafeRawPointer,
        bytesPerRow: Int
    ) {
        let x = region.origin.x
        let y = region.origin.y
        let columns = region.size.width
        let rows = region.size.height
        guard mipmapLevel == 0, x >= 0, y >= 0, columns > 0, rows > 0,
            x + columns <= width, y + rows <= height, bytesPerRow >= columns * 4
        else {
            return
        }
        let target = buffer.contents() + y * rowBytes + x * 4
        for row in 0..<rows {
            (target + row * rowBytes).copyMemory(
                from: bytes + row * bytesPerRow, byteCount: columns * 4)
        }
    }
}

final class TerminalMetalView: MTKView, CAMetalDisplayLinkDelegate, MTKViewDelegate {
    weak var contextMenuProvider: TerminalContextMenuProvider?
    var renderProvider: ((NativeFrameBuffer, UnsafeMutableRawPointer?) -> Bool)?

    private let commandQueue: MTLCommandQueue
    private let usesSmokeFrameFallback: Bool = {
        let scenario = ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_SCENARIO"]
        return nativeSmokeUsesDeterministicFrames(scenario)
    }()
    private var skiaRenderer: UnsafeMutableRawPointer?
    private var skiaFrameCount = 0
    private var frameBuffer: NativeFrameBuffer?
    /// Draws frames on the GPU when set; frames are drawn on the CPU and
    /// copied otherwise.
    private var gpuRenderer: NativeGpuRenderer?
    /// Asks for frames while the animated backdrop moves.
    private var backdropTimer: Timer?
    private var backdropLastTick: CFTimeInterval?
    private var nextFrameWorkItem: DispatchWorkItem?
    private var frameDisplayLink: CAMetalDisplayLink?
    private var displayRefreshInterval: CFTimeInterval?
    private let frameRequestLock = NSLock()
    private var frameRequestRevision: UInt64 = 0
    private var renderedFrameRequestRevision: UInt64 = 0
    private var lastRenderedTextureSize: (width: Int, height: Int)?
    private var rejectedDrawableCount = 0
    #if SATIN_SMOKE_SCENARIOS
        private var frameRequestInterleaveArmed = false
        private var frameRequestInterleavedRevision: UInt64?
        private var presentedFrameRequestRevision: UInt64 = 0
        private var presentedFrameCount = 0
        private var scheduledAnimationFrameCount = 0
    #endif

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
            fatalError("Metal renderer initialization failed after capability preflight")
        }

        self.commandQueue = commandQueue
        self.skiaRenderer = skiaRenderer
        super.init(frame: frameRect, device: device)
        colorPixelFormat = .bgra8Unorm
        // The frame buffer is blitted into the drawable.
        framebufferOnly = false
        if Self.drawsOnGpu(),
            let gpu = NativeGpuRenderer(device: device, pixelFormat: colorPixelFormat)
        {
            gpuRenderer = gpu
            satinSkiaMetalSetGpu(skiaRenderer, 1)
        }
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

    /// Whether frames are drawn on the GPU: yes unless SATIN_GPU_RENDERER is
    /// 0 or the gpuRenderer default is false.
    static func drawsOnGpu() -> Bool {
        if let value = ProcessInfo.processInfo.environment["SATIN_GPU_RENDERER"] {
            return value != "0"
        }
        return UserDefaults.standard.object(forKey: "gpuRenderer") as? Bool ?? true
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
        configureDisplayRefreshRate(window)
        observeBackdropConditions(window)
        requestFrame()
    }

    private func observeBackdropConditions(_ window: NSWindow) {
        let center = NotificationCenter.default
        let selector = #selector(backdropConditionsChanged(_:))
        for name in [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didChangeBackingPropertiesNotification,
        ] {
            center.removeObserver(self, name: name, object: nil)
            center.addObserver(self, selector: selector, name: name, object: window)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        let reduce = NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        workspace.removeObserver(self, name: reduce, object: nil)
        workspace.addObserver(self, selector: selector, name: reduce, object: nil)
        updateBackdropPixel()
        updateBackdropTimer()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            configureDisplayRefreshRate(window)
        }
        requestFrame()
    }

    private func configureDisplayRefreshRate(_ window: NSWindow) {
        let displayRate = min(120, max(30, window.screen?.maximumFramesPerSecond ?? 60))
        let rate = Float(displayRate)
        displayRefreshInterval = 1 / CFTimeInterval(displayRate)
        frameDisplayLink?.preferredFrameRateRange = CAFrameRateRange(
            minimum: rate,
            maximum: rate,
            preferred: rate
        )
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

        _ = satinSkiaMetalBeginFrame(skiaRenderer)
        var gpuOverflowed = false
        if let gpu = gpuRenderer,
            let frame = frameBuffer(matching: drawable.texture),
            renderProvider?(frame, skiaRenderer) == true,
            let encoded = NativeGpuRenderer.frame(from: skiaRenderer),
            gpu.encode(
                encoded, renderer: skiaRenderer, into: commandBuffer,
                target: drawable.texture, clearColor: clearColor)
        {
            skiaFrameCount += 1
            gpuOverflowed = encoded.overflowed
        } else if gpuRenderer == nil,
            let frame = frameBuffer(matching: drawable.texture),
            renderProvider?(frame, skiaRenderer) == true,
            let blit = commandBuffer.makeBlitCommandEncoder()
        {
            skiaFrameCount += 1
            blit.copy(from: frame.texture, to: drawable.texture)
            blit.endEncoding()
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
        #if SATIN_SMOKE_SCENARIOS
            drawable.addPresentedHandler { [weak self] _ in
                self?.recordPresentedFrame(revision: renderedRequestRevision)
            }
        #endif
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
        if gpuOverflowed {
            // The atlas was emptied while the frame was encoded: draw it again.
            requestFrame()
        }
    }

    /// Draws the experimental animated backdrop under the panes, or stops.
    /// It needs the GPU renderer; it holds still when motion is reduced.
    func setBackdropEnabled(_ enabled: Bool) {
        guard let gpu = gpuRenderer else {
            return
        }
        if enabled {
            if gpu.backdrop == nil {
                gpu.backdrop = NativeGpuRenderer.Backdrop()
                applyBackdropLook()
            }
        } else {
            gpu.backdrop = nil
        }
        updateBackdropPixel()
        updateBackdropTimer()
        requestFrame()
    }

    private var backdropPaper = false

    /// Paints the backdrop as ink on paper, or as the terminal's swirl.
    func setBackdropPaper(_ paper: Bool) {
        backdropPaper = paper
        applyBackdropLook()
        requestFrame()
    }

    private func applyBackdropLook() {
        guard gpuRenderer?.backdrop != nil else {
            return
        }
        let look = NativeGpuRenderer.Backdrop()
        gpuRenderer?.backdrop?.paper = backdropPaper
        gpuRenderer?.backdrop?.colors =
            backdropPaper
            ? [
                SIMD4(0.42, 0.29, 0.77, 1),
                SIMD4(0.12, 0.54, 0.54, 1),
                SIMD4(0.945, 0.91, 0.83, 1),
            ] : look.colors
        updateBackdropPixel()
    }

    /// Floods the backdrop with a color for a moment, as an event lands.
    func pulseBackdrop(_ tint: NSColor) {
        guard gpuRenderer?.backdrop != nil,
            let rgb = tint.usingColorSpace(.sRGB)
        else {
            return
        }
        gpuRenderer?.backdrop?.tint = SIMD4(
            Float(rgb.redComponent), Float(rgb.greenComponent), Float(rgb.blueComponent), 1)
        gpuRenderer?.backdrop?.pulse = 1
        requestFrame()
    }

    var isBackdropEnabled: Bool {
        gpuRenderer?.backdrop != nil
    }

    private func updateBackdropPixel() {
        let scale = Float(window?.backingScaleFactor ?? 2)
        gpuRenderer?.backdrop?.pixel = (backdropPaper ? 1 : 4) * scale
    }

    /// Runs the backdrop's clock at 30 frames a second while the window can
    /// be seen.
    private func updateBackdropTimer() {
        let moving =
            gpuRenderer?.backdrop != nil
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && window?.isVisible == true
            && window?.occlusionState.contains(.visible) == true
        guard moving != (backdropTimer != nil) else {
            return
        }
        backdropTimer?.invalidate()
        backdropTimer = nil
        backdropLastTick = nil
        guard moving else {
            return
        }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.advanceBackdrop()
        }
        RunLoop.main.add(timer, forMode: .common)
        backdropTimer = timer
    }

    private func advanceBackdrop() {
        guard let gpu = gpuRenderer, let backdrop = gpu.backdrop else {
            return
        }
        let now = CACurrentMediaTime()
        if let last = backdropLastTick {
            let elapsed = Float(min(0.1, now - last))
            gpu.backdropTime += elapsed * backdrop.speed * (1 + 3 * backdrop.pulse)
            gpu.backdrop?.pulse = max(0, backdrop.pulse - elapsed / 1.6)
        }
        backdropLastTick = now
        requestFrame()
    }

    @objc private func backdropConditionsChanged(_ notification: Notification) {
        updateBackdropPixel()
        updateBackdropTimer()
    }

    func requestFrame() {
        NativePerformanceRecorder.shared.recordFrameRequest()
        frameRequestLock.lock()
        frameRequestRevision &+= 1
        nextFrameWorkItem?.cancel()
        nextFrameWorkItem = nil
        if usesSmokeFrameFallback {
            needsDisplay = true
            frameRequestLock.unlock()
            return
        }
        frameDisplayLink?.isPaused = false
        frameRequestLock.unlock()
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

    #if SATIN_SMOKE_SCENARIOS
        func resetPresentedFrameCount() {
            frameRequestLock.lock()
            presentedFrameCount = 0
            frameRequestLock.unlock()
        }

        func presentedFrameSnapshot() -> (revision: UInt64, count: Int) {
            frameRequestLock.lock()
            let snapshot = (presentedFrameRequestRevision, presentedFrameCount)
            frameRequestLock.unlock()
            return snapshot
        }

        func resetScheduledAnimationFrameCount() {
            frameRequestLock.lock()
            scheduledAnimationFrameCount = 0
            frameRequestLock.unlock()
        }

        // An animation settles on its own, so a poll can miss it entirely. The
        // renderer counts the frames it scheduled for one instead.
        func scheduledAnimationFrames() -> Int {
            frameRequestLock.lock()
            let count = scheduledAnimationFrameCount
            frameRequestLock.unlock()
            return count
        }
    #endif

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
        let base =
            "requested=\(revisions.requested) rendered=\(revisions.rendered) "
            + "pending=\(revisions.requested == revisions.rendered ? "no" : "yes")"
        #if SATIN_SMOKE_SCENARIOS
            let presented = presentedFrameSnapshot()
            return base + " presented=\(presented.revision) count=\(presented.count)"
        #else
            return base
        #endif
    }

    func frameRequestRevisionSnapshot() -> (requested: UInt64, rendered: UInt64) {
        frameRequestRevisions()
    }

    #if SATIN_SMOKE_SCENARIOS
        func armFrameRequestInterleaveForSmoke() {
            frameRequestLock.lock()
            frameRequestInterleaveArmed = true
            frameRequestInterleavedRevision = nil
            frameRequestLock.unlock()
        }

        func interleavedFrameRequestRevisionForSmoke() -> UInt64? {
            frameRequestLock.lock()
            let revision = frameRequestInterleavedRevision
            frameRequestLock.unlock()
            return revision
        }
    #endif

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
        let delayMs = satinSkiaMetalNextFrameDelayMs(skiaRenderer)
        frameRequestLock.lock()
        #if SATIN_SMOKE_SCENARIOS
            if delayMs != UInt64.max {
                scheduledAnimationFrameCount += 1
            }
        #endif
        nextFrameWorkItem?.cancel()
        nextFrameWorkItem = nil
        renderedFrameRequestRevision = max(
            renderedFrameRequestRevision,
            renderedRequestRevision
        )
        if frameRequestRevision != renderedRequestRevision {
            if usesSmokeFrameFallback {
                needsDisplay = true
            } else {
                frameDisplayLink?.isPaused = false
            }
            frameRequestLock.unlock()
            return
        }
        #if SATIN_SMOKE_SCENARIOS
            interleaveFrameRequestForSmoke()
        #endif
        guard delayMs != UInt64.max else {
            if !usesSmokeFrameFallback {
                frameDisplayLink?.isPaused = true
            }
            frameRequestLock.unlock()
            return
        }
        if usesSmokeFrameFallback {
            frameRequestLock.unlock()
            commandBuffer.addCompletedHandler { [weak self] _ in
                let milliseconds = Int(min(delayMs, UInt64(Int.max)))
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                    self?.requestFrame()
                }
            }
            return
        }
        guard delayMs > 0 else {
            frameRequestLock.unlock()
            requestFrame()
            return
        }

        frameDisplayLink?.isPaused = true
        let workItem = DispatchWorkItem { [weak self] in
            self?.requestFrame()
        }
        nextFrameWorkItem = workItem
        frameRequestLock.unlock()
        let milliseconds = Int(min(delayMs, UInt64(Int.max)))
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(milliseconds),
            execute: workItem
        )
    }

    #if SATIN_SMOKE_SCENARIOS
        private func recordPresentedFrame(revision: UInt64) {
            frameRequestLock.lock()
            presentedFrameRequestRevision = max(presentedFrameRequestRevision, revision)
            presentedFrameCount += 1
            frameRequestLock.unlock()
        }

        private func interleaveFrameRequestForSmoke() {
            guard frameRequestInterleaveArmed else {
                return
            }
            frameRequestInterleaveArmed = false
            let started = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                started.signal()
                guard let self else {
                    return
                }
                self.requestFrame()
                let revision = self.frameRequestRevisionSnapshot().requested
                self.frameRequestLock.lock()
                self.frameRequestInterleavedRevision = revision
                self.frameRequestLock.unlock()
            }
            started.wait()
            Thread.sleep(forTimeInterval: 0.01)
        }
    #endif

    private func currentFrameRequestRevision() -> UInt64 {
        frameRequestRevisions().requested
    }

    private func frameRequestRevisions() -> (requested: UInt64, rendered: UInt64) {
        frameRequestLock.lock()
        let revisions = (frameRequestRevision, renderedFrameRequestRevision)
        frameRequestLock.unlock()
        return revisions
    }

    private func frameBuffer(matching target: MTLTexture) -> NativeFrameBuffer? {
        if let frameBuffer, frameBuffer.matches(target) {
            return frameBuffer
        }
        frameBuffer = NativeFrameBuffer(matching: target)
        return frameBuffer
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
        let backingSize = convertToBacking(bounds.size)
        return (
            max(1, Int(abs(backingSize.width).rounded())),
            max(1, Int(abs(backingSize.height).rounded()))
        )
    }

    private func roundedSize(_ size: CGSize) -> (width: Int, height: Int) {
        (max(1, Int(size.width.rounded())), max(1, Int(size.height.rounded())))
    }
}
