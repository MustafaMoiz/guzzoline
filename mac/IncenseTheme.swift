// Incense, drawn natively: a port of src/themes/incense.js. Sticks laid on an ash bed burn
// toward the mascot: the ash is what's spent, the ember is now, smoke rises off it. The bed,
// sticks and figures are painted with Core Graphics; smoke, sparks and the ember's glow are
// GPU points, blended as the web version blends them.

import AppKit
import Metal

final class IncenseTheme: NativeTheme {
  private static let bed: CGFloat = 44 // y of the ash bed, from the top
  private static let ink = srgb(0xECE8E0)
  private static let muted = srgb(0x8B877F)
  private static func fragment(width: Int) -> String { """
  struct Dot { float2 at; float size; float alpha; };
  struct DotOut { float4 position [[position]]; float size [[point_size]]; float alpha; };
  vertex DotOut dots(uint id [[vertex_id]], constant Dot *list [[buffer(0)]]) {
    Dot d = list[id];
    DotOut o;
    o.position = float4(d.at.x / \(width).0 * 2.0 - 1.0, d.at.y / \(barHeight).0 * 2.0 - 1.0, 0.0, 1.0);
    o.size = d.size;
    o.alpha = d.alpha;
    return o;
  }
  // A soft round point; style is its linear colour and how sharply it falls off.
  fragment float4 glow(DotOut in [[stage_in]], float2 pc [[point_coord]], constant float4 &style [[buffer(0)]]) {
    float r = length(pc - 0.5) * 2.0;
    float a = exp(-r * r * style.w) * (1.0 - smoothstep(0.7, 1.0, r)) * in.alpha;
    return float4(encode(style.rgb) * a, a);
  }
  """ }

  private struct Dot { var at: SIMD2<Float>; var size: Float; var alpha: Float }
  private struct Puff { var x, y, age, life, seed, size, alpha, vy, rise, turb: Double }
  private struct Spark { var x, y, age, life, vx, vy, alpha: Double }
  private struct Stick {
    let x0, x1, thick: Double
    let breaks: [Double]
    var tip: Double
    var emit = 0.0
    var kind = "session"
  }

  private let gpu: GPU
  private let backdrop: MTLRenderPipelineState
  private let soft: MTLRenderPipelineState
  private let bright: MTLRenderPipelineState
  private let canvas: Canvas
  private let buffers: [MTLBuffer]
  private var sticks: [Stick]
  private var smoke: [Puff] = []
  private var sparks: [Spark] = []
  private let textX: CGFloat
  private let clawdX: CGFloat
  private let right: CGFloat
  private let numberFont = Fonts.font("ibm-plex-mono-latin-300-normal.woff", size: 26)
  private let signFont = Fonts.font("ibm-plex-mono-latin-300-normal.woff", size: 17)
  private let resetFont = Fonts.font("ibm-plex-mono-latin-300-normal.woff", size: 19)
  private var painted = -1.0 // when the sticks and figures were last painted
  private var paintedTips: [Double] = []
  private(set) var busy = false
  var layer: CALayer { gpu.layer }

  private static func hash(_ n: Double) -> Double {
    let x = sin(n * 127.1 + 311.7) * 43758.5453
    return x - floor(x)
  }

  // Ash breaks into pieces of fixed lengths, so it doesn't shimmer as the ember moves.
  private static func breaks(_ length: Double, _ seed: Double) -> [Double] {
    var out = [0.0]
    var i = 0.0
    while out.last! < length {
      out.append(out.last! + 9 + hash(seed + i) * 19)
      i += 1
    }
    return out
  }

  private let width: Int

  init?(device: MTLDevice, width: Int) {
    self.width = width
    guard let gpu = GPU(device: device, width: width, source: IncenseTheme.fragment(width: width)),
          let backdrop = gpu.pipeline(fragment: "layer"),
          let soft = gpu.pipeline(vertex: "dots", fragment: "glow", blend: .alpha),
          let bright = gpu.pipeline(vertex: "dots", fragment: "glow", blend: .add) else { return nil }
    self.gpu = gpu
    self.backdrop = backdrop
    self.soft = soft
    self.bright = bright
    canvas = Canvas(device: device, width: width, decoded: false)
    buffers = (0..<3).map { _ in device.makeBuffer(length: 1024 * MemoryLayout<Dot>.stride, options: .storageModeShared)! }
    // Laid out from the bar's width: the second limit's stick and figures at the right edge,
    // the first limit's figures and Clawd before them, and the first stick takes the rest.
    let width = Double(width)
    let weekX1 = width - 156
    let weekX0 = weekX1 - (width * 0.17).rounded()
    let text = weekX0 - 208
    let x1 = text - 68
    textX = CGFloat(text)
    clawdX = CGFloat(x1 + 16)
    right = CGFloat(width - 18)
    sticks = [
      Stick(x0: 46, x1: x1, thick: 3, breaks: IncenseTheme.breaks(x1 - 46, 0), tip: 46),
      Stick(x0: weekX0, x1: weekX1, thick: 2, breaks: IncenseTheme.breaks(weekX1 - weekX0, 97), tip: weekX0),
    ]
  }

  private var ctx: CGContext { canvas.context }

  private func fill(_ hex: UInt32) { ctx.setFillColor(srgb(hex)) }

  // The bed and its marks, the ash, and what's left of the stick. Returns the ember's centre,
  // in pixels from the bottom left.
  private func draw(_ st: Stick, lit: Bool, t: Double) -> SIMD2<Float> {
    let bed = IncenseTheme.bed
    let thick = CGFloat(st.thick)
    let y = bed - thick
    let tip = st.tip.rounded()
    fill(0x2C2A27)
    ctx.fill(CGRect(x: st.x0 - 14, y: bed, width: st.x1 - st.x0 + 28, height: 1))
    fill(0x55524D)
    let marks = st.kind == "session" ? 5 : 7
    for m in 0...marks {
      ctx.fill(CGRect(x: (st.x0 + Double(m) / Double(marks) * (st.x1 - st.x0)).rounded(), y: bed + 2, width: 1, height: 3))
    }
    // Ash: broken pieces, a little sunk, flecked.
    for i in 0..<(st.breaks.count - 1) {
      let a = st.x0 + st.breaks[i]
      let b = min(st.x0 + st.breaks[i + 1] - 1, tip - 1)
      if a >= tip { break }
      let sink: CGFloat = IncenseTheme.hash(Double(i) * 7 + st.x0) > 0.6 ? 1 : 0
      fill(IncenseTheme.hash(Double(i) * 3 + 1) > 0.5 ? 0x6F6A63 : 0x7B766E)
      ctx.fill(CGRect(x: a, y: y + sink, width: max(0, b - a), height: thick))
      fill(0x9B958C)
      var k = 0.0
      while k < (b - a) / 6 {
        ctx.fill(CGRect(x: a + floor(IncenseTheme.hash(Double(i) * 13 + k) * (b - a)), y: y + sink, width: 1, height: 1))
        k += 1
      }
    }
    // What's left: a pale stick, charred just behind the ember.
    if tip < st.x1 {
      fill(0xD6CCBB)
      ctx.fill(CGRect(x: tip, y: y, width: st.x1 - tip, height: thick))
      fill(0xEFE7D9)
      ctx.fill(CGRect(x: tip, y: y, width: st.x1 - tip, height: 1))
      if lit {
        let char = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [srgb(0x2A120A), srgb(0x2A120A, alpha: 0)] as CFArray, locations: [0, 1])!
        ctx.saveGState()
        ctx.clip(to: CGRect(x: tip, y: y, width: 9, height: thick))
        ctx.drawLinearGradient(char, start: CGPoint(x: tip, y: 0), end: CGPoint(x: tip + 9, y: 0), options: [])
        ctx.restoreGState()
        ctx.setFillColor(CGColor(srgbRed: 1, green: (140 + 60 * sin(t * 3)) / 255, blue: 90 / 255, alpha: 1))
        ctx.fill(CGRect(x: tip - 1, y: y, width: 2, height: thick))
      }
    }
    return SIMD2(Float(tip), Float(Double(barHeight) - Double(y) - st.thick / 2))
  }

  // A number, a per cent sign and the reset, from x, or ending at `right`.
  private func figures(_ w: Window, _ showUsed: Bool, x: CGFloat? = nil, right: CGFloat? = nil) {
    let parts: [(String, CTFont, CGColor, CGFloat)] = [
      (pct(showUsed ? w.used : w.left), numberFont, w.hot ? Clawd.color : IncenseTheme.ink, 2),
      ("%", signFont, IncenseTheme.muted, 12),
      (resetText(w), resetFont, IncenseTheme.muted, 0),
    ]
    let widths = parts.map { canvas.measure($0.0, font: $0.1) }
    var cx = x ?? (right! - zip(widths, parts).reduce(0) { $0 + $1.0 + $1.1.3 })
    for (part, width) in zip(parts, widths) {
      canvas.text(part.0, font: part.1, color: part.2, x: cx, y: 40)
      cx += width + part.3
    }
  }

  private func upload(_ dots: [Dot], into buffer: MTLBuffer) -> Int {
    let count = min(dots.count, 1024)
    dots.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: count * MemoryLayout<Dot>.stride) }
    return count
  }

  func render(_ v: BarState, dt: Double, t: Double) {
    let asleep = [v.primary, v.secondary].contains { $0?.status == "out" }
    for i in sticks.indices {
      guard let win = i == 0 ? v.primary : v.secondary else { continue }
      let target = sticks[i].x0 + win.used * (sticks[i].x1 - sticks[i].x0)
      sticks[i].tip += (target - sticks[i].tip) * (1 - exp(-6 * dt))
    }
    // The smoke and glow move every frame; the sticks and figures are painted again when an
    // ember has burnt a pixel further, or 12 times a second for the ember's slow flicker.
    let tips = sticks.map { $0.tip.rounded() }
    let paint = t - painted >= 1.0 / 12 || tips != paintedTips
    if paint {
      canvas.clear()
      fill(0x000000)
      ctx.fill(CGRect(x: 0, y: 0, width: width, height: barHeight))
    }
    var embers: [Dot] = []
    busy = false

    for i in sticks.indices {
      guard let win = i == 0 ? v.primary : v.secondary else { continue }
      sticks[i].kind = win.kind
      let st = sticks[i]
      let lit = win.active && win.status != "out" && !asleep
      if lit { busy = true }
      let tip = SIMD2(Float(st.tip.rounded()), Float(Double(barHeight) - (Double(IncenseTheme.bed) - st.thick) - st.thick / 2))
      if paint { _ = draw(st, lit: lit, t: t) }

      // The now mark: where the ember would be at an even pace.
      if paint, win.active {
        let px = (st.x0 + win.elapsed * (st.x1 - st.x0)).rounded()
        let bed = IncenseTheme.bed
        ctx.setFillColor(IncenseTheme.ink)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: px + 0.5, y: bed + 6))
        ctx.addLine(to: CGPoint(x: px + 3.5, y: bed + 11))
        ctx.addLine(to: CGPoint(x: px - 2.5, y: bed + 11))
        ctx.closePath()
        ctx.fillPath()
      }

      if lit {
        let glow = 0.75 + 0.25 * sin(t * 2.2 + Double(i)) + (v.working ? 0.35 : 0)
        embers.append(Dot(at: tip, size: Float((st.thick + 1) * 7 * glow), alpha: 0.95))
        sticks[i].emit += dt * (v.working ? 70 : 26) * (i > 0 ? 0.6 : 1)
        while sticks[i].emit >= 1 {
          sticks[i].emit -= 1
          smoke.append(Puff(x: Double(tip.x) + Double.random(in: -0.5..<0.5), y: Double(tip.y) + 1, age: 0, life: 2.8 + Double.random(in: 0..<1.6),
                            seed: Double.random(in: 0..<100), size: 2, alpha: 0, vy: 9 + Double.random(in: 0..<5), rise: 0, turb: v.working ? 1.6 : 1))
        }
        if v.working, Double.random(in: 0..<1) < dt * 5 {
          for _ in 0..<3 {
            sparks.append(Spark(x: Double(tip.x), y: Double(tip.y), age: 0, life: 0.3 + Double.random(in: 0..<0.4),
                                vx: Double.random(in: -0.5..<0.5) * 40, vy: 20 + Double.random(in: 0..<30), alpha: 1))
          }
        }
      }
    }

    smoke = smoke.compactMap { puff in
      var p = puff
      p.age += dt
      if p.age >= p.life { return nil }
      let h = p.rise
      let curl = min(1, h / 16) * p.turb
      p.y += p.vy * dt
      p.rise += p.vy * dt
      p.x += (sin(t * 0.9 + p.seed + h * 0.12) * 5 + sin(t * 2.1 + h * 0.31 + p.seed * 2) * 3) * curl * dt + 1.5 * dt
      p.size = 2 + h * 0.22
      p.alpha = min(1, p.age * 4) * (1 - p.age / p.life) * 0.16
      return p
    }
    sparks = sparks.compactMap { spark in
      var p = spark
      p.age += dt
      if p.age >= p.life { return nil }
      p.x += p.vx * dt
      p.y += p.vy * dt
      p.vy -= 90 * dt
      p.alpha = 1 - p.age / p.life
      return p
    }

    if paint {
      // Clawd sits at the end of the first stick, eyes closed unless Claude is working.
      ctx.setFillColor(Clawd.color)
      for (r, row) in Clawd.animate(t, working: false, asleep: asleep || !v.working).enumerated() {
        for (c, on) in row.enumerated() where on != 0 {
          ctx.fill(CGRect(x: clawdX + CGFloat(c) * 2, y: IncenseTheme.bed - 20 + CGFloat(r) * 2, width: 2, height: 2))
        }
      }
      figures(v.primary, v.showUsed, x: textX)
      if let w = v.secondary { figures(w, v.showUsed, right: right) }
      canvas.upload()
      painted = t
      paintedTips = tips
    }

    let smokeCount = upload(smoke.map { Dot(at: SIMD2(Float($0.x), Float($0.y)), size: Float($0.size), alpha: Float($0.alpha)) }, into: buffers[0])
    let emberCount = upload(embers, into: buffers[1])
    let sparkCount = upload(sparks.map { Dot(at: SIMD2(Float($0.x), Float($0.y)), size: 2.5, alpha: Float($0.alpha)) }, into: buffers[2])
    var smokeStyle = linear(0xE8E4DD); smokeStyle.w = 6
    var emberStyle = linear(0xFF7A3C); emberStyle.w = 3.2
    var sparkStyle = linear(0xFFB27A); sparkStyle.w = 9
    gpu.frame { encoder in
      encoder.setFragmentTexture(canvas.texture, index: 0)
      encoder.fullscreen(backdrop)
      for (pipeline, buffer, count, style) in [(soft, buffers[0], smokeCount, smokeStyle), (bright, buffers[1], emberCount, emberStyle), (bright, buffers[2], sparkCount, sparkStyle)] where count > 0 {
        var s = style
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setFragmentBytes(&s, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: count)
      }
    }
  }
}
