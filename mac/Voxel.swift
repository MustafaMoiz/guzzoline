// The voxel mascot, as src/voxel.js builds it, for Walk and the crew of sessions: cubes lit as
// three.js lights them (a warm sky, a key light from the front left and a rim from behind) on a
// matte body, with recessed eyes from the 2D pose, and arms and legs that move.

import Metal
import simd

enum Voxel {
  static let shaders = """
  struct Cube { float4x4 model; float4 color; }; // color.a: 1 lit, 0 flat
  struct Scene { float4x4 projection; float4 sky; float4 ground; float4 rim; };
  struct Lit { float4 position [[position]]; float3 normal; float4 color; };
  // A cube's faces are square to its own axes and its scales come before its rotation, so its
  // model matrix turns their normals the right way; shading normalises them.
  vertex Lit cube(uint vid [[vertex_id]], uint iid [[instance_id]], constant float4 *mesh [[buffer(0)]],
                  constant Cube *cubes [[buffer(1)]], constant Scene &scene [[buffer(2)]]) {
    Cube c = cubes[iid];
    Lit o;
    o.position = scene.projection * (c.model * float4(mesh[vid * 2].xyz, 1.0));
    o.normal = (c.model * float4(mesh[vid * 2 + 1].xyz, 0.0)).xyz;
    o.color = c.color;
    return o;
  }
  // A matte surface as three.js lights it: diffuse over pi, plus a little emission.
  fragment float4 shade(Lit in [[stage_in]], constant Scene &scene [[buffer(2)]]) {
    float3 albedo = in.color.rgb;
    if (in.color.a < 0.5) return float4(encode(albedo), 1.0);
    float3 n = normalize(in.normal);
    float3 light = mix(scene.ground.rgb, scene.sky.rgb, 0.5 * n.y + 0.5) * 1.6;
    light += max(dot(n, normalize(float3(-0.5, 0.8, 1.6))), 0.0) * 3.2;
    light += max(dot(n, normalize(float3(1.0, 0.4, -0.8))), 0.0) * 1.4 * scene.rim.rgb;
    return float4(encode(albedo * light * 0.318309886 + albedo * 0.12), 1.0);
  }
  """

  struct Cube { var model: simd_float4x4; var color: SIMD4<Float> }
  struct Scene { var projection: simd_float4x4; var sky, ground, rim: SIMD4<Float> }

  static let cubesPerFigure = 111 // the body block, 104 face cells, two arms and four legs

  // Pixels from the bottom left, as the three.js camera sees them; nearer is a larger z.
  static func scene(width: Int) -> Scene {
    let w = Float(width), h = Float(barHeight)
    let projection = simd_float4x4(columns: (
      SIMD4(2 / w, 0, 0, 0), SIMD4(0, 2 / h, 0, 0), SIMD4(0, 0, -1 / 2000, 0), SIMD4(-1, -1, 1100 / 2000, 1)))
    return Scene(projection: projection, sky: linear(0xFFF4EC), ground: linear(0x2A1C16), rim: linear(0xFFE2D2))
  }

  // A unit cube's 36 corners and their faces' normals.
  static func mesh(_ device: MTLDevice) -> MTLBuffer {
    let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [ // normal, then two edges
      (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)), (SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)),
      (SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 0)), (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)),
      (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)), (SIMD3(0, 0, -1), SIMD3(0, 1, 0), SIMD3(1, 0, 0)),
    ]
    var out: [SIMD4<Float>] = []
    for (n, a, b) in faces {
      let c = n * 0.5
      let corners = [c - a * 0.5 - b * 0.5, c + a * 0.5 - b * 0.5, c + a * 0.5 + b * 0.5, c - a * 0.5 + b * 0.5]
      for i in [0, 1, 2, 0, 2, 3] {
        out.append(SIMD4(corners[i], 1))
        out.append(SIMD4(n, 0))
      }
    }
    return device.makeBuffer(bytes: out, length: out.count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared)!
  }

  // A colour drawn as it is, without light.
  static func flat(_ hex: UInt32) -> SIMD4<Float> {
    var c = linear(hex)
    c.w = 0
    return c
  }

  static func translate(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4(x, y, z, 1)
    return m
  }

  static func scale(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
    simd_float4x4(diagonal: SIMD4(x, y, z, 1))
  }

  static func rotation(x a: Float, y b: Float) -> simd_float4x4 {
    let rx = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, cos(a), sin(a), 0), SIMD4(0, -sin(a), cos(a), 0), SIMD4(0, 0, 0, 1)))
    let ry = simd_float4x4(columns: (SIMD4(cos(b), 0, -sin(b), 0), SIMD4(0, 1, 0, 0), SIMD4(sin(b), 0, cos(b), 0), SIMD4(0, 0, 0, 1)))
    return rx * ry
  }

  // The mascot's cubes, in its own units: arms that swing and legs that lift while it walks.
  // `wave` raises the right arm beside the head, swung out and back by `swing` (-1 to 1);
  // `cheer` raises both, as Claude Code's arms-up pose does.
  static func figure(_ rig: simd_float4x4, grid: [[UInt8]], lift: Float, walking: Bool, squash: Float,
                     wave: Float = 0, swing: Float = 0, cheer: Float = 0,
                     body: SIMD4<Float>, eye: SIMD4<Float>, into list: inout [Cube]) {
    let torso = rig * translate(0, walking ? abs(lift) * 0.45 : 0, 0) * scale(1, squash, 1)
    list.append(Cube(model: torso * translate(0, 6, -0.5) * scale(13, 8, 5), color: body))
    for r in 0..<8 {
      for c in 2...14 {
        let cx = Float(c) + 0.5 - 8.5, cy = 9.5 - Float(r)
        if grid[r][c] != 0 {
          list.append(Cube(model: torso * translate(cx, cy, 2.5), color: body))
        } else {
          list.append(Cube(model: torso * translate(cx, cy, 1.9), color: eye))
        }
      }
    }
    for (i, base) in [SIMD2<Float>(-7.5, 5), SIMD2<Float>(7.5, 5)].enumerated() {
      var at = base
      if walking { at.y += (i == 1 ? -lift : lift) * 0.45 }
      if i == 1, wave != 0 {
        at.x += wave * (0.25 + swing * 0.35)
        at.y += wave * (3 + swing * 0.4)
      }
      if cheer != 0 {
        at.x += (i == 1 ? 1 : -1) * cheer * 0.25
        at.y += cheer * 3
      }
      list.append(Cube(model: torso * translate(at.x, at.y, 0) * scale(2, 2, 2), color: body))
    }
    for (i, legX) in [2, 4, 12, 14].enumerated() {
      let up = i % 2 == 0 ? max(0, lift) : max(0, -lift)
      list.append(Cube(model: rig * translate(Float(legX) + 0.5 - 8.5, 1 + up * 0.9, 0.5) * scale(1, 2, 2), color: body))
    }
  }
}
