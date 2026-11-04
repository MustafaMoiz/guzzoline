// Engraving, drawn natively: a port of src/themes/engraving.js. Two scales like a slide rule's;
// what's left of each limit is a block cut in white lines, painted by the shader, and the rest
// (ticks, pointers, the mascot, the figures) is painted with Core Graphics on top. Each limit's
// figures sit level with its scale, flush with the bar's right edge.

import AppKit
import Metal

final class EngravingTheme: NativeTheme {
  private static let ink = srgb(0xECE8E0)
  private static let muted = srgb(0x8E8A82)
  private static let x0: CGFloat = 96
  private static let upperBaseline: CGFloat = 22
  private static let lowerBaseline: CGFloat = 55
  private static let face = "barlow-condensed-latin-600-normal.woff"
  private static let lightFace = "barlow-condensed-latin-500-normal.woff"
  private static let fragment = """
  float hash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }
  float noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + float2(1, 0)), f.x), mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), f.x), f.y);
  }
  float hatch(float2 p, float4 b, float dir) {
    float edge = b.x + (noise(float2(p.y * 0.8, b.x * 0.1)) - 0.5) * 1.6;
    float inside = smoothstep(edge - 0.5, edge + 0.5, p.x) * step(p.x, b.y) * step(b.z, p.y) * step(p.y, b.w);
    float period = 4.0;
    float t = (p.x + dir * p.y) / period;
    float d = abs(fract(t) - 0.5) * period;
    float half_ = 0.5 + 0.38 * noise(float2(p.x * 0.035 + floor(t) * 3.1, floor(t) * 0.7));
    float line = 1.0 - smoothstep(half_ - 0.55, half_ + 0.55, d);
    line *= smoothstep(0.1, 0.22, noise(p * float2(0.3, 0.8) + floor(t) * 7.0));
    return line * inside;
  }
  // blocks: what's left of each limit, as x from, x to, y from, y to, in pixels from the bottom.
  fragment float4 engraving(Pixel in [[stage_in]], texture2d<float> overlay [[texture(0)]], constant float4 *blocks [[buffer(0)]]) {
    constexpr sampler s(coord::pixel, filter::nearest, address::clamp_to_edge);
    float2 p = upright(in.position);
    float h = max(hatch(p, blocks[0], 1.0), hatch(p, blocks[1], -1.0));
    float4 o = overlay.sample(s, in.position.xy); // linear, premultiplied
    float3 c = float3(0.86, 0.83, 0.78) * h;
    return float4(encode(c * (1.0 - o.a) + o.rgb), 1.0);
  }
  """

  private struct Chip { var x, y, vx, vy, life: Double }

  private let gpu: GPU
  private let pass: MTLRenderPipelineState
  private let canvas: Canvas
  private var chips: [Chip] = []
  private(set) var busy = false
  var layer: CALayer { gpu.layer }

  // Sized by cap height: the number's caps fill a scale's height, the rest sit smaller.
  private let numberFont = Fonts.font(EngravingTheme.face, capHeight: 19)
  private let nameFont = Fonts.font(EngravingTheme.face, capHeight: 9)
  private let signFont = Fonts.font(EngravingTheme.face, capHeight: 11)
  private let resetFont = Fonts.font(EngravingTheme.lightFace, capHeight: 12.5)
  private let signWidth: CGFloat
  private let x1: CGFloat // where the scales end, so they stay put as the figures change

  private let width: CGFloat

  init?(device: MTLDevice, width: Int) {
    guard let gpu = GPU(device: device, width: width, source: EngravingTheme.fragment),
          let pass = gpu.pipeline(fragment: "engraving") else { return nil }
    self.gpu = gpu
    self.pass = pass
    canvas = Canvas(device: device, width: width)
    self.width = CGFloat(width)
    signWidth = canvas.measure("%", font: signFont)
    let widest = canvas.measure("SESSION", font: nameFont, tracking: 1.5) + 12 + canvas.measure("100", font: numberFont)
      + 3 + signWidth + 10 + max(canvas.measure("in 1d 14h", font: resetFont), canvas.measure("12:59 am", font: resetFont))
    x1 = (CGFloat(width) - 22 - widest - 30).rounded()
  }

  private var ctx: CGContext { canvas.context }

  // Ticks along a baseline: marks are (fraction, length).
  private func scale(_ base: CGFloat, _ down: Bool, _ marks: [(Double, CGFloat)]) {
    ctx.setFillColor(EngravingTheme.ink.copy(alpha: 0.85)!)
    let x0 = EngravingTheme.x0
    ctx.fill(CGRect(x: x0, y: base, width: x1 - x0, height: 1))
    for (f, len) in marks {
      let x = (x0 + CGFloat(f) * (x1 - x0)).rounded()
      ctx.fill(CGRect(x: x, y: down ? base + 1 : base - len, width: 1, height: len))
    }
  }

  // Hours and ten minutes on a session; days and quarter days on a week.
  private func marks(_ w: Window) -> [(Double, CGFloat)] {
    var out: [(Double, CGFloat)] = []
    if w.kind == "session" {
      for m in stride(from: 0, through: 300, by: 10) {
        let length: CGFloat = m % 60 == 0 ? 6 : (m % 30 == 0 ? 4 : 2)
        out.append((Double(m) / 300, length))
      }
    } else {
      for q in 0...28 { out.append((Double(q) / 28, q % 4 == 0 ? 6 : 2)) }
    }
    return out
  }

  // An even-pace pointer in the channel between the scales: a stem and a head at the ticks.
  private func pointer(_ x: CGFloat, up: Bool) {
    let cx = x.rounded() + 0.5
    ctx.setFillColor(EngravingTheme.ink)
    ctx.fill(CGRect(x: cx - 0.5, y: 27, width: 1, height: 6))
    ctx.beginPath()
    if up {
      ctx.move(to: CGPoint(x: cx, y: 23.5))
      ctx.addLine(to: CGPoint(x: cx + 3, y: 28.5))
      ctx.addLine(to: CGPoint(x: cx - 3, y: 28.5))
    } else {
      ctx.move(to: CGPoint(x: cx, y: 36.5))
      ctx.addLine(to: CGPoint(x: cx + 3, y: 31.5))
      ctx.addLine(to: CGPoint(x: cx - 3, y: 31.5))
    }
    ctx.closePath()
    ctx.fillPath()
  }

  private struct Row { let window: Window; let name, number, reset: String }

  // Both rows' figures in shared columns, as wide as they need, ending at the right margin.
  private func figures(_ rows: [Row]) {
    let nameW = rows.map { canvas.measure($0.name, font: nameFont, tracking: 1.5) }.max() ?? 0
    let numberW = rows.map { canvas.measure($0.number, font: numberFont) }.max() ?? 0
    let resetW = rows.map { canvas.measure($0.reset, font: resetFont) }.max() ?? 0
    let left = width - 22 - (nameW + 12 + numberW + 3 + signWidth + 10 + resetW)
    let numberRight = left + nameW + 12 + numberW
    for (row, baseline) in zip(rows, [EngravingTheme.upperBaseline, EngravingTheme.lowerBaseline]) {
      canvas.text(row.name, font: nameFont, color: EngravingTheme.muted, x: left, y: baseline, tracking: 1.5)
      canvas.text(row.number, font: numberFont, color: row.window.hot ? Clawd.color : EngravingTheme.ink, x: numberRight, y: baseline, right: true)
      canvas.text("%", font: signFont, color: EngravingTheme.muted, x: numberRight + 3, y: baseline)
      canvas.text(row.reset, font: resetFont, color: EngravingTheme.muted, x: numberRight + 3 + signWidth + 10, y: baseline)
    }
  }

  func render(_ v: BarState, dt: Double, t: Double) {
    let s = v.primary
    let w = v.secondary
    let x0 = Double(EngravingTheme.x0), len = Double(x1) - x0
    let bS = x0 + s.used * len
    let bW = w.map { x0 + $0.used * len } ?? Double(x1)
    var blocks: [SIMD4<Float>] = [
      SIMD4(Float(bS), Float(x1), Float(barHeight - 16 - 1), Float(barHeight - 3)),
      SIMD4(Float(bW), Float(x1), Float(barHeight - 56 - 1), Float(barHeight - 43)),
    ]

    canvas.clear()

    // The maker's mark: the one thing in colour.
    let asleep = s.status == "out" || w?.status == "out"
    ctx.setFillColor(Clawd.color)
    for (r, row) in Clawd.animate(t, working: false, asleep: asleep).enumerated() {
      for (c, on) in row.enumerated() where on != 0 {
        ctx.fill(CGRect(x: 22 + CGFloat(c) * 3, y: 15 + CGFloat(r) * 3, width: 3, height: 3))
      }
    }

    scale(17, true, marks(s))
    if let w { scale(42, false, marks(w)) }
    if s.active { pointer(CGFloat(x0 + s.elapsed * len), up: true) }
    if let w, w.active { pointer(CGFloat(x0 + w.elapsed * len), up: false) }

    // Chips fly off the edge of the first block while Claude is working.
    if v.working, !asleep, Double.random(in: 0..<1) < dt * 9 {
      chips.append(Chip(x: bS, y: 5 + Double.random(in: 0..<10), vx: -20 - Double.random(in: 0..<30), vy: -25 - Double.random(in: 0..<25), life: 0))
    }
    chips = chips.compactMap { chip in
      var c = chip
      c.life += dt
      c.x += c.vx * dt
      c.y += c.vy * dt
      c.vy += 140 * dt
      return c.life > 0.5 ? nil : c
    }
    for c in chips {
      ctx.setFillColor(EngravingTheme.ink.copy(alpha: CGFloat(1 - c.life / 0.5))!)
      ctx.fill(CGRect(x: c.x.rounded(), y: c.y.rounded(), width: 1.5, height: 1.5))
    }
    busy = !chips.isEmpty

    let words = { (win: Window) in
      Row(window: win, name: win.about.name.uppercased(), number: pct(v.showUsed ? win.used : win.left), reset: resetText(win))
    }
    figures([s, w].compactMap { $0 }.map(words))

    canvas.upload()
    gpu.frame { encoder in
      encoder.setFragmentTexture(canvas.texture, index: 0)
      encoder.setFragmentBytes(&blocks, length: MemoryLayout<SIMD4<Float>>.stride * 2, index: 0)
      encoder.fullscreen(pass)
    }
  }
}
