// Your sessions as a crew of Clawds to the right of the usage, a port of src/sessions.js: one
// each, in the order the sessions began, acting out its session and coloured by it. Red, walking,
// while it works; amber, hopping and waving, while it waits on you; green for a while once it has
// finished (cheering at first, or shaking its head if it failed); blue, dimmed and dozing, after
// that. One under a finger stands on a lit line.

import AppKit
import CoreText
import Metal
import simd

final class Crew {
  private static let unit: Float = 3 // one mascot unit, in pixels
  private static let slot = 72 // each Clawd's share of the row
  private static let pad = 22
  private static let feet: Float = 15 // where they stand, from the bottom
  private static let colour: [Session.State: UInt32] = [.working: 0xE0443E, .asking: 0xF5A623, .done: 0x4FB477, .failed: 0x4FB477, .idle: 0x4A86D8]
  // How bright each is: the one waiting on you outshines the rest.
  private static let light: [Session.State: Float] = [.asking: 1.1, .working: 1, .done: 1, .failed: 1, .idle: 0.55]

  static func width(_ count: Int) -> Int { count > 0 ? pad * 2 + min(count, Sessions.most) * slot - 12 : 0 }
  // The Clawd at a point along the row, in pixels.
  static func slot(at x: CGFloat) -> Int { Int(floor((x - CGFloat(pad) + 6) / CGFloat(slot))) }

  private let gpu: GPU
  private let cubes: MTLRenderPipelineState
  private let depth: MTLDepthStencilState
  private let mesh: MTLBuffer
  private let instances: MTLBuffer
  private var scene: Voxel.Scene
  private var bodies = [SIMD4<Float>](repeating: .zero, count: Sessions.most) // linear, and lit; zero before the first frame
  var touched = -1
  private(set) var busy = false
  var layer: CALayer { gpu.layer }

  init?(device: MTLDevice, count: Int) {
    let width = Crew.width(count)
    guard width > 0, let gpu = GPU(device: device, width: width, source: Voxel.shaders, depth: true, samples: 4),
          let cubes = gpu.pipeline(vertex: "cube", fragment: "shade"),
          let depth = gpu.depthState(test: true) else { return nil }
    self.gpu = gpu
    self.cubes = cubes
    self.depth = depth
    mesh = Voxel.mesh(device)
    instances = device.makeBuffer(length: (Sessions.most * Voxel.cubesPerFigure + Sessions.most) * MemoryLayout<Voxel.Cube>.stride,
                                  options: .storageModeShared)!
    scene = Voxel.scene(width: width)
  }

  // How a state moves a Clawd at a moment, `age` seconds into it: a hop, a squash on landing, arms
  // up, a turn of the head. `moving` is whether any of it is under way.
  private struct Act {
    var walking = false, phase = 0.0, hop = 0.0, squash = 1.0, wave = 0.0, cheer = 0.0, yaw = 0.0
    var moving = false

    init(_ state: Session.State, _ t: Double, _ seed: Double, age: Double) {
      let fresh = age < 120 // a finished one celebrates, or shakes its head, for two minutes
      switch state {
      case .working:
        walking = true
        phase = t * 8 + seed * 4
        yaw = 0.45
        moving = true
      case .asking:
        let p = (t + seed).truncatingRemainder(dividingBy: 1.4) / 1.4
        hop = p < 0.32 ? sin(p / 0.32 * .pi) * 8 : 0
        squash = p >= 0.32 && p < 0.44 ? 0.88 + (p - 0.32) / 0.12 * 0.12 : 1
        wave = 1
        yaw = sin(t * 1.7 + seed) * 0.22
        moving = true
      case .done:
        let p = (t + seed).truncatingRemainder(dividingBy: 3) / 3
        if fresh, p < 0.16 {
          hop = sin(p / 0.16 * .pi) * 6
          cheer = 1
        }
        moving = fresh && p < 0.16
      case .failed:
        let p = (t + seed).truncatingRemainder(dividingBy: 2) / 2
        yaw = fresh && p < 0.3 ? sin(p / 0.3 * .pi * 4) * 0.4 : 0
        moving = fresh && p < 0.3
      case .idle:
        squash = 0.95 + sin(t * 1.4 + seed) * 0.012 // breathing, too slight to need every frame
      }
    }
  }

  func render(_ sessions: [Session], dt: Double, t: Double) {
    var list: [Voxel.Cube] = []
    busy = false
    let now = Date().timeIntervalSince1970
    for (i, s) in sessions.prefix(Sessions.most).enumerated() {
      let cx = Float(Crew.pad + i * Crew.slot + 25)
      let seed = Double(i) * 0.61
      // Each Clawd eases into its state's colour.
      var target = linear(Crew.colour[s.state] ?? 0xD77757) * (Crew.light[s.state] ?? 1)
      target.w = 1
      bodies[i] = bodies[i].w == 0 ? target : bodies[i] + (target - bodies[i]) * Float(1 - exp(-6 * dt))
      let act = Act(s.state, t, seed, age: now - s.since)
      // Drawn every frame from just before a hop or a shake begins until it settles.
      busy = busy || act.moving || Act(s.state, t + 0.2, seed, age: now - s.since + 0.2).moving || simd_length(target - bodies[i]) > 0.005
      let grid = s.state == .idle ? Clawd.animate(t, working: false, asleep: true) : Clawd.animate(t + seed, working: false, asleep: false)
      let body = bodies[i]
      let rig = Voxel.translate(cx, Crew.feet + 1 + Float(act.hop), 0) * Voxel.scale(Crew.unit, Crew.unit, Crew.unit)
        * Voxel.rotation(x: 0.3, y: Float(act.yaw))
      Voxel.figure(rig, grid: grid, lift: Float(act.walking ? sin(act.phase) : 0), walking: act.walking, squash: Float(act.squash),
                   wave: Float(act.wave), swing: Float(sin(t * 11 + seed)), cheer: Float(act.cheer),
                   body: body, eye: Voxel.flat(0x0B0604), into: &list)
      // Under a finger, it stands on a lit line, behind its feet.
      if touched == i {
        list.append(Voxel.Cube(model: Voxel.translate(cx, 12, -50) * Voxel.scale(44, 2, 1), color: Voxel.flat(0xECE8E0)))
      }
    }
    let count = list.count
    list.withUnsafeBytes { instances.contents().copyMemory(from: $0.baseAddress!, byteCount: count * MemoryLayout<Voxel.Cube>.stride) }
    gpu.frame { encoder in
      guard count > 0 else { return }
      encoder.setDepthStencilState(depth)
      encoder.setCullMode(.none)
      encoder.setRenderPipelineState(cubes)
      encoder.setVertexBuffer(mesh, offset: 0, index: 0)
      encoder.setVertexBuffer(instances, offset: 0, index: 1)
      encoder.setVertexBytes(&scene, length: MemoryLayout<Voxel.Scene>.stride, index: 2)
      encoder.setFragmentBytes(&scene, length: MemoryLayout<Voxel.Scene>.stride, index: 2)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 36, instanceCount: count)
    }
  }
}

// The crew's view on the Touch Bar: where a finger is along it, in pixels from its left (nil
// once the finger has slid off it), and whether it lifted on the row.
final class CrewView: NSView {
  var onTouch: ((CGFloat?) -> Void)?
  var onLift: ((Bool) -> Void)?

  override init(frame: NSRect) {
    super.init(frame: frame)
    allowedTouchTypes = [.direct]
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  private func along(_ event: NSEvent) -> CGFloat? {
    guard let touch = event.touches(matching: .any, in: self).first else { return nil }
    let x = touch.location(in: self).x
    return x >= 0 && x <= bounds.width ? x * 2 : nil
  }

  override func touchesBegan(with event: NSEvent) { onTouch?(along(event)) }
  override func touchesMoved(with event: NSEvent) { onTouch?(along(event)) }
  override func touchesEnded(with event: NSEvent) { onLift?(along(event) != nil) }
  override func touchesCancelled(with event: NSEvent) { onLift?(false) }
}

// A session's title, and what it's doing, across the usage while a finger is on its Clawd, as
// the gallery's .reading card sets them: the title in the system face, the state after it.
final class ReadingView: NSView {
  private var session: Session?

  func show(_ s: Session) {
    if s != session {
      session = s
      needsDisplay = true
    }
    isHidden = false
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.setFillColor(CGColor.black)
    context.fill(bounds)
    guard let session else { return }
    let size = bounds.height * 0.46
    let titleFont = NSFont.systemFont(ofSize: size, weight: .semibold)
    let wordFont = NSFont.systemFont(ofSize: size * 0.8, weight: .medium)
    let line = { (text: String, font: NSFont, color: UInt32) in
      CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: srgb(color)]))
    }
    let word = line(session.word, wordFont, 0x7F7B74)
    var title = line(session.title, titleFont, 0xE9E6E0)
    let left = size * 1.2, gap = size * 0.8
    let width = { (l: CTLine) in CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)) }
    // The title gives way to the state word, ending in an ellipsis when it must.
    let room = bounds.width - left - gap - width(word) - left
    if width(title) > room, let cut = CTLineCreateTruncatedLine(title, Double(room), .end, line("…", titleFont, 0xE9E6E0)) {
      title = cut
    }
    // Each sits with its capitals centred on the bar, on a whole pixel.
    let baseline = { (font: NSFont) in ((self.bounds.height - font.capHeight) / 2 * 2).rounded() / 2 }
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: left, y: baseline(titleFont))
    CTLineDraw(title, context)
    context.textPosition = CGPoint(x: left + width(title) + gap, y: baseline(wordFont))
    CTLineDraw(word, context)
  }
}
