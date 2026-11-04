// Phosphor, drawn natively: a port of src/themes/phosphor.js. Brightness is painted into a
// gray bitmap, then lit as phosphor behind a control grid, with a tight glow.

import AppKit
import Metal

final class PhosphorTheme: NativeTheme {
  private static let ghost: CGFloat = 0.016
  private static let labelLevel: CGFloat = 0.62
  private static let digits: [Character: String] = [
    "0": "abcdef", "1": "bc", "2": "abged", "3": "abgcd", "4": "fgbc", "5": "afgcd",
    "6": "afgecd", "7": "abc", "8": "abcdefg", "9": "abcdfg",
  ]
  private static let fragment = """
  fragment float4 phosphor(Pixel in [[stage_in]], texture2d<float> map [[texture(0)]], constant float4 &phosphor [[buffer(0)]]) {
    constexpr sampler s(coord::pixel, filter::nearest, address::clamp_to_edge);
    float2 at = in.position.xy;
    float i = map.sample(s, at).r;
    float glow = 0.0;
    float total = 0.0;
    for (int dx = -6; dx <= 6; dx++) {
      for (int dy = -3; dy <= 3; dy++) {
        float w = exp(-float(dx * dx) / 12.0 - float(dy * dy) / 4.0);
        glow += map.sample(s, at + float2(dx, dy)).r * w;
        total += w;
      }
    }
    glow /= total;
    float2 p = upright(in.position);
    float mesh = max(step(2.3, fmod(p.x + p.y, 3.0)), step(2.3, fmod(p.x - p.y + 3000.0, 3.0)));
    float3 c = phosphor.rgb * (i * (1.0 - 0.3 * mesh) * 0.95 + glow * 0.35);
    c += float3(1.0, 0.8, 0.66) * smoothstep(0.9, 1.0, i) * 0.06;
    return float4(encode(c), 1.0);
  }
  """

  // Laid out from the bar's right edge, each x where a part ends: the second limit's day,
  // number and segments, its label, the reset's clock, the first number; the first limit's
  // segments fill what's left.
  private struct Layout {
    static let weekLength: CGFloat = 28 * 12 + 6 * 6 - 3
    let right, weekDigits, weekStart, weekLabel, minutes, digits: CGFloat
    let segments: Int
    init(width: CGFloat) {
      right = width - 24
      weekDigits = right - 72
      weekStart = weekDigits - 81 - 24 - Layout.weekLength
      weekLabel = weekStart - 38
      minutes = weekLabel - 52
      digits = minutes - 110
      segments = Int(((digits - 100 - 138 + 4) / 17).rounded(.down))
    }
  }

  private let gpu: GPU
  private let pass: MTLRenderPipelineState
  private let canvas: Canvas
  private let at: Layout
  private var phosphor = linear(0xFF8A5C)
  private var lit5: [CGFloat]
  private var litW = [CGFloat](repeating: 0, count: 28)
  private(set) var busy = false
  var layer: CALayer { gpu.layer }

  init?(device: MTLDevice, width: Int) {
    guard let gpu = GPU(device: device, width: width, source: PhosphorTheme.fragment),
          let pass = gpu.pipeline(fragment: "phosphor") else { return nil }
    self.gpu = gpu
    self.pass = pass
    canvas = Canvas(device: device, width: width, gray: true)
    at = Layout(width: CGFloat(width))
    lit5 = [CGFloat](repeating: 0, count: at.segments)
  }

  private var ctx: CGContext { canvas.context }

  private func fill(_ level: CGFloat) { ctx.setFillColor(gray: level, alpha: 1) }

  private func polygon(_ points: [(CGFloat, CGFloat)]) {
    ctx.beginPath()
    ctx.move(to: CGPoint(x: points[0].0, y: points[0].1))
    for p in points.dropFirst() { ctx.addLine(to: CGPoint(x: p.0, y: p.1)) }
    ctx.closePath()
    ctx.fillPath()
  }

  private func segment(_ horizontal: Bool, _ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ t: CGFloat) {
    let h = t / 2
    if horizontal { polygon([(a, c), (a + h, c - h), (b - h, c - h), (b, c), (b - h, c + h), (a + h, c + h)]) }
    else { polygon([(c, a), (c + h, a + h), (c + h, b - h), (c, b), (c - h, b - h), (c - h, a + h)]) }
  }

  // A slanted seven-segment digit in a w×h box at (x, y), every segment ghosted, the digit's lit.
  private func digit(_ ch: Character, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ t: CGFloat, _ level: CGFloat) {
    let k: CGFloat = 0.1, g: CGFloat = 1.2
    ctx.saveGState()
    ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: -k, d: 1, tx: x + k * h, ty: y))
    let lit = PhosphorTheme.digits[ch] ?? ""
    let segs: [(Character, Bool, CGFloat, CGFloat, CGFloat)] = [
      ("a", true, t / 2 + g, w - t / 2 - g, t / 2),
      ("g", true, t / 2 + g, w - t / 2 - g, h / 2),
      ("d", true, t / 2 + g, w - t / 2 - g, h - t / 2),
      ("f", false, t / 2 + g, h / 2 - g, t / 2),
      ("b", false, t / 2 + g, h / 2 - g, w - t / 2),
      ("e", false, h / 2 + g, h - t / 2 - g, t / 2),
      ("c", false, h / 2 + g, h - t / 2 - g, w - t / 2),
    ]
    for (name, horizontal, a, b, c) in segs {
      fill(lit.contains(name) ? level : PhosphorTheme.ghost)
      segment(horizontal, a, b, c, t)
    }
    ctx.restoreGState()
  }

  // A right-aligned run of digits; blanks stay as ghost eights.
  private func number(_ text: String, _ right: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ t: CGFloat, _ pitch: CGFloat, _ count: Int, _ level: CGFloat) {
    let padded = String(repeating: " ", count: max(0, count - text.count)) + text
    for (i, ch) in padded.suffix(count).enumerated() {
      digit(ch, right - CGFloat(count - i) * pitch, y, w, h, t, level)
    }
  }

  private func colon(_ x: CGFloat, _ y: CGFloat, _ h: CGFloat, _ level: CGFloat) {
    fill(level)
    ctx.fill(CGRect(x: x, y: y + h * 0.28, width: 3, height: 3))
    ctx.fill(CGRect(x: x - 1, y: y + h * 0.66, width: 3, height: 3))
  }

  private func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ level: CGFloat = PhosphorTheme.labelLevel, _ scale: CGFloat = 2) {
    fill(level)
    PixelFont.draw(text, x: 0, y: 0) { dx, dy in
      ctx.fill(CGRect(x: x + CGFloat(dx) * scale, y: y + CGFloat(dy) * scale, width: scale * 0.8, height: scale * 0.8))
    }
  }

  private func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ skew: CGFloat, _ level: CGFloat) {
    fill(level)
    polygon([(x + skew, y), (x + w + skew, y), (x + w, y + h), (x, y + h)])
  }

  // Lit segments ease toward their state: on quickly, off with a little afterglow.
  private func ladder(_ levels: inout [CGFloat], _ target: Double, _ pulse: CGFloat, _ dt: Double) -> Bool {
    let on = Int((target * Double(levels.count)).rounded())
    var moving = false
    for i in levels.indices {
      var goal = i < on ? 1 : PhosphorTheme.ghost
      if pulse > 0, i == on - 1 { goal = 0.55 + 0.45 * pulse }
      let rate = goal > levels[i] ? 40.0 : 7.0
      levels[i] += (goal - levels[i]) * CGFloat(1 - exp(-rate * dt))
      if abs(goal - levels[i]) > 0.01 { moving = true }
    }
    return moving
  }

  func render(_ v: BarState, dt: Double, t: Double) {
    let s = v.primary
    let w = v.secondary
    let pulse: CGFloat = v.working && s.status != "out" ? 0.5 + 0.5 * CGFloat(sin(t * 9)) : 0
    var moving = ladder(&lit5, v.showUsed ? s.used : s.left, pulse, dt)
    if let w { moving = ladder(&litW, v.showUsed ? w.used : w.left, 0, dt) || moving }
    let blink = Int(t * 1.6) % 2 == 0
    busy = moving || s.status == "out" || w?.status == "out"

    canvas.clear(gray: 0)

    // The mascot, in phosphor dots.
    fill(1)
    let asleep = s.status == "out" || w?.status == "out"
    let grid = Clawd.animate(t, working: v.working && !asleep, asleep: asleep)
    for (r, row) in grid.enumerated() {
      for (c, on) in row.enumerated() where on != 0 {
        ctx.fill(CGRect(x: 24 + CGFloat(c) * 3, y: 15 + CGFloat(r) * 3, width: 2.4, height: 2.4))
      }
    }

    // The first limit: the session, or the week on a plan without one.
    label(s.about.short, 100, 23)
    for (i, level) in lit5.enumerated() { bar(138 + CGFloat(i) * 17, 18, 13, 24, 4, level) }
    if s.active {
      let pace = v.showUsed ? s.elapsed : 1 - s.elapsed
      let px = 138 + CGFloat(pace) * CGFloat(at.segments) * 17 - 2
      fill(0.7)
      polygon([(px - 4, 51), (px + 4, 51), (px, 46)])
    }
    number(pct(v.showUsed ? s.used : s.left), at.digits, 12, 20, 36, 4, 27, 3, 1)
    label("%", at.digits + 6, 34)
    // When it resets: a clock time (a weekday when that's days off), blinking like a VCR's
    // once the limit has run out.
    let level: CGFloat = s.active ? (s.status == "out" && !blink ? PhosphorTheme.ghost : 1) : PhosphorTheme.ghost
    if s.active, s.kind == "week", let resetIn = s.resetIn, resetIn >= day, let when = s.resetsAt {
      label(weekday(when).uppercased(), at.minutes - 70, 23, level)
    } else {
      let (time, period) = s.resetsAt.map(clock) ?? (":", "")
      let parts = time.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
      number(parts.first ?? "", at.minutes - 44, 23, 13, 26, 3, 17, 2, level)
      colon(at.minutes - 40, 23, 26, level)
      number(parts.count > 1 ? parts[1] : "", at.minutes, 23, 13, 26, 3, 17, 2, level)
      if !period.isEmpty { label(period.uppercased(), at.minutes + 6, 22, level * 0.8, 1.4) }
    }

    if let w {
      // The second limit, in seven groups of four.
      label(w.about.short, at.weekLabel, 23)
      for (i, level) in litW.enumerated() {
        let g = CGFloat(i / 4)
        bar(at.weekStart + CGFloat(i) * 12 + g * 6, 21, 9, 18, 3, level)
      }
      if w.active {
        let pace = v.showUsed ? w.elapsed : 1 - w.elapsed
        let px = at.weekStart + CGFloat(pace) * Layout.weekLength
        fill(0.7)
        polygon([(px - 4, 50), (px + 4, 50), (px, 45)])
      }
      number(pct(v.showUsed ? w.used : w.left), at.weekDigits, 12, 20, 36, 4, 27, 3, 1)
      label("%", at.weekDigits + 6, 34)
      let weekLevel: CGFloat = w.status == "out" && !blink ? PhosphorTheme.ghost : 0.85
      let when = w.resetsAt ?? v.now
      let dayText = ((w.resetIn ?? day) < day ? clock(when).time : weekday(when)).uppercased()
      label(dayText, at.right - CGFloat(PixelFont.width(dayText) * 2), 23, weekLevel)
    }

    canvas.upload()
    gpu.frame { encoder in
      encoder.setFragmentTexture(canvas.texture, index: 0)
      encoder.setFragmentBytes(&phosphor, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
      encoder.fullscreen(pass)
    }
  }
}
