import CoreGraphics
import Foundation
import Metal

/// Draws the triangles the core encodes for a frame: quads of a color, glyphs
/// from the core's atlas, and images, each draw inside its clip.
final class NativeGpuRenderer {
    /// What satin_skia_metal_gpu_frame writes: twelve Int64.
    struct Frame {
        let vertices: UnsafeRawPointer?
        let vertexCount: Int
        let draws: UnsafeRawPointer?
        let drawCount: Int
        let atlas: UnsafeRawPointer?
        let atlasSide: Int
        let dirty: (x: Int, y: Int, width: Int, height: Int)
        let generation: Int
        let overflowed: Bool

        init(_ fields: [Int64]) {
            vertices = UnsafeRawPointer(bitPattern: Int(fields[0]))
            vertexCount = Int(fields[1])
            draws = UnsafeRawPointer(bitPattern: Int(fields[2]))
            drawCount = Int(fields[3])
            atlas = UnsafeRawPointer(bitPattern: Int(fields[4]))
            atlasSide = Int(fields[5])
            dirty = (Int(fields[6]), Int(fields[7]), Int(fields[8]), Int(fields[9]))
            generation = Int(fields[10])
            overflowed = fields[11] != 0
        }
    }

    static let vertexStride = 24
    static let drawStride = 64

    private static let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct GpuVertex {
            packed_float2 position;
            packed_float2 uv;
            uint color;
            uint mode;
        };

        struct Varyings {
            float4 position [[position]];
            float2 uv;
            float4 color;
            uint mode [[flat]];
        };

        vertex Varyings satin_gpu_vertex(
            uint id [[vertex_id]],
            const device GpuVertex *vertices [[buffer(0)]],
            constant float2 &size [[buffer(1)]]
        ) {
            GpuVertex v = vertices[id];
            Varyings out;
            out.position = float4(
                v.position[0] / size.x * 2.0 - 1.0,
                1.0 - v.position[1] / size.y * 2.0,
                0.0,
                1.0);
            out.uv = float2(v.uv[0], v.uv[1]);
            out.color = unpack_unorm4x8_to_float(v.color);
            out.mode = v.mode;
            return out;
        }

        fragment float4 satin_gpu_fragment(
            Varyings in [[stage_in]],
            texture2d<float> texture [[texture(0)]],
            sampler nearest [[sampler(0)]],
            texture2d<float> backdrop [[texture(1)]],
            constant float &veil [[buffer(0)]]
        ) {
            float4 color = float4(in.color.rgb * in.color.a, in.color.a);
            if (in.mode == 0) {
                return color;
            }
            if (in.mode == 4) {
                // The pane's own background over the backdrop, as one
                // opaque fill however many of them are drawn.
                if (veil < 0.0) {
                    return color;
                }
                float4 under = backdrop.read(uint2(in.position.xy));
                return float4(mix(under.rgb, in.color.rgb, veil), 1.0);
            }
            float4 sampled = texture.sample(nearest, in.uv);
            if (in.mode == 1) {
                return color * sampled.a;
            }
            return sampled * in.color.a;
        }

        struct BackdropUniforms {
            float2 size;
            float time;
            float swirl;
            float pixel;
            float vivid;
            float pulse;
            float paper;
            float4 first;
            float4 second;
            float4 third;
            float4 tint;
        };

        struct BackdropVaryings {
            float4 position [[position]];
        };

        vertex BackdropVaryings satin_backdrop_vertex(uint id [[vertex_id]]) {
            float2 corner = float2((id << 1) & 2, id & 2);
            BackdropVaryings out;
            out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
            return out;
        }

        // Swirling paint: the coordinates are turned about the middle, then
        // folded over themselves a few times, and their length picks among
        // three colors.
        fragment float4 satin_backdrop_fragment(
            BackdropVaryings in [[stage_in]],
            constant BackdropUniforms &u [[buffer(0)]]
        ) {
            float2 cell = floor(in.position.xy / u.pixel) * u.pixel;
            cell.y = u.size.y - cell.y;
            float2 uv = (cell - 0.5 * u.size) / length(u.size);
            float r = length(uv);
            float a = atan2(uv.y, uv.x) + 0.25 * u.time * u.swirl
                - (u.swirl + 1.5 * u.pulse) * 4.0 * r * (1.0 - r);
            uv = float2(cos(a), sin(a)) * r * 26.0;
            float2 w = float2(uv.x + uv.y);
            for (int i = 0; i < 5; i++) {
                w += sin(max(uv.x, uv.y)) + uv;
                uv += 0.5 * float2(cos(5.11 + 0.35 * w.y + u.time * 0.13), sin(w.x - 0.11 * u.time));
                uv -= cos(uv.x + uv.y) - sin(uv.x * 0.71 - uv.y);
            }
            float m = 1.4 + 0.6 * u.vivid;
            float paint = clamp(length(uv) * 0.035 * m, 0.0, 2.0);
            float p1 = max(0.0, 1.0 - m * abs(1.0 - paint));
            float p2 = max(0.0, 1.0 - m * abs(paint));
            float p3 = 1.0 - min(1.0, p1 + p2);
            float3 color = u.first.rgb * p1 + u.second.rgb * p2 + u.third.rgb * p3;
            if (u.paper > 0.5) {
                // Paper: the same currents as faint ink soaked into cream
                // stock, with the grain of its fibres.
                float2 fibre = floor(in.position.xy);
                float grain = fract(sin(dot(fibre, float2(12.9898, 78.233))) * 43758.5453);
                float3 sheet = u.third.rgb;
                sheet = mix(sheet, u.first.rgb, 0.17 * clamp(p1, 0.0, 1.0));
                sheet = mix(sheet, u.second.rgb, 0.15 * clamp(p2, 0.0, 1.0));
                sheet *= 0.985 + 0.03 * grain;
                sheet = mix(sheet, u.tint.rgb, 0.3 * u.pulse * (0.4 + p1));
                return float4(sheet, 1.0);
            }
            color = mix(u.third.rgb, color, clamp(u.vivid, 0.0, 1.5) / 1.5 + 0.2);
            // A pulse floods the paint with the tint of what just happened.
            color = mix(color, u.tint.rgb * (0.55 + 0.6 * p1), 0.6 * u.pulse);
            return float4(color, 1.0);
        }
        """

    /// The backdrop's look; what the experimental animated backdrop draws
    /// under the panes, whose own background lets it through.
    struct Backdrop {
        var swirl: Float = 0.9
        var speed: Float = 0.6
        var pixel: Float = 4
        var vivid: Float = 0.8
        /// How much of the panes' background stays over the backdrop.
        var veil: Float = 0.72
        var colors: [SIMD4<Float>] = [
            SIMD4(0.482, 0.310, 0.839, 1),
            SIMD4(0.122, 0.541, 0.541, 1),
            SIMD4(0.071, 0.051, 0.110, 1),
        ]
        /// How strongly an event's tint shows, from 1 when it lands to 0.
        var pulse: Float = 0
        /// Ink soaking into paper, rather than swirling paint.
        var paper = false
        var tint = SIMD4<Float>(0, 0, 0, 1)
    }

    private struct BackdropUniforms {
        var size: SIMD2<Float>
        var time: Float
        var swirl: Float
        var pixel: Float
        var vivid: Float
        var pulse: Float
        var paper: Float
        var first: SIMD4<Float>
        var second: SIMD4<Float>
        var third: SIMD4<Float>
        var tint: SIMD4<Float>
    }

    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let backdropPipeline: MTLRenderPipelineState
    /// Drawn under the panes when set.
    var backdrop: Backdrop?
    /// The backdrop's clock, in seconds of its own speed; the host advances it.
    var backdropTime: Float = 0
    /// What the backdrop drew this frame, read by the panes' background.
    private var backdropTexture: MTLTexture?
    private let sampler: MTLSamplerState
    private var atlas: MTLTexture?
    private var atlasGeneration = -1
    private var pictures: [UInt64: (texture: MTLTexture, lastFrame: Int)] = [:]
    private var frameNumber = 0

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
            let vertexFunction = library.makeFunction(name: "satin_gpu_vertex"),
            let fragmentFunction = library.makeFunction(name: "satin_gpu_fragment"),
            let backdropVertex = library.makeFunction(name: "satin_backdrop_vertex"),
            let backdropFragment = library.makeFunction(name: "satin_backdrop_fragment")
        else {
            return nil
        }
        let backdropDescriptor = MTLRenderPipelineDescriptor()
        backdropDescriptor.vertexFunction = backdropVertex
        backdropDescriptor.fragmentFunction = backdropFragment
        backdropDescriptor.colorAttachments[0]?.pixelFormat = pixelFormat
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        guard let attachment = descriptor.colorAttachments[0] else {
            return nil
        }
        attachment.pixelFormat = pixelFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .nearest
        samplerDescriptor.magFilter = .nearest
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
            let backdropPipeline = try? device.makeRenderPipelineState(
                descriptor: backdropDescriptor),
            let sampler = device.makeSamplerState(descriptor: samplerDescriptor)
        else {
            return nil
        }
        self.device = device
        self.pipeline = pipeline
        self.backdropPipeline = backdropPipeline
        self.sampler = sampler
    }

    /// Reads the frame the core encoded since begin_frame; nil when it encoded none.
    static func frame(from renderer: UnsafeMutableRawPointer?) -> Frame? {
        var fields = [Int64](repeating: 0, count: 12)
        let encoded = fields.withUnsafeMutableBytes { bytes in
            satinSkiaMetalGpuFrame(renderer, bytes.baseAddress)
        }
        return encoded == 0 ? nil : Frame(fields)
    }

    /// Encodes frame into target. False when it could not.
    func encode(
        _ frame: Frame,
        renderer: UnsafeMutableRawPointer?,
        into commandBuffer: MTLCommandBuffer,
        target: MTLTexture,
        clearColor: MTLClearColor
    ) -> Bool {
        frameNumber += 1
        guard updateAtlas(frame, renderer: renderer) else {
            return false
        }
        var veil: Float = -1
        if let backdrop, let texture = backdropTarget(matching: target) {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                drawBackdrop(backdrop, encoder: encoder, target: texture)
                encoder.endEncoding()
                // A pulse also thins the panes' background so it shows.
                veil = backdrop.veil * (1 - 0.3 * backdrop.pulse)
            }
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clearColor
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return false
        }
        defer { encoder.endEncoding() }
        guard frame.vertexCount > 0, let vertices = frame.vertices, let draws = frame.draws,
            let buffer = device.makeBuffer(
                bytes: vertices,
                length: frame.vertexCount * Self.vertexStride,
                options: .storageModeShared)
        else {
            return true
        }
        var size = SIMD2<Float>(Float(target.width), Float(target.height))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&size, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentBytes(&veil, length: MemoryLayout<Float>.size, index: 0)
        if veil >= 0, let backdropTexture {
            encoder.setFragmentTexture(backdropTexture, index: 1)
        } else if let atlas {
            // Unread when there is no backdrop, but a texture must be bound.
            encoder.setFragmentTexture(atlas, index: 1)
        }
        for index in 0..<frame.drawCount {
            let draw = draws + index * Self.drawStride
            let first = Int(draw.load(fromByteOffset: 0, as: Int64.self))
            let count = Int(draw.load(fromByteOffset: 8, as: Int64.self))
            let clipX = Int(draw.load(fromByteOffset: 16, as: Int64.self))
            let clipY = Int(draw.load(fromByteOffset: 24, as: Int64.self))
            let clipWidth = Int(draw.load(fromByteOffset: 32, as: Int64.self))
            let clipHeight = Int(draw.load(fromByteOffset: 40, as: Int64.self))
            let picture = UInt(draw.load(fromByteOffset: 48, as: UInt64.self))
            let serial = draw.load(fromByteOffset: 56, as: UInt64.self)
            let x = min(max(clipX, 0), target.width)
            let y = min(max(clipY, 0), target.height)
            let width = min(max(clipWidth, 0), target.width - x)
            let height = min(max(clipHeight, 0), target.height - y)
            guard count > 0, first >= 0, first + count <= frame.vertexCount, width > 0,
                height > 0
            else {
                continue
            }
            let texture = picture == 0 ? atlas : pictureTexture(picture, serial: serial)
            guard let texture else {
                continue
            }
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setScissorRect(MTLScissorRect(x: x, y: y, width: width, height: height))
            encoder.drawPrimitives(type: .triangle, vertexStart: first, vertexCount: count)
        }
        pictures = pictures.filter { frameNumber - $0.value.lastFrame < 120 }
        return true
    }

    private func backdropTarget(matching target: MTLTexture) -> MTLTexture? {
        if let backdropTexture, backdropTexture.width == target.width,
            backdropTexture.height == target.height
        {
            return backdropTexture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: target.pixelFormat, width: target.width, height: target.height,
            mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        backdropTexture = device.makeTexture(descriptor: descriptor)
        return backdropTexture
    }

    private func drawBackdrop(
        _ backdrop: Backdrop, encoder: MTLRenderCommandEncoder, target: MTLTexture
    ) {
        var uniforms = BackdropUniforms(
            size: SIMD2(Float(target.width), Float(target.height)),
            time: backdropTime,
            swirl: backdrop.swirl,
            pixel: backdrop.pixel,
            vivid: backdrop.vivid,
            pulse: backdrop.pulse,
            paper: backdrop.paper ? 1 : 0,
            first: backdrop.colors[0],
            second: backdrop.colors[1],
            third: backdrop.colors[2],
            tint: backdrop.tint)
        encoder.setRenderPipelineState(backdropPipeline)
        encoder.setFragmentBytes(
            &uniforms, length: MemoryLayout<BackdropUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    private func updateAtlas(_ frame: Frame, renderer: UnsafeMutableRawPointer?) -> Bool {
        let side = frame.atlasSide
        if atlas == nil || atlas?.width != side {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: side, height: side, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = .shaderRead
            guard let made = device.makeTexture(descriptor: descriptor) else {
                return false
            }
            atlas = made
            atlasGeneration = -1
        }
        guard let atlas, let pixels = frame.atlas else {
            return true
        }
        var region = frame.dirty
        if atlasGeneration != frame.generation {
            region = (0, 0, side, side)
            atlasGeneration = frame.generation
        }
        if region.width > 0, region.height > 0 {
            let rowBytes = side * 4
            atlas.replace(
                region: MTLRegionMake2D(region.x, region.y, region.width, region.height),
                mipmapLevel: 0,
                withBytes: pixels + region.y * rowBytes + region.x * 4,
                bytesPerRow: rowBytes)
        }
        satinSkiaMetalGpuTookAtlas(renderer)
        return true
    }

    /// The texture of the CGImage at address, made the first time serial is drawn.
    private func pictureTexture(_ address: UInt, serial: UInt64) -> MTLTexture? {
        if let held = pictures[serial] {
            pictures[serial] = (held.texture, frameNumber)
            return held.texture
        }
        guard let pointer = UnsafeRawPointer(bitPattern: address) else {
            return nil
        }
        let image = Unmanaged<CGImage>.fromOpaque(pointer).takeUnretainedValue()
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
            // The CPU backend draws images in the device's RGB space.
            let space = Optional(CGColorSpaceCreateDeviceRGB()),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue),
            let data = context.data
        else {
            return nil
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data,
            bytesPerRow: width * 4)
        pictures[serial] = (texture, frameNumber)
        return texture
    }
}

/// The shaders compile and the pipeline is made on this machine's GPU.
func runNativeGpuRendererSelfTests() -> Bool {
    guard let device = MTLCreateSystemDefaultDevice() else {
        return true
    }
    return NativeGpuRenderer(device: device, pixelFormat: .bgra8Unorm) != nil
        && NativeGpuRenderer.vertexStride == 24 && NativeGpuRenderer.drawStride == 64
}
