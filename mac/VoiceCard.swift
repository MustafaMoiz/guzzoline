// The bar while you talk to a session, across the usage where its title card goes: a red dot and
// the session's name, your voice as a waveform flowing in from the right, and the words heard so
// far after it. Dressed in the theme: ink capsules for Walk, glowing phosphor, hairlines for
// Engraving, lamps for Marquee, an ember at the newest end for Incense. Then a word on how it went.

import AppKit
import CoreText

final class VoiceCard: NSView {
  enum Phase { case off, listening, sending, note }
  private(set) var phase = Phase.off
  // Off the row, letting go cancels: it all greys, and says so.
  var cancelling = false { didSet { if cancelling != oldValue { needsDisplay = true } } }
  // macOS took the touch away, so a pause will send instead of letting go.
  var handsFree = false { didSet { if handsFree != oldValue { needsDisplay = true } } }
  private(set) var loudness: Float = 0 // the latest level, eased: the dot and the Clawd move with it

  private struct Wave {
    var pitch: CGFloat = 4, bar: CGFloat = 2, round = true, lamps = false, ember = false
  }

  private static let red: UInt32 = 0xF2453D
  private var theme = ""
  private var skin = Skin.of("walk")
  private var titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold) as CTFont
  private var wordsFont = NSFont.systemFont(ofSize: 13) as CTFont
  private var capitals = false // Engraving's names are cut in capitals
  private var wave = Wave()
  private var title = ""
  private var words = ""
  private var levels: [Float] = []
  private var position = 0.0 // where the waveform has got to, in levels: the newest at its right
  private var shift: CGFloat = 0 // how far the words have scrolled, to keep the newest in view
  private var sentAt = 0.0
  private var lastTick = 0.0
  private var note = (lead: "", name: "", check: false)
  private var noteUntil = 0.0
  // Where things go, measured when the words or the size change.
  private let titleX: CGFloat = 30
  private var titleMost: CGFloat = 200
  private var waveX: CGFloat = 0, waveW: CGFloat = 0, wordsX: CGFloat = 0, wordsRoom: CGFloat = 0, wordsWidth: CGFloat = 0

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    isHidden = true
    alphaValue = 0
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  // Each theme's type on the bar: a name's, and running words'.
  static func type(for theme: String) -> (name: CTFont, words: CTFont) {
    let plex = { (weight: Int, size: CGFloat) in Fonts.font("ibm-plex-mono-latin-\(weight)-normal.woff", size: size) }
    let barlow = { (weight: Int, size: CGFloat) in Fonts.font("barlow-condensed-latin-\(weight)-normal.woff", size: size) }
    let system = { (weight: NSFont.Weight, size: CGFloat) in NSFont.systemFont(ofSize: size, weight: weight) as CTFont }
    switch theme {
    case "phosphor", "marquee": return (plex(500, 12), plex(400, 12))
    case "engraving": return (barlow(600, 16), barlow(500, 16))
    case "incense": return (system(.medium, 13), system(.regular, 13))
    default: return (system(.semibold, 13), system(.regular, 13))
    }
  }

  func dress(_ theme: String) {
    guard theme != self.theme else { return }
    self.theme = theme
    skin = Skin.of(theme)
    (titleFont, wordsFont) = VoiceCard.type(for: theme)
    capitals = theme == "engraving"
    switch theme {
    case "engraving": wave = Wave(pitch: 3, bar: 1, round: false)
    case "marquee": wave = Wave(lamps: true)
    case "incense": wave = Wave(bar: 1.5, ember: true)
    default: wave = Wave()
    }
    measure()
    needsDisplay = true
  }

  func begin(title: String) {
    self.title = title
    words = ""
    levels = []
    position = 0
    shift = 0
    loudness = 0
    cancelling = false
    handsFree = false
    measure()
    become(.listening)
  }

  func add(_ level: Float) {
    if phase == .listening { levels.append(level) }
  }

  func hear(_ words: String) {
    guard phase == .listening || phase == .sending else { return }
    self.words = words
    measure()
  }

  func send() {
    sentAt = CACurrentMediaTime()
    phase = .sending
    needsDisplay = true
  }

  func show(note lead: String, name: String = "", check: Bool = false, for seconds: Double) {
    note = (lead, name, check)
    noteUntil = CACurrentMediaTime() + seconds
    become(.note)
  }

  func hide() { become(.off) }

  // Each frame: the waveform flows, the dot and the words ease, a note runs out.
  func tick(_ now: Double) {
    let dt = lastTick == 0 ? 1.0 / 60 : min(0.1, now - lastTick)
    lastTick = now
    switch phase {
    case .listening:
      // Twenty levels a second, kept a couple behind the newest so it never runs dry; it starts
      // flowing once the microphone has started.
      if !levels.isEmpty {
        let behind = Double(levels.count) - 2.5 - position
        position += dt * Listener.rate * (1 + max(-0.6, min(0.6, behind * 0.3)))
      }
      loudness += ((levels.last ?? 0) - loudness) * Float(1 - exp(-dt * 16))
      ease(dt)
      needsDisplay = true
    case .sending:
      loudness *= Float(exp(-dt * 8))
      ease(dt)
      if now - sentAt < 0.5 || abs(shift - scrolled) > 0.5 { needsDisplay = true }
    case .note:
      if now >= noteUntil { hide() }
    case .off:
      break
    }
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    measure()
  }

  // MARK: Drawing

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.setFillColor(skin.bg)
    context.fill(bounds)
    context.textMatrix = .identity
    switch phase {
    case .off: break
    case .note: drawNote(context)
    case .listening, .sending: drawTalk(context, now: CACurrentMediaTime())
    }
  }

  private func drawTalk(_ context: CGContext, now: Double) {
    let mid = bounds.height / 2
    let grey = cancelling && phase == .listening
    // The dot: red while it listens, breathing while you're quiet, its halo as loud as you are.
    let dot = CGPoint(x: 16, y: mid)
    if phase == .listening, !grey {
      let r = 4 + 1.2 * CGFloat(0.5 + 0.5 * sin(now * 3.6)) + CGFloat(loudness) * 6
      context.setFillColor(srgb(VoiceCard.red, alpha: 0.16 + 0.22 * CGFloat(loudness)))
      context.fillEllipse(in: CGRect(x: dot.x - r, y: dot.y - r, width: r * 2, height: r * 2))
    }
    context.setFillColor(grey ? skin.muted : srgb(VoiceCard.red))
    context.fillEllipse(in: CGRect(x: dot.x - 4, y: dot.y - 4, width: 8, height: 8))

    glowing(context, on: !grey) {
      put(named(title, grey ? skin.muted : skin.ink, most: titleMost), titleFont, x: titleX, context)
    }
    drawWave(context, now: now, grey: grey)

    context.saveGState()
    context.clip(to: CGRect(x: wordsX, y: 0, width: wordsRoom, height: bounds.height))
    if grey {
      put(line("Let go to cancel", wordsFont, skin.ink), wordsFont, x: wordsX, context)
    } else if words.isEmpty {
      if phase == .listening {
        let hint = handsFree ? "Still listening. Pause when you're done" : "Let go to send, slide off to cancel"
        put(line(hint, wordsFont, skin.muted), wordsFont, x: wordsX, context)
      }
    } else {
      glowing(context, on: true) { put(line(words, wordsFont, skin.ink), wordsFont, x: wordsX - shift, context) }
      if shift > 1 { fadeIn(context, from: wordsX, over: 28) } // what's scrolled away fades
    }
    context.restoreGState()
  }

  private func drawWave(_ context: CGContext, now: Double, grey: Bool) {
    let mid = bounds.height / 2
    let left = waveX, right = waveX + waveW
    let low = max(wave.bar, 1.5), high = bounds.height * 0.72
    // Once sent, the bars settle onto the line.
    var settle: CGFloat = 1
    if phase == .sending {
      let p = CGFloat(min(1, (now - sentAt) / 0.4))
      settle = 1 - p * p * (3 - 2 * p)
    }
    let ink = grey ? skin.muted : skin.ink
    let newest = Int(position.rounded(.down))
    let at = { (i: Int) -> CGFloat in i >= 0 && i < self.levels.count ? CGFloat(self.levels[i]) : 0 }
    glowing(context, on: !grey) {
      // Each bar is one stroke, its fade the context's alpha: nothing is made anew per bar.
      context.setLineWidth(wave.bar)
      context.setLineCap(wave.round ? .round : .butt)
      for i in (newest - Int(waveW / wave.pitch) - 1)...newest {
        let x = right - CGFloat(position - Double(i)) * wave.pitch
        guard x >= left else { continue }
        // Each bar leans on its neighbours, so a voice reads as one shape rather than a barcode.
        let level = at(i) * 0.5 + (at(i - 1) + at(i + 1)) * 0.25
        let height = low + (high - low) * pow(level, 0.8) * settle
        // Older ones dim as they drift left, and fade out at the edge; the newest come in at the right.
        let age = (x - left) / waveW
        context.setAlpha(min(1, age / 0.35) * (0.55 + 0.45 * age) * min(1, (right - x) / wave.pitch + 0.15))
        if wave.lamps {
          for k in -3...3 {
            context.setFillColor(abs(CGFloat(k)) * 3 <= height / 2 + 0.6 ? ink : skin.ghost)
            context.fillEllipse(in: CGRect(x: x - 0.95, y: mid + CGFloat(k) * 3 - 0.95, width: 1.9, height: 1.9))
          }
          continue
        }
        // The newest burn, and cool as they drift away.
        let ember = wave.ember && !grey
        context.setStrokeColor(ember ? mix(skin.muted, skin.accent, max(0, 1 - CGFloat(position - Double(i)) / 12)) : ink)
        // A round cap adds half the bar's width at each end.
        let half = max(0.01, height / 2 - (wave.round ? wave.bar / 2 : 0))
        context.move(to: CGPoint(x: x, y: mid - half))
        context.addLine(to: CGPoint(x: x, y: mid + half))
        context.strokePath()
      }
      context.setAlpha(1)
    }
  }

  private func drawNote(_ context: CGContext) {
    let mid = bounds.height / 2
    var x: CGFloat = 14
    glowing(context, on: true) {
      if note.check {
        context.setStrokeColor(skin.ink)
        context.setLineWidth(1.8)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: CGPoint(x: x, y: mid + 0.2))
        context.addLine(to: CGPoint(x: x + 3.6, y: mid - 3.4))
        context.addLine(to: CGPoint(x: x + 10.5, y: mid + 4))
        context.strokePath()
        x += 19
      }
      let lead = line(note.lead, wordsFont, note.name.isEmpty ? skin.ink : skin.muted)
      put(lead, wordsFont, x: x, context)
      if !note.name.isEmpty {
        let at = x + width(lead) + (capitals ? 7 : 5)
        put(named(note.name, skin.ink, most: bounds.width - 12 - at), titleFont, x: at, context)
      }
    }
  }

  // MARK: Helpers

  private var scrolled: CGFloat { max(0, wordsWidth - wordsRoom) }

  private func ease(_ dt: Double) {
    shift += (scrolled - shift) * CGFloat(1 - exp(-dt * 15))
  }

  private func measure() {
    let pad: CGFloat = 12
    titleMost = min(220, bounds.width * 0.28)
    let named = min(titleMost, width(self.named(title, skin.ink, most: .greatestFiniteMagnitude)))
    waveX = titleX + named + 20
    waveW = max(120, min(300, (bounds.width - pad - waveX) * 0.42))
    wordsX = waveX + waveW + 18
    wordsRoom = max(40, bounds.width - pad - wordsX)
    wordsWidth = words.isEmpty ? 0 : width(line(words, wordsFont, skin.ink))
  }

  // A session's name as the theme sets it, cut short with an ellipsis when it must be.
  private func named(_ name: String, _ colour: CGColor, most: CGFloat) -> CTLine {
    let kern: CGFloat = capitals ? 1.2 : 0
    let full = line(capitals ? name.uppercased() : name, titleFont, colour, kern: kern)
    guard width(full) > most, let cut = CTLineCreateTruncatedLine(full, Double(most), .end, line("…", titleFont, colour)) else { return full }
    return cut
  }

  private func line(_ text: String, _ font: CTFont, _ colour: CGColor, kern: CGFloat = 0) -> CTLine {
    var attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour,
    ]
    if kern != 0 { attributes[NSAttributedString.Key(kCTKernAttributeName as String)] = kern }
    return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
  }

  private func width(_ line: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) }

  // With its capitals centred on the bar, on a whole pixel.
  private func put(_ line: CTLine, _ font: CTFont, x: CGFloat, _ context: CGContext) {
    context.textPosition = CGPoint(x: x, y: ((bounds.height - CTFontGetCapHeight(font)) / 2 * 2).rounded() / 2)
    CTLineDraw(line, context)
  }

  // The theme's glow, where it has one, around what's drawn.
  private func glowing(_ context: CGContext, on: Bool, _ draw: () -> Void) {
    guard on, let glow = skin.glow else { return draw() }
    context.saveGState()
    context.setShadow(offset: .zero, blur: 6, color: glow)
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    draw()
    context.endTransparencyLayer()
    context.restoreGState()
  }

  private func fadeIn(_ context: CGContext, from x: CGFloat, over: CGFloat) {
    guard let clear = skin.bg.copy(alpha: 0),
          let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [skin.bg, clear] as CFArray, locations: [0, 1]) else { return }
    context.drawLinearGradient(gradient, start: CGPoint(x: x, y: 0), end: CGPoint(x: x + over, y: 0), options: [])
  }

  private func mix(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> CGColor {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let p = a.converted(to: space, intent: .defaultIntent, options: nil)?.components,
          let q = b.converted(to: space, intent: .defaultIntent, options: nil)?.components,
          p.count >= 3, q.count >= 3 else { return a }
    return CGColor(srgbRed: p[0] + (q[0] - p[0]) * t, green: p[1] + (q[1] - p[1]) * t, blue: p[2] + (q[2] - p[2]) * t, alpha: 1)
  }

  // Shown and hidden with a fade, and crossfaded from one phase to the next.
  private func become(_ next: Phase) {
    let was = phase
    phase = next
    needsDisplay = true
    guard let layer else {
      isHidden = next == .off
      return
    }
    if was == .off, next != .off {
      isHidden = false
      fade(layer, to: 1, 0.16)
    } else if next == .off, was != .off {
      fade(layer, to: 0, 0.3) { [weak self] in
        if self?.phase == .off { self?.isHidden = true }
      }
    } else if next != was {
      let swap = CATransition()
      swap.type = .fade
      swap.duration = 0.2
      layer.add(swap, forKey: "swap")
    }
  }

  private func fade(_ layer: CALayer, to opacity: Float, _ duration: Double, then: (() -> Void)? = nil) {
    let from = layer.presentation()?.opacity ?? layer.opacity
    CATransaction.begin()
    CATransaction.setCompletionBlock(then)
    let animation = CABasicAnimation(keyPath: "opacity")
    animation.fromValue = from
    animation.toValue = opacity
    animation.duration = duration
    alphaValue = CGFloat(opacity)
    layer.add(animation, forKey: "fade")
    CATransaction.commit()
  }
}

// In the theme's place until there are numbers to draw: what's missing (a sign-in, or the first
// read), in the theme's type and colours.
final class StatusView: NSView {
  var text = "" { didSet { if text != oldValue { needsDisplay = true } } }
  private var skin = Skin.of("walk")
  private var font = VoiceCard.type(for: "walk").words

  func dress(_ theme: String) {
    skin = Skin.of(theme)
    font = VoiceCard.type(for: theme).words
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.setFillColor(skin.bg)
    context.fill(bounds)
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): skin.muted,
    ]
    var line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    let room = Double(bounds.width - 28)
    if CTLineGetTypographicBounds(line, nil, nil, nil) > room,
       let cut = CTLineCreateTruncatedLine(line, room, .end, CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))) {
      line = cut
    }
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: 14, y: ((bounds.height - CTFontGetCapHeight(font)) / 2 * 2).rounded() / 2)
    CTLineDraw(line, context)
  }
}
