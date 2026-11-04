// Claude Code's own /usage report, read for its numbers: lines like
//   Current session: 23% used · resets 3:49pm (Asia/Calcutta)
//   Current week (all models): 7% used · resets Nov 7 at 10:29am (Asia/Calcutta)
//   Current week (Fable): 0% used · resets Nov 7 at 10:30am (Asia/Calcutta)
// turned into the usage API's own shape (five_hour, seven_day, seven_day_fable, each with its
// utilization and resets_at), which the rest of the app reads.

import Foundation

enum UsageReport {
  static func usage(from text: String, now: Date = Date()) -> [String: Any]? {
    let pattern = #"^\s*Current (session|week(?: \(([^)]+)\))?)\s*:\s*(\d+(?:\.\d+)?)% used(?:\s*·\s*resets\s+(.+?)\s*(?:\(([^)]+)\))?)?\s*$"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines, .caseInsensitive]) else { return nil }
    var usage: [String: Any] = [:]
    for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
      func group(_ i: Int) -> String? { Range(match.range(at: i), in: text).map { String(text[$0]) } }
      guard let what = group(1), let percent = group(3).flatMap(Double.init) else { continue }
      let key: String
      if what.lowercased() == "session" {
        key = "five_hour"
      } else if let model = group(2), model.lowercased() != "all models" {
        key = "seven_day_" + model.lowercased().replacingOccurrences(of: " ", with: "_")
      } else {
        key = "seven_day"
      }
      var window: [String: Any] = ["utilization": percent]
      if let when = group(4), let reset = resetDate(when, zone: group(5), now: now) {
        window["resets_at"] = ISO8601DateFormatter().string(from: reset)
      }
      usage[key] = window
    }
    return usage.isEmpty ? nil : usage
  }

  // "3:49pm" is today's, or tomorrow's once it's passed; "Nov 7 at 10:29am" is this year's, or
  // next year's once it's well past. In the time zone the report names.
  static func resetDate(_ text: String, zone: String?, now: Date = Date()) -> Date? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone.flatMap(TimeZone.init(identifier:)) ?? .current
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    let cleaned = text.replacingOccurrences(of: " at ", with: " ").replacingOccurrences(of: ",", with: "")
      .replacingOccurrences(of: "am", with: "AM").replacingOccurrences(of: "pm", with: "PM")
      .trimmingCharacters(in: .whitespaces)
    let today = calendar.dateComponents([.year, .month, .day], from: now)
    for format in ["MMM d yyyy h:mma", "MMM d yyyy ha", "MMM d h:mma", "MMM d ha", "h:mma", "ha"] {
      formatter.dateFormat = format
      guard let parsed = formatter.date(from: cleaned) else { continue }
      var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: parsed)
      let hasDay = format.hasPrefix("MMM"), hasYear = format.contains("yyyy")
      if !hasDay {
        (parts.year, parts.month, parts.day) = (today.year, today.month, today.day)
      } else if !hasYear {
        parts.year = today.year
      }
      guard var date = calendar.date(from: parts) else { continue }
      if !hasDay, date < now.addingTimeInterval(-60) {
        date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
      } else if hasDay, !hasYear, date < now.addingTimeInterval(-86_400) {
        date = calendar.date(byAdding: .year, value: 1, to: date) ?? date
      }
      return date
    }
    return nil
  }
}
