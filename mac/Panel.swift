// The panel under the menu bar icon, in place of a menu; a port of the gallery's panel.html. Your
// sessions, when the bar shows, its sound, its theme (each the Touch Bar itself, live, with your
// crew), and the app's own settings, dressed in the theme you've picked. Clicking in it never
// closes it; a click outside, Escape, or the icon again does. Every height is fixed, so no
// theme's type can change its size.

import AppKit
import CoreText
import Metal
import QuartzCore

// One theme's dress for the panel: its black and its ink, its type, and the texture of the line
// beside each heading.
struct Skin {
  enum Leader { case dots, segments, hatching, lamps, ember }
  let bg, ink, muted, ghost, edge, frame, hover, card, accent, leaderColor: CGColor
  let title, head: CTFont
  let tracking: CGFloat // the headings' letter spacing, in ems
  let leader: Leader
  let glow: CGColor? // the theme's glow on its type
  let lampHeads: Bool // headings made of lamps

  static func of(_ theme: String) -> Skin {
    let plex = { (weight: Int, size: CGFloat) in Fonts.font("ibm-plex-mono-latin-\(weight)-normal.woff", size: size) }
    let barlow = { (weight: Int, size: CGFloat) in Fonts.font("barlow-condensed-latin-\(weight)-normal.woff", size: size) }
    let system = { (weight: NSFont.Weight, size: CGFloat) in NSFont.systemFont(ofSize: size, weight: weight) as CTFont }
    switch theme {
    case "phosphor":
      return Skin(bg: srgb(0x050302), ink: srgb(0xFFA76D), muted: srgb(0x9A5C3B), ghost: srgb(0x3C2415), edge: srgb(0x2A190E),
                  frame: srgb(0x2C1A0F), hover: srgb(0x140B06), card: srgb(0x0E0805), accent: srgb(0xFFA76D), leaderColor: srgb(0x3A2213),
                  title: plex(500, 11.5), head: plex(500, 9.5), tracking: 0.12, leader: .segments,
                  glow: srgb(0xFF7832, alpha: 0.5), lampHeads: false)
    case "engraving":
      return Skin(bg: srgb(0x040404), ink: srgb(0xF3F0EA), muted: srgb(0x8E8B85), ghost: srgb(0x3E3C38), edge: srgb(0x262626),
                  frame: srgb(0x2A2A2A), hover: srgb(0x111111), card: srgb(0x0D0D0D), accent: srgb(0xF3F0EA), leaderColor: srgb(0x6F6C67),
                  title: barlow(600, 15), head: barlow(500, 11), tracking: 0.16, leader: .hatching, glow: nil, lampHeads: false)
    case "marquee":
      return Skin(bg: srgb(0x060504), ink: srgb(0xFFE4C8), muted: srgb(0x93806D), ghost: srgb(0x3F352C), edge: srgb(0x2A231D),
                  frame: srgb(0x2A231D), hover: srgb(0x100D0B), card: srgb(0x0F0C0A), accent: srgb(0xFFE4C8), leaderColor: srgb(0x6E5D4D),
                  title: plex(500, 11.5), head: plex(500, 10.5), tracking: 0.12, leader: .lamps,
                  glow: srgb(0xFFCD96, alpha: 0.4), lampHeads: true)
    case "incense":
      return Skin(bg: srgb(0x0B0A09), ink: srgb(0xDED7CC), muted: srgb(0x766F65), ghost: srgb(0x36322E), edge: srgb(0x24211E),
                  frame: srgb(0x26231F), hover: srgb(0x13110F), card: srgb(0x12100E), accent: srgb(0xFF7A3D), leaderColor: srgb(0x2C2926),
                  title: system(.regular, 12.5), head: plex(400, 9.5), tracking: 0.12, leader: .ember, glow: nil, lampHeads: false)
    default:
      return Skin(bg: srgb(0x000000), ink: srgb(0xF2EFE9), muted: srgb(0x8B877F), ghost: srgb(0x3A3835), edge: srgb(0x262422),
                  frame: srgb(0x262422), hover: srgb(0x121110), card: srgb(0x0D0C0B), accent: srgb(0xF2EFE9), leaderColor: srgb(0x4D4A45),
                  title: system(.medium, 12.5), head: plex(500, 9.5), tracking: 0.12, leader: .dots, glow: nil, lampHeads: false)
    }
  }
}

// What the panel shows, from the app.
struct PanelState {
  var sessions: [(session: Session, onBar: Bool)] = []
  var showing = "front"
  var muted = false
  var tone = "Glass" // the sound picked, kept while muted
  var theme = "walk"
  var login: Bool? // nil where macOS can't say (before 13)
  var awake = false
}

// A theme's card: the Touch Bar as it would look in it, crew and all, drawn live.
final class Preview {
  let view = NSView()
  private var bar: NativeTheme?
  private var crew: Crew?
  private(set) var count = -1

  init() {
    view.wantsLayer = true
    view.layer = CALayer()
    view.layer?.backgroundColor = CGColor.black
  }

  // Laid out as the bar is beside `count` sessions, `size` points across; the new picture fades
  // in over the old.
  func build(device: MTLDevice, make: (MTLDevice, Int) -> NativeTheme?, count: Int, size: CGSize, fade: Bool) {
    if fade {
      let transition = CATransition()
      transition.type = .fade
      transition.duration = 0.35
      view.layer?.add(transition, forKey: "relayout")
    }
    view.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
    let crewWidth = Crew.width(count)
    let width = barWidth - crewWidth
    let scale = size.width / CGFloat(barWidth)
    bar = make(device, width)
    crew = count > 0 ? Crew(device: device, count: count) : nil
    if let layer = bar?.layer {
      layer.frame = CGRect(x: 0, y: 0, width: CGFloat(width) * scale, height: size.height)
      view.layer?.addSublayer(layer)
    }
    if let layer = crew?.layer {
      layer.frame = CGRect(x: CGFloat(width) * scale, y: 0, width: CGFloat(crewWidth) * scale, height: size.height)
      view.layer?.addSublayer(layer)
    }
    self.count = count
  }

  func render(_ state: BarState, sessions: [Session], dt: Double, t: Double) {
    bar?.render(state, dt: dt, t: t)
    crew?.render(sessions, dt: dt, t: t)
  }
}

final class PanelView: NSView, NSViewToolTipOwner {
  enum Hit: Equatable { case session(String), showing(String), mute, tone(String), theme(String), login, awake, quit }

  static let width: CGFloat = 760
  private static let pad: CGFloat = 16
  private static let column: CGFloat = 380
  private static let rowHeight: CGFloat = 30 // a session
  private static let choiceHeight: CGFloat = 26 // a choice, a setting, the sounds

  var skin = Skin.of("walk")
  private(set) var state = PanelState()
  private var regions: [(rect: CGRect, hit: Hit, tip: String?)] = []
  private var heads: [(title: String, y: CGFloat, x0: CGFloat, x1: CGFloat)] = []
  private var rules: [CGRect] = []
  private var glyphs: [(rect: CGRect, session: Session, onBar: Bool, seed: Double)] = []
  private var cards: [(id: String, rect: CGRect)] = []
  private var hovered: Hit?
  private var tracking: NSTrackingArea?
  var previews: [String: Preview] = [:]

  override var isFlipped: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  // Every click is the panel's, the live bars' included.
  override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

  // Lays the panel out for what it shows; returns its height.
  @discardableResult
  func arrange(_ state: PanelState) -> CGFloat {
    self.state = state
    regions = []
    heads = []
    rules = []
    glyphs = []
    cards = []
    let pad = PanelView.pad, column = PanelView.column, width = PanelView.width
    let top: CGFloat = 2
    func head(_ title: String, _ y: CGFloat, _ x0: CGFloat, _ x1: CGFloat) -> CGFloat {
      heads.append((title, y + 12, x0, x1))
      return y + 12 + 22 + 4
    }

    // Sessions: a click shows or hides one; its Clawd says which, and what it's doing.
    var y = head("Sessions", top, pad, column - pad)
    for (i, (session, onBar)) in state.sessions.enumerated() {
      let rect = CGRect(x: 6, y: y, width: column - 12, height: PanelView.rowHeight)
      regions.append((rect, .session(session.id), session.title))
      glyphs.append((CGRect(x: rect.maxX - 10 - 17, y: rect.midY - 7, width: 17, height: 14), session, onBar, Double(i) * 0.61))
      y += PanelView.rowHeight
    }
    let left = y + 14

    // When the bar shows, and its sound.
    y = head("Show the bar", top, column + pad, width - pad)
    for id in ["front", "open", "always"] {
      regions.append((CGRect(x: column + 6, y: y, width: column - 12, height: PanelView.choiceHeight), .showing(id), nil))
      y += PanelView.choiceHeight
    }
    y = head("Sound", y, column + pad, width - pad)
    regions.append((CGRect(x: column + pad - 2, y: y + 5, width: 20, height: 16), .mute, state.muted ? "Sound off" : "Sound on"))
    for (i, name) in App.sounds.enumerated() {
      regions.append((CGRect(x: column + pad + 28 + CGFloat(i) * 20, y: y + 6, width: 14, height: 14), .tone(name), name))
    }
    let right = y + PanelView.choiceHeight + 14
    let split = max(left, right)
    rules.append(CGRect(x: column, y: 0, width: 1, height: split))
    rules.append(CGRect(x: 0, y: split, width: width, height: 1))

    // Themes: each the Touch Bar itself, as wide as the panel.
    y = head("Theme", split, pad, width - pad)
    let cardWidth = width - 2 * pad
    let barHeight = ((cardWidth - 10) * CGFloat(barHeight) / CGFloat(barWidth) * 2).rounded() / 2
    for (id, name) in themes {
      let rect = CGRect(x: pad, y: y, width: cardWidth, height: barHeight + 10)
      cards.append((id, rect))
      regions.append((rect, .theme(id), name))
      y += rect.height + 6
    }
    y += 8
    rules.append(CGRect(x: 0, y: y, width: width, height: 1))

    // The app's own settings.
    y += 8
    var x: CGFloat = 6
    if state.login != nil {
      regions.append((CGRect(x: x, y: y, width: 130, height: PanelView.choiceHeight), .login, nil))
      x += 138
    }
    regions.append((CGRect(x: x, y: y, width: 240, height: PanelView.choiceHeight), .awake,
                    "Keeps the Mac awake with the lid shut while an agent works"))
    regions.append((CGRect(x: width - 6 - 36, y: y, width: 36, height: PanelView.choiceHeight), .quit, "Quit Guzzoline"))
    let height = y + PanelView.choiceHeight + 8

    removeAllToolTips()
    for region in regions where region.tip != nil { addToolTip(region.rect, owner: self, userData: nil) }
    for (id, rect) in cards { previews[id]?.view.frame = rect.insetBy(dx: 5, dy: 5) }
    needsDisplay = true
    return height
  }

  func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
    regions.first { $0.rect.contains(point) }?.tip ?? ""
  }

  // The live bars, rebuilt when the number of sessions on the bar changes.
  func buildPreviews(device: MTLDevice, make: (String) -> ((MTLDevice, Int) -> NativeTheme?)?, count: Int) {
    for (id, rect) in cards {
      let preview = previews[id] ?? Preview()
      if previews[id] == nil {
        previews[id] = preview
        addSubview(preview.view)
      }
      preview.view.frame = rect.insetBy(dx: 5, dy: 5)
      guard preview.count != count, let maker = make(id) else { continue }
      preview.build(device: device, make: maker, count: count, size: preview.view.frame.size, fade: preview.count >= 0)
    }
  }

  func releasePreviews() {
    previews.values.forEach { $0.view.removeFromSuperview() }
    previews = [:]
  }

  // Only the Clawds move; they're redrawn, the rest isn't.
  func animate() {
    for glyph in glyphs where glyph.onBar { setNeedsDisplay(glyph.rect.insetBy(dx: -1, dy: -4)) }
  }

  // MARK: Drawing

  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: 2, cornerHeight: 2, transform: nil))
    ctx.clip()
    ctx.setFillColor(skin.bg)
    ctx.fill(bounds)
    ctx.setFillColor(skin.frame)
    rules.forEach { ctx.fill($0) }

    for head in heads { drawHead(head.title, y: head.y, x0: head.x0, x1: head.x1, ctx) }

    let t = CACurrentMediaTime()
    for region in regions {
      let hover = region.hit == hovered
      switch region.hit {
      case .session(let id):
        guard let row = state.sessions.first(where: { $0.session.id == id }) else { break }
        let (session, onBar) = row
        if hover { fill(region.rect, skin.hover, ctx) }
        let title = text(session.title, skin.title, onBar ? skin.ink : skin.muted, maxWidth: region.rect.width - 20 - 17 - 12)
        draw(title, x: region.rect.minX + 10, midY: region.rect.midY, font: skin.title, ctx)
      case .showing(let id):
        if hover { fill(region.rect, skin.hover, ctx) }
        let label = ["front": "Only in Claude", "open": "While Claude is open", "always": "In every app"][id] ?? id
        radio(at: CGPoint(x: region.rect.minX + 10, y: region.rect.midY), on: id == state.showing, ctx)
        draw(text(label, skin.title, skin.ink), x: region.rect.minX + 31, midY: region.rect.midY, font: skin.title, ctx)
      case .mute:
        speaker(in: region.rect, muted: state.muted, ctx)
      case .tone(let name):
        let chosen = name == state.tone
        let rect = region.rect.insetBy(dx: 0.5, dy: 0.5)
        ctx.setAlpha(state.muted ? 0.35 : 1)
        if chosen {
          fill(region.rect, skin.accent, ctx)
        } else {
          ctx.setStrokeColor(hover ? skin.ink : skin.muted)
          ctx.setLineWidth(1)
          ctx.stroke(rect)
        }
        ctx.setAlpha(1)
      case .theme(let id):
        fill(region.rect, skin.card, ctx)
        ctx.setStrokeColor(id == state.theme ? skin.accent : hover ? skin.muted : skin.frame)
        ctx.setLineWidth(1)
        ctx.stroke(region.rect.insetBy(dx: 0.5, dy: 0.5))
      case .login, .awake:
        if hover { fill(region.rect, skin.hover, ctx) }
        let on = region.hit == .login ? state.login == true : state.awake
        check(at: CGPoint(x: region.rect.minX + 10, y: region.rect.midY), on: on, ctx)
        let label = region.hit == .login ? "Open at login" : "Stay awake with the lid shut"
        draw(text(label, skin.title, skin.ink), x: region.rect.minX + 31, midY: region.rect.midY, font: skin.title, ctx)
      case .quit:
        power(in: region.rect, color: hover ? skin.ink : skin.muted, ctx)
      }
    }

    for glyph in glyphs { drawClawd(glyph, t: t, ctx) }
    ctx.restoreGState()
    ctx.setStrokeColor(skin.edge)
    ctx.setLineWidth(1)
    ctx.addPath(CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 2, cornerHeight: 2, transform: nil))
    ctx.strokePath()
  }

  private func fill(_ rect: CGRect, _ color: CGColor, _ ctx: CGContext) {
    ctx.setFillColor(color)
    ctx.fill(rect)
  }

  private func text(_ string: String, _ font: CTFont, _ color: CGColor, tracking: CGFloat = 0, maxWidth: CGFloat? = nil) -> CTLine {
    var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    if tracking != 0 { attributes[.kern] = tracking * CTFontGetSize(font) }
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    guard let maxWidth, CTLineGetTypographicBounds(line, nil, nil, nil) > Double(maxWidth) else { return line }
    let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
    return CTLineCreateTruncatedLine(line, Double(maxWidth), .end, ellipsis) ?? line
  }

  // A line with its capitals centred on `midY`, glowing if the theme's type does.
  private func draw(_ line: CTLine, x: CGFloat, midY: CGFloat, font: CTFont, _ ctx: CGContext) {
    ctx.saveGState()
    if let glow = skin.glow { ctx.setShadow(offset: .zero, blur: 7, color: glow) }
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.textPosition = CGPoint(x: x, y: ((midY + CTFontGetCapHeight(font) / 2) * 2).rounded() / 2)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
  }

  // A heading: its name in small capitals, and a line in the theme's texture to the column's end.
  private func drawHead(_ title: String, y: CGFloat, x0: CGFloat, x1: CGFloat, _ ctx: CGContext) {
    let midY = y + 11
    let line = text(title.uppercased(), skin.head, skin.lampHeads ? skin.ink : skin.muted, tracking: skin.tracking)
    let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    draw(line, x: x0, midY: midY, font: skin.head, ctx)
    if skin.lampHeads {
      // Lamps: the letters show through a grid of dots, a pixel each with a pixel between.
      ctx.setFillColor(skin.bg)
      let box = CGRect(x: x0 - 1, y: midY - 8, width: width + 2, height: 16)
      var gx = box.minX.rounded(.down)
      while gx < box.maxX { ctx.fill(CGRect(x: gx + 0.5, y: box.minY, width: 0.5, height: box.height)); gx += 1 }
      var gy = box.minY.rounded(.down)
      while gy < box.maxY { ctx.fill(CGRect(x: box.minX, y: gy + 0.5, width: box.width, height: 0.5)); gy += 1 }
    }
    leader(from: x0 + width + 10, to: x1, midY: midY, ctx)
  }

  private func leader(from x0: CGFloat, to x1: CGFloat, midY: CGFloat, _ ctx: CGContext) {
    ctx.setFillColor(skin.leaderColor)
    switch skin.leader {
    case .dots:
      var x = x0.rounded()
      while x + 2 <= x1 { ctx.fill(CGRect(x: x, y: midY.rounded() - 1, width: 2, height: 2)); x += 8 }
    case .segments:
      var x = x0.rounded()
      while x + 7 <= x1 { ctx.fill(CGRect(x: x, y: midY.rounded() - 1.5, width: 7, height: 3)); x += 9 }
    case .hatching:
      let band = CGRect(x: x0, y: midY.rounded() - 3, width: x1 - x0, height: 6)
      ctx.saveGState()
      ctx.clip(to: band)
      ctx.setStrokeColor(skin.leaderColor)
      ctx.setLineWidth(1)
      var x = band.minX - band.height
      while x < band.maxX {
        ctx.move(to: CGPoint(x: x, y: band.maxY))
        ctx.addLine(to: CGPoint(x: x + band.height, y: band.minY))
        x += 4
      }
      ctx.strokePath()
      ctx.restoreGState()
    case .lamps:
      var x = x0.rounded() + 1
      while x + 1 <= x1 { ctx.fillEllipse(in: CGRect(x: x - 0.9, y: midY.rounded() - 0.9, width: 1.8, height: 1.8)); x += 5 }
    case .ember:
      ctx.fill(CGRect(x: x0, y: midY.rounded(), width: x1 - x0, height: 1))
      ctx.saveGState()
      ctx.setShadow(offset: .zero, blur: 6, color: srgb(0xFF6E32, alpha: 0.7))
      ctx.setFillColor(srgb(0xFF7A3D))
      ctx.fillEllipse(in: CGRect(x: x1 - 3, y: midY.rounded() - 1, width: 3, height: 3))
      ctx.restoreGState()
    }
  }

  private func radio(at p: CGPoint, on: Bool, _ ctx: CGContext) {
    let rect = CGRect(x: p.x, y: p.y - 5.5, width: 11, height: 11)
    ctx.setLineWidth(1)
    ctx.setStrokeColor(on ? skin.accent : skin.muted)
    ctx.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
    if on {
      ctx.setFillColor(skin.accent)
      ctx.fillEllipse(in: rect.insetBy(dx: 3.5, dy: 3.5))
    }
  }

  private func check(at p: CGPoint, on: Bool, _ ctx: CGContext) {
    let rect = CGRect(x: p.x, y: p.y - 5.5, width: 11, height: 11)
    if on {
      ctx.setFillColor(skin.accent)
      ctx.fill(rect)
      ctx.setStrokeColor(skin.bg)
      ctx.setLineWidth(1.5)
      ctx.move(to: CGPoint(x: rect.minX + 2.5, y: rect.midY))
      ctx.addLine(to: CGPoint(x: rect.minX + 4.7, y: rect.maxY - 3))
      ctx.addLine(to: CGPoint(x: rect.maxX - 2.3, y: rect.minY + 3))
      ctx.strokePath()
    } else {
      ctx.setStrokeColor(skin.muted)
      ctx.setLineWidth(1)
      ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
    }
  }

  // The speaker, with its waves, or crossed out while muted (from panel.js's 16-point icons).
  private func speaker(in rect: CGRect, muted: Bool, _ ctx: CGContext) {
    ctx.saveGState()
    ctx.translateBy(x: rect.minX + 2, y: rect.midY - 8)
    ctx.setFillColor(muted ? skin.muted : skin.ink)
    ctx.setStrokeColor(muted ? skin.muted : skin.ink)
    ctx.setLineWidth(1.3)
    ctx.move(to: CGPoint(x: 1, y: 5)); ctx.addLine(to: CGPoint(x: 4, y: 5)); ctx.addLine(to: CGPoint(x: 8, y: 1.5))
    ctx.addLine(to: CGPoint(x: 8, y: 14.5)); ctx.addLine(to: CGPoint(x: 4, y: 11)); ctx.addLine(to: CGPoint(x: 1, y: 11))
    ctx.closePath()
    ctx.fillPath()
    if muted {
      ctx.move(to: CGPoint(x: 10.5, y: 5.5)); ctx.addLine(to: CGPoint(x: 15.5, y: 10.5))
      ctx.move(to: CGPoint(x: 15.5, y: 5.5)); ctx.addLine(to: CGPoint(x: 10.5, y: 10.5))
    } else {
      ctx.addArc(center: CGPoint(x: 9, y: 8), radius: 3.2, startAngle: -.pi / 3, endAngle: .pi / 3, clockwise: false)
      ctx.move(to: CGPoint(x: 9 + 6 * cos(-CGFloat.pi / 2.8), y: 8 + 6 * sin(-CGFloat.pi / 2.8)))
      ctx.addArc(center: CGPoint(x: 9, y: 8), radius: 6, startAngle: -.pi / 2.8, endAngle: .pi / 2.8, clockwise: false)
    }
    ctx.strokePath()
    ctx.restoreGState()
  }

  private func power(in rect: CGRect, color: CGColor, _ ctx: CGContext) {
    let c = CGPoint(x: rect.maxX - 18, y: rect.midY)
    ctx.saveGState()
    ctx.setStrokeColor(color)
    ctx.setLineWidth(1.4)
    ctx.move(to: CGPoint(x: c.x, y: c.y - 6.5))
    ctx.addLine(to: CGPoint(x: c.x, y: c.y - 0.5))
    ctx.move(to: CGPoint(x: c.x + 5.5 * cos(-CGFloat.pi * 0.3), y: c.y + 5.5 * sin(-CGFloat.pi * 0.3)))
    ctx.addArc(center: c, radius: 5.5, startAngle: -.pi * 0.3, endAngle: -.pi * 0.7, clockwise: false)
    ctx.strokePath()
    ctx.restoreGState()
  }

  // A session's Clawd as the bar acts it out, a unit to a point: walking, hopping with its arms
  // up, cheering, or asleep; still and dim while it's off the bar.
  private func drawClawd(_ glyph: (rect: CGRect, session: Session, onBar: Bool, seed: Double), t: Double, _ ctx: CGContext) {
    let s = glyph.session, seed = glyph.seed
    var grid = Clawd.pose()
    var lift = 0.0
    var colour = skin.ghost
    if glyph.onBar {
      let colours: [Session.State: UInt32] = [.working: 0xE0443E, .asking: 0xF5A623, .done: 0x4FB477, .failed: 0x4FB477, .idle: 0x4A86D8]
      colour = srgb(colours[s.state] ?? 0x4A86D8, alpha: s.state == .idle ? 0.62 : 1)
      switch s.state {
      case .working:
        grid = Clawd.animate(t + seed, working: true, asleep: false)
      case .asking:
        let p = (t + seed).truncatingRemainder(dividingBy: 1.4) / 1.4
        grid = Clawd.pose(arms: Int((t + seed) * 4) % 2 == 0 ? "up" : "down")
        lift = p < 0.32 ? sin(p / 0.32 * .pi) * 2 : 0
      case .done:
        let p = (t + seed).truncatingRemainder(dividingBy: 3) / 3
        if Date().timeIntervalSince1970 - s.since < 120, p < 0.16 {
          grid = Clawd.pose(arms: "up")
          lift = sin(p / 0.16 * .pi) * 1.5
        } else {
          grid = Clawd.animate(t + seed, working: false, asleep: false)
        }
      case .failed:
        grid = Clawd.animate(t + seed, working: false, asleep: false)
      case .idle:
        grid = Clawd.pose(eyes: "closed")
      }
    }
    ctx.setFillColor(colour)
    let origin = CGPoint(x: glyph.rect.minX, y: glyph.rect.minY + 2 - lift.rounded())
    for (r, row) in grid.enumerated() {
      for (c, on) in row.enumerated() where on != 0 { ctx.fill(CGRect(x: origin.x + CGFloat(c), y: origin.y + CGFloat(r), width: 1, height: 1)) }
    }
  }

  // MARK: Pointer

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseMoved(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    let hit = regions.first { $0.rect.contains(p) }?.hit
    if hit != hovered {
      hovered = hit
      needsDisplay = true
    }
  }

  override func mouseExited(with event: NSEvent) {
    hovered = nil
    needsDisplay = true
  }

  var onHit: ((Hit) -> Void)?

  override func mouseDown(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    if let hit = regions.first(where: { $0.rect.contains(p) })?.hit { onHit?(hit) }
  }
}

// A panel that can take Escape without making Guzzoline the frontmost app, so the Touch Bar
// stays as it is.
final class PanelWindow: NSPanel {
  override var canBecomeKey: Bool { true }
}

final class Panel {
  private let window: PanelWindow
  let view = PanelView()
  private var timer: Timer?
  private var clicks: Any?
  private var keys: Any?
  private var last = CACurrentMediaTime()
  private var frames = 0
  private weak var button: NSStatusBarButton?
  var state: () -> PanelState = { PanelState() }
  var bar: () -> BarState? = { nil }
  var crew: () -> [Session] = { [] }
  var themeMaker: (String) -> ((MTLDevice, Int) -> NativeTheme?)? = { _ in nil }
  var device: MTLDevice?
  var onOpen: (() -> Void)?

  var isOpen: Bool { window.isVisible }

  init() {
    window = PanelWindow(contentRect: NSRect(x: 0, y: 0, width: PanelView.width, height: 400),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    window.isFloatingPanel = true
    window.level = .popUpMenu
    window.hidesOnDeactivate = false
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
    window.contentView = view
  }

  func toggle(below button: NSStatusBarButton) {
    if isOpen { close() } else { open(below: button) }
  }

  func open(below button: NSStatusBarButton) {
    self.button = button
    refresh()
    if let device { view.buildPreviews(device: device, make: themeMaker, count: crew().count) }
    window.orderFrontRegardless()
    window.makeKey()
    last = CACurrentMediaTime()
    let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    // A click anywhere else closes it; so does Escape.
    clicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.close() }
    keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard event.keyCode == 53 else { return event }
      self?.close()
      return nil
    }
    onOpen?()
  }

  func close() {
    timer?.invalidate()
    timer = nil
    for monitor in [clicks, keys].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
    clicks = nil
    keys = nil
    window.orderOut(nil)
    view.releasePreviews()
  }

  // What it shows changed: laid out again, the live bars rebuilt if the crew's size did.
  func refresh() {
    let state = self.state()
    view.skin = Skin.of(state.theme)
    let height = view.arrange(state)
    window.setContentSize(NSSize(width: PanelView.width, height: height))
    place()
    if isOpen, let device { view.buildPreviews(device: device, make: themeMaker, count: crew().count) }
  }

  // Under the icon, kept on its screen.
  private func place() {
    guard let button, let buttonWindow = button.window, let screen = buttonWindow.screen ?? NSScreen.main else { return }
    let icon = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
    let size = window.frame.size
    let x = min(max(icon.midX - size.width / 2, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
    window.setFrameOrigin(NSPoint(x: x.rounded(), y: icon.minY - 5 - size.height))
  }

  private func tick() {
    let now = CACurrentMediaTime()
    let dt = min(0.1, now - last)
    last = now
    if let state = bar() {
      let sessions = crew()
      view.previews.values.forEach { $0.render(state, sessions: sessions, dt: dt, t: now) }
    }
    frames += 1
    if frames % 2 == 0 { view.animate() }
  }
}
