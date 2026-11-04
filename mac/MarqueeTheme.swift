// Marquee, drawn natively: a port of src/themes/marquee.js. An LED sign of 401 × 12 lamps at a
// 5 px pitch: each frame the content is laid out in lamps, and the shader draws each as a disc
// with a halo. Now and then, or on a tap, a sentence crawls across it.

import AppKit
import Metal

final class MarqueeTheme: NativeTheme {
  private static let rows = 12
  private static let pitch = 5
  private static let crawlSpeed = 46.0 // lamps a second
  private static let crawlEvery = 45.0 // seconds
  private static let fragment = """
  // grid: columns, rows, pitch, left offset. The frame's first row is the sign's top row.
  fragment float4 marquee(Pixel in [[stage_in]], texture2d<float> frame [[texture(0)]], constant float4 &grid [[buffer(0)]]) {
    float2 p = upright(in.position);
    float pitch = grid.z;
    float2 offset = float2(grid.w, 0.0);
    float2 cell = floor((p - offset) / pitch);
    float3 col = float3(0.0);
    for (int dx = -1; dx <= 1; dx++) {
      for (int dy = -1; dy <= 1; dy++) {
        float2 c = cell + float2(dx, dy);
        if (c.x < 0.0 || c.y < 0.0 || c.x >= grid.x || c.y >= grid.y) continue;
        float4 f = frame.read(uint2(uint(c.x), uint(grid.y - 1.0 - c.y)));
        float3 tint = mix(float3(1.0, 0.8, 0.62), float3(1.0, 0.36, 0.2), f.g);
        float d = length(p - ((c + 0.5) * pitch + offset));
        if (dx == 0 && dy == 0) {
          float disc = 1.0 - smoothstep(1.3, 1.9, d);
          col += mix(float3(0.018, 0.016, 0.015), tint * 1.1, f.r) * disc;
        }
        col += tint * f.r * exp(-d * d / 7.0) * 0.22;
      }
    }
    return float4(encode(col), 1.0);
  }
  """

  // A page of lamps: brightness and colour per lamp, rows counted from the top.
  private final class Page {
    let cols: Int
    var level: [Float]
    var orange: [UInt8]
    init(cols: Int) {
      self.cols = cols
      level = [Float](repeating: 0, count: cols * MarqueeTheme.rows)
      orange = [UInt8](repeating: 0, count: cols * MarqueeTheme.rows)
    }
    func clear() {
      for i in level.indices { level[i] = 0; orange[i] = 0 }
    }
    func set(_ c: Int, _ r: Int, _ v: Float = 1, _ o: UInt8 = 0) {
      guard c >= 0, c < cols, r >= 0, r < MarqueeTheme.rows else { return }
      level[r * cols + c] = v
      orange[r * cols + c] = o
    }
  }

  private struct Box { let x, w, top, rows: Int }

  private let gpu: GPU
  private let pass: MTLRenderPipelineState
  private let texture: MTLTexture
  private let cols: Int
  private var grid: SIMD4<Float>
  private let right: Int
  private let textX: Int
  private let bar: Box
  private let week: Box
  private let dash: Page
  private var bytes: [UInt8]
  private var message: Page?
  private var crawl = -1.0 // lamps scrolled, or -1 while the dashboard stands still
  private var nextCrawl: Double?
  private var tapped = false
  private(set) var busy = false
  var layer: CALayer { gpu.layer }

  init?(device: MTLDevice, width: Int) {
    cols = width / MarqueeTheme.pitch
    guard let gpu = GPU(device: device, width: width, source: MarqueeTheme.fragment),
          let pass = gpu.pipeline(fragment: "marquee") else { return nil }
    self.gpu = gpu
    self.pass = pass
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: cols, height: MarqueeTheme.rows, mipmapped: false)
    desc.usage = .shaderRead
    texture = device.makeTexture(descriptor: desc)!
    grid = SIMD4(Float(cols), Float(MarqueeTheme.rows), Float(MarqueeTheme.pitch), Float(width - cols * MarqueeTheme.pitch) / 2)
    // Laid out from the sign's right edge: the second limit's figures end there, its meter sits
    // before them, then the first limit's figures; the first meter takes the rest.
    right = cols - 3
    week = Box(x: right - 54 - 77, w: 77, top: 4, rows: 4)
    textX = week.x - 64
    bar = Box(x: 23, w: textX - 6 - 23, top: 3, rows: 6)
    dash = Page(cols: cols)
    bytes = [UInt8](repeating: 0, count: cols * MarqueeTheme.rows * 4)
  }

  func tap() { tapped = true }

  @discardableResult
  private func text(_ page: Page, _ string: String, _ x: Int, _ r: Int, _ v: Float = 1) -> Int {
    PixelFont.draw(string, x: x, y: r) { c, rr in page.set(c, rr, v) }
    return x + string.reduce(0) { $0 + PixelFont.width(String($1)) + 1 }
  }

  // Lit up to the fraction, the rest of the meter glowing faintly; a week is ruled in days.
  private func meter(_ box: Box, _ fraction: Double, _ pace: Double?, _ chase: Bool, _ t: Double, days: Int = 0) {
    let lit = Int((fraction * Double(box.w)).rounded())
    let every = days > 0 ? Int((Double(box.w) / Double(days)).rounded()) : 0
    for c in 0..<box.w {
      let dayLine = days > 0 && c > 0 && c % every == 0
      for r in 0..<box.rows {
        var v: Float = c < lit ? 1 : 0.1
        if c < lit, chase, (c - Int(floor(t * 14))) % 6 == 0 { v = 0.35 }
        if dayLine { v = 0 }
        dash.set(box.x + c, box.top + r, v)
      }
    }
    if let pace {
      let c = box.x + Int((pace * Double(box.w)).rounded())
      dash.set(c, box.top - 2, 0.55)
      dash.set(c, box.top + box.rows + 1, 0.55)
    }
  }

  private func timeText(_ date: Date) -> String {
    let (time, period) = clock(date)
    return period.isEmpty ? time : "\(time) \(period)"
  }

  private func resetShort(_ w: Window) -> String {
    guard w.active, let at = w.resetsAt, let resetIn = w.resetIn else { return "" }
    if w.status == "out" { return until(resetIn).replacingOccurrences(of: " ", with: "") }
    return w.kind == "session" || resetIn < day ? timeText(at) : weekday(at)
  }

  // "66% OF THE SESSION LEFT · RESETS AT 1:18A — 59% OF THE WEEK LEFT · RESETS SAT"
  private func phrase(_ w: Window) -> String {
    guard w.active, let at = w.resetsAt, let resetIn = w.resetIn else { return "\(w.about.phrase) is fresh" }
    if w.status == "out" { return "\(w.about.phrase) is spent · back in \(until(resetIn))" }
    let when = w.kind == "session" || resetIn < day ? "at \(timeText(at))" : weekday(at)
    return "\(pct(w.left))% of \(w.about.phrase) left · resets \(when)"
  }

  private func dashboard(_ v: BarState, _ t: Double) {
    let s = v.primary
    let w = v.secondary
    dash.clear()
    let asleep = s.status == "out" || w?.status == "out"
    for (r, row) in Clawd.animate(t, working: v.working && !asleep, asleep: asleep).enumerated() {
      for (c, on) in row.enumerated() where on != 0 { dash.set(2 + c, 1 + r, 1, 1) }
    }
    // A 12-hour time ("11:26 PM") makes the first limit's figures longer: like the week's, its
    // meter makes the room, rather than the figures running into the week's meter.
    let firstNumber = "\(pct(v.showUsed ? s.used : s.left))%"
    let firstReset = resetShort(s).uppercased()
    let figuresX = min(textX, week.x - 7 - (PixelFont.width(firstNumber) + 5 + PixelFont.width(firstReset)))
    let barBox = Box(x: bar.x, w: max(20, min(bar.w, figuresX - 6 - bar.x)), top: bar.top, rows: bar.rows)
    meter(barBox, v.showUsed ? s.used : s.left, s.active ? (v.showUsed ? s.elapsed : 1 - s.elapsed) : nil,
          v.working && !asleep, t, days: s.kind == "week" ? 7 : 0)
    let blinkOff = Int(floor(t * 1.6)) % 2 == 1
    var x = text(dash, firstNumber, figuresX, 2)
    if !(s.status == "out" && blinkOff) { text(dash, firstReset, x + 4, 2, 0.6) }
    guard let w else { return }

    let number = "\(pct(v.showUsed ? w.used : w.left))%"
    let reset = resetShort(w).uppercased()
    // The figures need more room when the week resets within the day and shows a time; the
    // meter makes it, rather than being written over.
    let figures = PixelFont.width(number) + 5 + PixelFont.width(reset)
    let meterBox = Box(x: week.x, w: max(20, min(week.w, right - figures - 6 - week.x)), top: week.top, rows: week.rows)
    meter(meterBox, v.showUsed ? w.used : w.left, w.active ? (v.showUsed ? w.elapsed : 1 - w.elapsed) : nil, false, t, days: 7)
    // A text's end is a lamp of spacing past its last glyph, and the reset starts 4 after.
    x = text(dash, number, right - (PixelFont.width(number) + 5 + PixelFont.width(reset)), 2)
    if !(w.status == "out" && blinkOff) { text(dash, reset, x + 4, 2, 0.6) }
  }

  // The sign at `at` lamps along: the dashboard, a gap, the sentence, a gap, the dashboard again.
  private func show(_ at: Int) {
    let rows = MarqueeTheme.rows
    for r in 0..<rows {
      for c in 0..<cols {
        var v: Float = 0
        var o: UInt8 = 0
        let tx = c + at
        if tx < cols {
          v = dash.level[r * cols + tx]; o = dash.orange[r * cols + tx]
        } else if let m = message, tx >= cols + 40, tx < cols + 40 + m.cols {
          v = m.level[r * m.cols + tx - cols - 40]; o = m.orange[r * m.cols + tx - cols - 40]
        } else if let m = message, tx >= cols + 80 + m.cols {
          let x = tx - (cols + 80 + m.cols)
          v = dash.level[r * cols + x]; o = dash.orange[r * cols + x]
        }
        let i = (r * cols + c) * 4
        bytes[i] = UInt8((v * 255).rounded())
        bytes[i + 1] = o != 0 ? 255 : 0
      }
    }
    texture.replace(region: MTLRegionMake2D(0, 0, cols, rows), mipmapLevel: 0, withBytes: bytes, bytesPerRow: cols * 4)
  }

  func render(_ v: BarState, dt: Double, t: Double) {
    dashboard(v, t)
    if nextCrawl == nil { nextCrawl = t + 12 }
    if tapped { nextCrawl = t }
    tapped = false
    if crawl < 0, let next = nextCrawl, t >= next {
      let sentence = [v.primary, v.secondary].compactMap { $0 }.map(phrase).joined(separator: " — ").uppercased()
      let page = Page(cols: PixelFont.width(sentence) + 1)
      text(page, sentence, 0, 2)
      message = page
      crawl = 0
    }
    if crawl >= 0, let m = message {
      crawl += MarqueeTheme.crawlSpeed * dt
      if crawl >= Double(cols + 80 + m.cols) {
        crawl = -1
        nextCrawl = t + MarqueeTheme.crawlEvery
      }
    }
    busy = crawl >= 0
    show(crawl < 0 ? 0 : Int(crawl))
    gpu.frame { encoder in
      encoder.setFragmentTexture(texture, index: 0)
      encoder.setFragmentBytes(&grid, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
      encoder.fullscreen(pass)
    }
  }
}
