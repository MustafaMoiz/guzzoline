// Walk, drawn natively: a port of src/themes/walk.js. Clawd, in voxels lit like the three.js
// version (hemisphere, key and rim lights on a matte body), walks the first limit's path, with
// a dim mirrored copy below the line. The path and figures are painted with Core Graphics:
// what's under the mascot first, then the cubes, then the fade and what floats over it.

import AppKit
import Metal
import simd

final class WalkTheme: NativeTheme {
  private static let ink: UInt32 = 0xF2EFE9
  private static let muted: UInt32 = 0x8B877F
  private static let unit: Float = 3 // one mascot unit, in pixels
  private static let ground: CGFloat = 17 // the path's line, from the bottom

  private let gpu: GPU
  private let under: MTLRenderPipelineState
  private let over: MTLRenderPipelineState
  private let cubes: MTLRenderPipelineState
  private let depthOn: MTLDepthStencilState
  private let depthOff: MTLDepthStencilState
  private let mesh: MTLBuffer
  private let instances: MTLBuffer
  private let below: Canvas
  private let above: Canvas
  private var scene: Voxel.Scene

  // Laid out from the bar's width: the second limit's figures end at the right margin, its
  // track sits before them, then the first limit's figures, and the walk takes the rest.
  private let path: (CGFloat, CGFloat)
  private let numberX: CGFloat
  private let week: (CGFloat, CGFloat)
  private let right: CGFloat

  private let numberFont = Fonts.font("ibm-plex-mono-latin-500-normal.woff", size: 26)
  private let signFont = Fonts.font("ibm-plex-mono-latin-400-normal.woff", size: 17)
  private let resetFont = Fonts.font("ibm-plex-mono-latin-400-normal.woff", size: 19)
  private let zFont = Fonts.font("ibm-plex-mono-latin-400-normal.woff", size: 15)

  private var x: Double
  private var facing = 1.0
  private var yaw = 0.0
  private var phase = 0.0
  private(set) var busy = false
  var layer: CALayer { gpu.layer }

  private let width: Int

  init?(device: MTLDevice, width: Int) {
    self.width = width
    guard let gpu = GPU(device: device, width: width, source: Voxel.shaders, depth: true, samples: 4),
          let under = gpu.pipeline(fragment: "layer"),
          let over = gpu.pipeline(fragment: "layer", blend: .alpha),
          let cubes = gpu.pipeline(vertex: "cube", fragment: "shade"),
          let depthOn = gpu.depthState(test: true), let depthOff = gpu.depthState(test: false) else { return nil }
    self.gpu = gpu
    self.under = under
    self.over = over
    self.cubes = cubes
    self.depthOn = depthOn
    self.depthOff = depthOff
    mesh = Voxel.mesh(device)
    instances = device.makeBuffer(length: 2 * Voxel.cubesPerFigure * MemoryLayout<Voxel.Cube>.stride, options: .storageModeShared)!
    below = Canvas(device: device, width: width, decoded: false)
    above = Canvas(device: device, width: width, decoded: false)

    let barW = CGFloat(width)
    right = barW - 30
    let weekLength = (barW * 0.15).rounded()
    let week1 = right - 176
    numberX = week1 - weekLength - 90 - 200
    path = (34, numberX - 40)
    week = (week1 - weekLength, week1)
    x = Double(path.0)
    scene = Voxel.scene(width: width)
  }

  // A rectangle given as the web version places it: x, y from the bottom, width, height.
  private func rect(_ canvas: Canvas, _ hex: UInt32, _ alpha: CGFloat, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
    guard w > 0, h > 0 else { return }
    canvas.context.setFillColor(srgb(hex, alpha: alpha))
    canvas.context.fill(CGRect(x: x, y: CGFloat(barHeight) - y - h, width: w, height: h))
  }

  // Text with its baseline at y from the bottom; returns its width.
  @discardableResult
  private func text(_ canvas: Canvas, _ string: String, _ font: CTFont, _ color: CGColor, _ x: CGFloat, _ y: CGFloat) -> CGFloat {
    canvas.text(string, font: font, color: color, x: x, y: CGFloat(barHeight) - y)
  }

  func render(_ v: BarState, dt: Double, t: Double) {
    let s = v.primary
    let w = v.secondary
    let ground = WalkTheme.ground
    let length = Double(path.1 - path.0)
    // The mascot is half a body wide, so it walks to just short of the finish post.
    let target = Double(path.0) + s.used * (length - 30)
    let d = target - x
    let moving = abs(d) > 0.75
    if moving {
      let speed = min(max(abs(d) * 2.5, 45), 900)
      x += (d > 0 ? 1 : -1) * min(abs(d), speed * dt)
      facing = d > 0 ? 1 : -1
    }
    let asleep = !moving && (s.status == "out" || w?.status == "out")
    let walking = moving || (v.working && !asleep)
    busy = moving || asleep
    phase = walking ? phase + dt * (moving ? 13 : 8) : 0
    yaw += ((walking ? facing * 0.55 : 0) - yaw) * (1 - exp(-8 * dt))

    let grid = Clawd.animate(t, working: false, asleep: asleep)
    let squash = Float(asleep ? 0.95 + sin(t * 1.4) * 0.012 : 1)
    let lift = Float(walking ? sin(phase) : 0)
    let u = WalkTheme.unit, px = Float(x)
    var list: [Voxel.Cube] = []
    let body = linear(0xD77757)
    Voxel.figure(Voxel.translate(px, Float(ground) + 1, 0) * Voxel.scale(u, u, u) * Voxel.rotation(x: 0.3, y: Float(yaw)),
                 grid: grid, lift: lift, walking: walking, squash: squash, body: body, eye: Voxel.flat(0x0B0604), into: &list)
    // The floor is glossy black: a dim, unlit copy hangs below the line.
    Voxel.figure(Voxel.translate(px, Float(ground) - 4, 0) * Voxel.scale(u, -u, u) * Voxel.rotation(x: -0.3, y: Float(yaw)),
                 grid: grid, lift: lift, walking: walking, squash: squash, body: Voxel.flat(0x2E1A13), eye: Voxel.flat(0x0B0604), into: &list)
    let count = list.count
    list.withUnsafeBytes { instances.contents().copyMemory(from: $0.baseAddress!, byteCount: count * MemoryLayout<Voxel.Cube>.stride) }

    // Under the mascot: the path, the post, the second limit's track, the figures.
    let ink = WalkTheme.ink, muted = WalkTheme.muted
    below.clear()
    below.context.setFillColor(srgb(0x000000))
    below.context.fill(CGRect(x: 0, y: 0, width: width, height: barHeight))
    let xi = CGFloat(x.rounded())
    rect(below, ink, 0.9, path.0, ground - 2, max(0, xi - path.0), 2)
    var dx = xi + 30
    while dx < path.1 - 2 {
      rect(below, muted, 0.55, dx - 1, ground - 2, 2, 2)
      dx += 8
    }
    rect(below, ink, 0.55, path.1, ground - 2, 2, 16)
    rect(below, ink, 0.55, path.1 + 2, ground + 9, 6, 5)

    let hot = { (win: Window) in win.hot ? Clawd.color : srgb(ink) }
    let number = pct(v.showUsed ? s.used : s.left)
    let numberW = text(below, number, numberFont, hot(s), numberX, 21)
    let signW = text(below, "%", signFont, srgb(muted), numberX + numberW + 2, 21)
    text(below, resetText(s), resetFont, srgb(muted), numberX + numberW + signW + 14, 21)

    if let w {
      // The second limit: a thinner track, ruled in days, and its figures at the right margin.
      let wl = week.1 - week.0, wy: CGFloat = 29
      let fill = (CGFloat(w.used) * wl).rounded()
      rect(below, ink, 0.9, week.0, wy - 1, fill, 2)
      rect(below, muted, 0.6, week.0 + fill, wy - 0.5, wl - fill, 1)
      for i in 0...7 { rect(below, muted, 0.7, (week.0 + CGFloat(i) / 7 * wl).rounded(), wy - 4, 1, 3) }
      if w.active { rect(below, ink, 0.45, (week.0 + CGFloat(w.elapsed) * wl).rounded() - 1, wy + 3, 2, 5) }
      let weekNumber = pct(v.showUsed ? w.used : w.left)
      let reset = resetText(w)
      let total = below.measure(weekNumber, font: numberFont) + 2 + below.measure("%", font: signFont) + 14 + below.measure(reset, font: resetFont)
      var cx = right - total
      cx += text(below, weekNumber, numberFont, hot(w), cx, 21) + 2
      cx += text(below, "%", signFont, srgb(muted), cx, 21) + 14
      text(below, reset, resetFont, srgb(muted), cx, 21)
    }
    below.upload()

    // Over it: the fade on the reflection, the even-pace tick, sweat and sleep.
    above.clear()
    let fade = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [srgb(0x000000, alpha: 0.15), srgb(0x000000, alpha: 1)] as CFArray, locations: [0, 1])!
    above.context.saveGState()
    above.context.clip(to: CGRect(x: 0, y: CGFloat(barHeight) - (ground - 2), width: path.1 + 60, height: ground - 2))
    above.context.drawLinearGradient(fade, start: CGPoint(x: 0, y: CGFloat(barHeight) - (ground - 2)), end: CGPoint(x: 0, y: CGFloat(barHeight)), options: [])
    above.context.restoreGState()
    if s.active { rect(above, ink, 0.4, (path.0 + CGFloat(s.elapsed) * CGFloat(length - 30)).rounded() - 1, ground - 9, 2, 6) }
    if walking, !moving, s.status == "fast" {
      let sp = CGFloat(t.truncatingRemainder(dividingBy: 1.1) / 1.1)
      rect(above, ink, 0.9 * (1 - sp), xi + (facing > 0 ? 27 : -30), ground + 29 - sp * 10, 3, 4)
    }
    if asleep {
      for i in 0..<3 {
        let p = (t * 0.45 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
        text(above, "z", zFont, srgb(muted, alpha: CGFloat(sin(p * .pi) * 0.9)), xi + 20 + CGFloat(p) * 14 + CGFloat(i) * 2, ground + 22 + CGFloat(p) * 10)
      }
    }
    above.upload()

    gpu.frame { encoder in
      encoder.setDepthStencilState(depthOff)
      encoder.setFragmentTexture(below.texture, index: 0)
      encoder.fullscreen(under)
      encoder.setDepthStencilState(depthOn)
      encoder.setCullMode(.none)
      encoder.setRenderPipelineState(cubes)
      encoder.setVertexBuffer(mesh, offset: 0, index: 0)
      encoder.setVertexBuffer(instances, offset: 0, index: 1)
      encoder.setVertexBytes(&scene, length: MemoryLayout<Voxel.Scene>.stride, index: 2)
      encoder.setFragmentBytes(&scene, length: MemoryLayout<Voxel.Scene>.stride, index: 2)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 36, instanceCount: count)
      encoder.setDepthStencilState(depthOff)
      encoder.setFragmentTexture(above.texture, index: 0)
      encoder.fullscreen(over)
    }
  }
}
