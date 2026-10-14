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
            sampler nearest [[sampler(0)]]
        ) {
            float4 color = float4(in.color.rgb * in.color.a, in.color.a);
            if (in.mode == 0) {
                return color;
            }
            float4 sampled = texture.sample(nearest, in.uv);
            if (in.mode == 1) {
                return color * sampled.a;
            }
            return sampled * in.color.a;
        }
        """

    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var atlas: MTLTexture?
    private var atlasGeneration = -1
    private var pictures: [UInt64: (texture: MTLTexture, lastFrame: Int)] = [:]
    private var frameNumber = 0

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
            let vertexFunction = library.makeFunction(name: "satin_gpu_vertex"),
            let fragmentFunction = library.makeFunction(name: "satin_gpu_fragment")
        else {
            return nil
        }
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
            let sampler = device.makeSamplerState(descriptor: samplerDescriptor)
        else {
            return nil
        }
        self.device = device
        self.pipeline = pipeline
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
