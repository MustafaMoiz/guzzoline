// Drawing a theme natively: shapes and type painted with Core Graphics into textures, and Metal
// passes (ports of the themes' WebGL shaders) that turn them into the Touch Bar's pixels.
//
// Shaders work in linear light and encode sRGB themselves, and the drawable isn't an sRGB
// format, so blending happens on encoded values, as it does in the browser.

import AppKit
import CoreText
import Metal
import QuartzCore
import simd

let barWidth = 2008 // the 13-inch MacBook Pro's Touch Bar, in pixels
let barHeight = 60

// A native theme draws into its layer whenever it's asked to, laid out for the width it's
// given (the whole bar, or what the crew of sessions leaves).
protocol NativeTheme: AnyObject {
  var layer: CALayer { get }
  var busy: Bool { get } // something is moving, so it wants the faster frame rate
  func render(_ state: BarState, dt: Double, t: Double)
  func tap()
}

extension NativeTheme {
  func tap() {}
}

// A Core Graphics bitmap the size of the bar, drawn with y down as in a web canvas, and copied
// into a texture for the shaders: gray for brightness, or premultiplied sRGB colour.
final class Canvas {
  let width: Int
  let context: CGContext
  let texture: MTLTexture

  init(device: MTLDevice, width: Int, gray: Bool = false, decoded: Bool = true) {
    self.width = width
    let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
    let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    context = CGContext(data: nil, width: width, height: barHeight, bitsPerComponent: 8,
                        bytesPerRow: 0, space: space, bitmapInfo: info)!
    context.translateBy(x: 0, y: CGFloat(barHeight))
    context.scaleBy(x: 1, y: -1)
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    // `decoded` textures read back as linear light; the others as the encoded values.
    let format: MTLPixelFormat = gray ? .r8Unorm : decoded ? .rgba8Unorm_srgb : .rgba8Unorm
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: barHeight, mipmapped: false)
    desc.usage = .shaderRead
    texture = device.makeTexture(descriptor: desc)!
  }

  func clear(gray: CGFloat? = nil) {
    context.saveGState()
    context.setBlendMode(.copy)
    if let gray { context.setFillColor(gray: gray, alpha: 1) } else { context.setFillColor(CGColor(gray: 0, alpha: 0)) }
    context.fill(CGRect(x: 0, y: 0, width: width, height: barHeight))
    context.restoreGState()
  }

  func upload() {
    texture.replace(region: MTLRegionMake2D(0, 0, width, barHeight), mipmapLevel: 0,
                    withBytes: context.data!, bytesPerRow: context.bytesPerRow)
  }

  private func line(_ string: String, _ font: CTFont, _ color: CGColor, _ tracking: CGFloat) -> CTLine {
    var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    if tracking != 0 { attributes[.kern] = tracking }
    return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
  }

  func measure(_ string: String, font: CTFont, tracking: CGFloat = 0) -> CGFloat {
    CGFloat(CTLineGetTypographicBounds(line(string, font, CGColor(gray: 1, alpha: 1), tracking), nil, nil, nil))
  }

  // A line of text with its baseline at y, from x (or ending at x when right-aligned).
  @discardableResult
  func text(_ string: String, font: CTFont, color: CGColor, x: CGFloat, y: CGFloat, right: Bool = false, tracking: CGFloat = 0) -> CGFloat {
    let l = line(string, font, color, tracking)
    let width = CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil))
    context.textPosition = CGPoint(x: right ? x - width : x, y: y)
    CTLineDraw(l, context)
    return width
  }
}

enum Blend { case none, alpha, add } // alpha: premultiplied

// A theme's Metal state: a layer the size of the Touch Bar, its shaders, and one render pass a
// frame into the layer's drawable.
final class GPU {
  let device: MTLDevice
  let width: Int
  let layer = CAMetalLayer()
  private let queue: MTLCommandQueue
  private let library: MTLLibrary
  private var depth: MTLTexture?

  // Shared by every theme's shaders.
  static let common = """
  #include <metal_stdlib>
  using namespace metal;
  struct Pixel { float4 position [[position]]; };
  vertex Pixel fullscreen(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    Pixel o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return o;
  }
  // Pixel centres with y up, as the WebGL versions' coordinates.
  inline float2 upright(float4 position) { return float2(position.x, \(barHeight).0 - position.y); }
  inline float3 encode(float3 c) {
    c = max(c, 0.0);
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
  }
  // A painted canvas laid over what's been drawn, as it is (premultiplied and encoded).
  fragment float4 layer(Pixel in [[stage_in]], texture2d<float> canvas [[texture(0)]]) {
    constexpr sampler s(coord::pixel, filter::nearest, address::clamp_to_edge);
    return canvas.sample(s, in.position.xy);
  }
  """

  private let samples: Int
  private var multisampled: MTLTexture?
  private static var libraries: [String: MTLLibrary] = [:]

  // `samples` above 1 antialiases edges, as the WebGL renderer's antialias does.
  init?(device: MTLDevice, width: Int, source: String = "", depth needsDepth: Bool = false, samples: Int = 1) {
    self.device = device
    self.width = width
    self.samples = samples
    guard let queue = device.makeCommandQueue() else { return nil }
    self.queue = queue
    // Compiled once a run for each set of shaders, however many bars draw with them.
    if let cached = GPU.libraries[source] {
      library = cached
    } else {
      do {
        let options = MTLCompileOptions()
        options.fastMathEnabled = false // the shaders' noise relies on precise sin()
        library = try device.makeLibrary(source: GPU.common + source, options: options)
        GPU.libraries[source] = library
      } catch {
        log("shader failed: \(error)")
        return nil
      }
    }
    func target(_ format: MTLPixelFormat) -> MTLTexture? {
      let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: barHeight, mipmapped: false)
      desc.usage = .renderTarget
      desc.storageMode = .private
      if samples > 1 {
        desc.textureType = .type2DMultisample
        desc.sampleCount = samples
      }
      return device.makeTexture(descriptor: desc)
    }
    if needsDepth { depth = target(.depth32Float) }
    if samples > 1 { multisampled = target(.bgra8Unorm) }
    layer.device = device
    layer.pixelFormat = .bgra8Unorm
    layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    layer.framebufferOnly = true
    layer.isOpaque = true
    layer.contentsScale = 2
    layer.drawableSize = CGSize(width: width, height: barHeight)
    layer.frame = CGRect(x: 0, y: 0, width: width / 2, height: barHeight / 2)
  }

  func pipeline(vertex: String = "fullscreen", fragment: String, blend: Blend = .none) -> MTLRenderPipelineState? {
    let desc = MTLRenderPipelineDescriptor()
    desc.vertexFunction = library.makeFunction(name: vertex)
    desc.fragmentFunction = library.makeFunction(name: fragment)
    desc.rasterSampleCount = samples
    let color = desc.colorAttachments[0]!
    color.pixelFormat = .bgra8Unorm
    if blend != .none {
      color.isBlendingEnabled = true
      color.sourceRGBBlendFactor = .one
      color.sourceAlphaBlendFactor = .one
      color.destinationRGBBlendFactor = blend == .add ? .one : .oneMinusSourceAlpha
      color.destinationAlphaBlendFactor = blend == .add ? .one : .oneMinusSourceAlpha
    }
    if depth != nil { desc.depthAttachmentPixelFormat = .depth32Float }
    do { return try device.makeRenderPipelineState(descriptor: desc) } catch {
      log("pipeline \(fragment) failed: \(error)")
      return nil
    }
  }

  func depthState(test: Bool) -> MTLDepthStencilState? {
    let desc = MTLDepthStencilDescriptor()
    desc.depthCompareFunction = test ? .less : .always
    desc.isDepthWriteEnabled = test
    return device.makeDepthStencilState(descriptor: desc)
  }

  // One frame: cleared to black, drawn, shown.
  func frame(_ draw: (MTLRenderCommandEncoder) -> Void) {
    guard let drawable = layer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    if let multisampled {
      pass.colorAttachments[0].texture = multisampled
      pass.colorAttachments[0].resolveTexture = drawable.texture
      pass.colorAttachments[0].storeAction = .multisampleResolve
    } else {
      pass.colorAttachments[0].texture = drawable.texture
      pass.colorAttachments[0].storeAction = .store
    }
    if let depth {
      pass.depthAttachment.texture = depth
      pass.depthAttachment.loadAction = .clear
      pass.depthAttachment.clearDepth = 1
      pass.depthAttachment.storeAction = .dontCare
    }
    guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
    draw(encoder)
    encoder.endEncoding()
    buffer.present(drawable)
    buffer.commit()
  }
}

extension MTLRenderCommandEncoder {
  // A full-screen pass.
  func fullscreen(_ pipeline: MTLRenderPipelineState) {
    setRenderPipelineState(pipeline)
    drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
  }
}

// Linear values for an sRGB colour, as three.js keeps colours: shaders work in linear light.
func linear(_ hex: UInt32) -> SIMD4<Float> {
  func channel(_ v: UInt32) -> Float {
    let c = Float(v) / 255
    return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
  }
  return SIMD4(channel((hex >> 16) & 255), channel((hex >> 8) & 255), channel(hex & 255), 1)
}

func srgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
  CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

// The bundled fonts, read from Contents/Resources/fonts. Sized by cap height when asked, so a
// face sits the same way whatever its proportions.
enum Fonts {
  private static var descriptors: [String: CTFontDescriptor] = [:]

  static func font(_ file: String, size: CGFloat) -> CTFont {
    if descriptors[file] == nil,
       let url = Bundle.main.resourceURL?.appendingPathComponent("fonts/\(file)"),
       let data = try? Data(contentsOf: url),
       let found = (CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor])?.first {
      descriptors[file] = found
    }
    guard let descriptor = descriptors[file] else { return CTFontCreateUIFontForLanguage(.system, size, nil)! }
    return CTFontCreateWithFontDescriptor(descriptor, size, nil)
  }

  static func font(_ file: String, capHeight: CGFloat) -> CTFont {
    let unit = CTFontGetCapHeight(font(file, size: 100)) / 100
    return font(file, size: (capHeight / unit).rounded())
  }
}
