// Renders a terminal into a CAMetalLayer drawable through the same exports
// the app calls, and reads the drawable back: no window, no screen capture.
//
//   scripts/test-drawable   (builds and runs this)
//
// Prints how many pixels differ from the background with framebufferOnly
// off, which is what the app needs, and exits 1 when nothing was drawn.
import Foundation
import Metal
import ImageIO
import QuartzCore
import UniformTypeIdentifiers

@_silgen_name("satin_runtime_create_external")
func runtimeCreate(_ rows: UInt16, _ cols: UInt16, _ pw: UInt16, _ ph: UInt16) -> UnsafeMutableRawPointer?
@_silgen_name("satin_runtime_tmux_feed_pane")
func runtimeFeed(_ pane: UnsafeMutableRawPointer?, _ bytes: UnsafePointer<UInt8>?, _ len: Int) -> UInt8
@_silgen_name("satin_runtime_destroy")
func runtimeDestroy(_ handle: UnsafeMutableRawPointer?)
@_silgen_name("satin_skia_metal_create")
func rendererCreate(_ device: UnsafeMutableRawPointer?, _ queue: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
@_silgen_name("satin_skia_metal_destroy")
func rendererDestroy(_ handle: UnsafeMutableRawPointer?)
@_silgen_name("satin_skia_metal_begin_frame")
func rendererBeginFrame(_ handle: UnsafeMutableRawPointer?) -> UInt8
@_silgen_name("satin_skia_metal_render_terminal")
func renderTerminal(
    _ renderer: UnsafeMutableRawPointer?, _ runtime: UnsafeMutableRawPointer?,
    _ texture: UnsafeMutableRawPointer?, _ width: Int32, _ height: Int32,
    _ originX: Float, _ originY: Float, _ contentWidth: Float, _ contentHeight: Float,
    _ cellWidth: Float, _ cellHeight: Float, _ clear: UInt8, _ preedit: UnsafePointer<CChar>?
) -> UInt8

let width = 400
let height = 120
guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
    print("no Metal device")
    exit(2)
}
let layer = CAMetalLayer()
layer.device = device
layer.pixelFormat = .bgra8Unorm
layer.framebufferOnly = ProcessInfo.processInfo.environment["FRAMEBUFFER_ONLY"] == "1"
layer.drawableSize = CGSize(width: width, height: height)
guard let drawable = layer.nextDrawable() else {
    print("no drawable")
    exit(2)
}
let runtime = runtimeCreate(6, 40, UInt16(width), UInt16(height))
let text = Array("fn main() -> u8 { a != b; } \u{1b}[41m red \u{1b}[0m 日本語 \u{e0b0} 👨‍👩‍👧".utf8)
_ = runtimeFeed(runtime, text, text.count)
let renderer = rendererCreate(
    Unmanaged.passUnretained(device).toOpaque(), Unmanaged.passUnretained(queue).toOpaque())
_ = rendererBeginFrame(renderer)
let rendered = renderTerminal(
    renderer, runtime, Unmanaged.passUnretained(drawable.texture).toOpaque(),
    Int32(width), Int32(height), 0, 0, Float(width), Float(height), 10, 20, 1, nil)

var pixels = [UInt8](repeating: 0, count: width * height * 4)
drawable.texture.getBytes(
    &pixels, bytesPerRow: width * 4,
    from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
let background = Array(pixels[(width * (height - 1) * 4)..<(width * (height - 1) * 4 + 4)])
var drawn = 0
var red = 0
for index in stride(from: 0, to: pixels.count, by: 4) {
    let pixel = Array(pixels[index..<index + 4])
    if pixel != background { drawn += 1 }
    if Int(pixel[2]) - Int(pixel[1]) > 60 && Int(pixel[2]) - Int(pixel[0]) > 60 { red += 1 }
}
// The text takes two rows of 20 pixels: everything drawn should be in them.
var belowFirstRow = 0
for index in stride(from: width * 40 * 4, to: pixels.count, by: 4)
where Array(pixels[index..<index + 4]) != background {
    belowFirstRow += 1
}
print("rendered=\(rendered) drawn=\(drawn) red=\(red) below-text=\(belowFirstRow)")
if let path = ProcessInfo.processInfo.environment["DRAWABLE_PNG"] {
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}
rendererDestroy(renderer)
runtimeDestroy(runtime)
exit(rendered == 1 && drawn > 500 && red > 500 && belowFirstRow < 50 ? 0 : 1)
