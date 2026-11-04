// Clawd, Claude Code's mascot, decoded from the block glyphs Claude Code draws it with, as in
// src/clawd.js: a cell is 2×2 quadrants, and a quadrant is 1 unit wide and 2 tall.

import CoreGraphics
import Foundation

enum Clawd {
  static let color = CGColor(srgbRed: 215 / 255, green: 119 / 255, blue: 87 / 255, alpha: 1)
  static let width = 17
  static let height = 10

  private static let quads: [Character: Int] = [
    " ": 0, "▘": 1, "▝": 2, "▀": 3, "▖": 4, "▌": 5, "▞": 6, "▛": 7,
    "▗": 8, "▚": 9, "▐": 10, "▜": 11, "▄": 12, "▙": 13, "▟": 14, "█": 15,
  ]
  private static let arms: [String: [String]] = [
    "down": [" ▐", "", "▝▜", "█▀"],
    "up": ["▗▟", "▄", " ▜", "█▘"],
  ]
  // A lid cell ("▂", true) is the body with a dark line across its bottom quarter: a closed eye.
  private static let eyes: [String: [(String, Bool)]] = [
    "open": [("▛███▛█", false)],
    "closed": [("▂", true), ("███", false), ("▂", true), ("█", false)],
  ]
  private static let feet = ["both": " ▝▝   ▝▝ ", "left": " ▝▝      ", "right": "      ▝▝ "]
  private static var cache: [String: [[UInt8]]] = [:]

  // A grid of 10 rows of 17 units: 1 where the body is.
  static func pose(eyes eyeName: String = "open", arms armName: String = "down", feet feetName: String = "both") -> [[UInt8]] {
    let key = "\(eyeName)/\(armName)/\(feetName)"
    if let grid = cache[key] { return grid }
    let a = arms[armName]!
    let cells = { (text: String, lid: Bool) in text.map { ($0, lid) } }
    let rows: [[(Character, Bool)]] = [
      cells(a[0], false) + eyes[eyeName]!.flatMap { cells($0.0, $0.1) } + cells(a[1], false),
      cells(a[2], false) + cells("█████", false) + cells(a[3], false),
      cells(feet[feetName]!, false),
    ]
    var grid = Array(repeating: [UInt8](repeating: 0, count: 18), count: 12)
    for (r, row) in rows.enumerated() {
      for (i, (ch, lid)) in row.enumerated() {
        let x = i * 2, y = r * 4
        if lid {
          for k in 0..<3 { grid[y + k][x] = 1; grid[y + k][x + 1] = 1 }
          continue
        }
        let m = quads[ch] ?? 0
        if m & 1 != 0 { grid[y][x] = 1; grid[y + 1][x] = 1 }
        if m & 2 != 0 { grid[y][x + 1] = 1; grid[y + 1][x + 1] = 1 }
        if m & 4 != 0 { grid[y + 2][x] = 1; grid[y + 3][x] = 1 }
        if m & 8 != 0 { grid[y + 2][x + 1] = 1; grid[y + 3][x + 1] = 1 }
      }
    }
    // The first unit column and the last two rows are always empty.
    let trimmed = grid.prefix(height).map { Array($0[1...width]) }
    cache[key] = trimmed
    return trimmed
  }

  // The pose for a moment: blinking now and then, walking while Claude works.
  static func animate(_ t: Double, working: Bool, asleep: Bool) -> [[UInt8]] {
    if asleep { return pose(eyes: "closed") }
    let blinking = t.truncatingRemainder(dividingBy: 4.2) < 0.13
    let eyeName = blinking ? "closed" : "open"
    guard working else { return pose(eyes: eyeName) }
    return pose(eyes: eyeName, feet: ["both", "left", "both", "right"][Int(t * 7) % 4])
  }
}
