// The usage model the native themes draw from, the same as src/state.js and src/format.js.

import Foundation

let minute = 60.0
let hour = 3600.0
let day = 86_400.0

// One limit: a key as the usage API names it, the fraction spent, and when it resets.
struct Limit {
  let key: String
  var used: Double
  var resetsAt: Date?
}

// What a limit is called and how long its window runs.
struct About {
  let kind: String // "session" or "week"
  let short: String
  let name: String
  let phrase: String
  let length: TimeInterval
}

func describe(_ key: String) -> About {
  if key == "five_hour" { return About(kind: "session", short: "5H", name: "session", phrase: "the session", length: 5 * hour) }
  if key == "seven_day" { return About(kind: "week", short: "WK", name: "week", phrase: "the week", length: 7 * day) }
  let model = key.replacingOccurrences(of: "seven_day_", with: "").replacingOccurrences(of: "_", with: " ")
  return About(kind: "week", short: String(model.prefix(2)).uppercased(), name: model, phrase: "the \(model) week", length: 7 * day)
}

// A limit as a theme sees it: `elapsed` is the fraction of the window's time gone, so at an
// even pace used ≈ elapsed.
struct Window {
  let about: About
  let used: Double
  let elapsed: Double
  let active: Bool
  let status: String // fresh, ok, fast, low, out
  let resetsAt: Date?
  let resetIn: TimeInterval?
  var left: Double { 1 - used }
  var kind: String { about.kind }
  var hot: Bool { status == "low" || status == "out" }
}

func window(_ limit: Limit, now: Date) -> Window {
  let about = describe(limit.key)
  let active = limit.resetsAt.map { $0 > now } ?? false
  let used = active ? min(1, max(0, limit.used)) : 0
  let resetIn = active ? limit.resetsAt!.timeIntervalSince(now) : nil
  let elapsed = resetIn.map { min(1, max(0, 1 - $0 / about.length)) } ?? 0
  var status = "ok"
  if !active { status = "fresh" } else if used >= 1 { status = "out" } else if used >= 0.9 { status = "low" } else if used > elapsed + 0.1 { status = "fast" }
  return Window(about: about, used: used, elapsed: elapsed, active: active, status: status,
                resetsAt: active ? limit.resetsAt : nil, resetIn: resetIn)
}

// What a bar draws: two limits, the session and the week, or on a plan without a session limit
// the week and the next weekly limit.
struct BarState {
  let now: Date
  let primary: Window
  let secondary: Window?
  let working: Bool
  let showUsed: Bool

  init?(limits: [Limit], working: Bool, showUsed: Bool = false, now: Date = Date()) {
    let rank = { (l: Limit) in l.key == "five_hour" ? 0 : l.key == "seven_day" ? 1 : 2 }
    let ordered = limits.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    guard let first = ordered.first else { return nil }
    self.now = now
    primary = window(first, now: now)
    secondary = ordered.count > 1 ? window(ordered[1], now: now) : nil
    self.working = working
    self.showUsed = showUsed
  }
}

private func parseDate(_ text: String?) -> Date? {
  guard let text else { return nil }
  // The API gives microseconds, which ISO8601DateFormatter doesn't read.
  let trimmed = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
  return ISO8601DateFormatter().date(from: trimmed)
}

// Limits from the usage API's response: its `limits` list, or the older top-level windows.
func limits(fromUsage usage: [String: Any]) -> [Limit] {
  if let list = usage["limits"] as? [[String: Any]], !list.isEmpty {
    return list.compactMap { entry in
      guard let percent = (entry["percent"] as? NSNumber)?.doubleValue else { return nil }
      let model = ((entry["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
      let kind = entry["kind"] as? String ?? ""
      let session = entry["group"] as? String == "session" || kind.range(of: "five|hour|session", options: .regularExpression) != nil
      let key = session ? "five_hour" : model.map { "seven_day_\($0.lowercased())" } ?? "seven_day"
      return Limit(key: key, used: percent / 100, resetsAt: parseDate(entry["resets_at"] as? String))
    }
  }
  return usage.compactMap { key, value in
    guard key.hasPrefix("five_hour") || key.hasPrefix("seven_day"),
          let window = value as? [String: Any], let u = (window["utilization"] as? NSNumber)?.doubleValue else { return nil }
    return Limit(key: key, used: u / 100, resetsAt: parseDate(window["resets_at"] as? String))
  }
}

// The gallery's first scenario, for --demo.
func demoLimits(now: Date = Date()) -> [Limit] {
  [Limit(key: "five_hour", used: 0.34, resetsAt: now.addingTimeInterval(2.75 * hour)),
   Limit(key: "seven_day", used: 0.41, resetsAt: now.addingTimeInterval(3.6 * day))]
}

// MARK: - Words and numbers

func pct(_ v: Double) -> String { String(Int((v * 100).rounded())) }

// "2h 14m", "14m", "3d 4h": how long until a reset.
func until(_ seconds: TimeInterval) -> String {
  if seconds >= day {
    let d = Int(seconds / day), h = Int(seconds.truncatingRemainder(dividingBy: day) / hour)
    return h > 0 ? "\(d)d \(h)h" : "\(d)d"
  }
  if seconds >= hour {
    let h = Int(seconds / hour), m = Int(seconds.truncatingRemainder(dividingBy: hour) / minute)
    return m > 0 ? "\(h)h \(m)m" : "\(h)h"
  }
  return seconds >= minute ? "\(Int(seconds / minute))m" : "<1m"
}

private let timeFormatter: DateFormatter = {
  let f = DateFormatter()
  f.locale = .current
  f.setLocalizedDateFormatFromTemplate("jmm")
  return f
}()

private let dayFormatter: DateFormatter = {
  let f = DateFormatter()
  f.locale = .current
  f.setLocalizedDateFormatFromTemplate("EEE")
  return f
}()

// ("4:10", "PM") in the viewer's locale; the period is "" on a 24-hour clock.
func clock(_ date: Date) -> (time: String, period: String) {
  var text = timeFormatter.string(from: date)
  var period = ""
  for symbol in [timeFormatter.amSymbol, timeFormatter.pmSymbol].compactMap({ $0 }) where text.contains(symbol) {
    period = symbol.uppercased().replacingOccurrences(of: ".", with: "")
    text = text.replacingOccurrences(of: symbol, with: "")
  }
  return (text.trimmingCharacters(in: .whitespaces), period)
}

func weekday(_ date: Date) -> String { dayFormatter.string(from: date) }

// When a window resets: a countdown once it has run out, a time for the session (and for a
// week resetting within the day), a weekday for the week.
func resetText(_ w: Window) -> String {
  guard w.active, let resetsAt = w.resetsAt, let resetIn = w.resetIn else { return "" }
  if w.status == "out" { return "in \(until(resetIn))" }
  if w.kind == "session" || resetIn < day {
    let (time, period) = clock(resetsAt)
    return period.isEmpty ? time : "\(time) \(period)"
  }
  return weekday(resetsAt)
}
