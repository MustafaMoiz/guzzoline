// Your Claude Code sessions in the Claude app, as vite.config.js reads them for the gallery. The
// app keeps a file per session (its own format, not a published one, so this follows it as it
// changes): <account>/<org>/local_<id>.json, and an entry in waiting-input/ while one waits on
// you. Only titles and states are read from them.
//
// A session can reply while agents or a workflow it started are still at work in the background.
// The Claude app's files don't say so, but Claude Code's do: each claude process keeps a record of
// the session it runs, ~/.claude/sessions/<pid>.json, which says busy until that work is done too.
// Commands left running in the background, like a server, don't keep it busy.
//
// Which ones are on the bar is yours to choose from the menu. A new session joins by itself, one
// you take off stays off, and five fit: a sixth bumps the one you've been away from longest,
// which comes back when you next write to it. A finished session stays green for an hour,
// counted from when you're next at the Mac: one that finishes while you're away is still green
// when you're back. While macOS has a prompt up (a password, a permission), the sessions that are
// working wait on you too: macOS doesn't say whose it is.

import CoreGraphics
import Foundation

struct Session: Equatable {
  enum State: String { case working, asking, done, failed, idle } // done and failed: finished lately
  let id: String
  let title: String
  let state: State
  let since: Double // when its turn last started or ended, in seconds

  var word: String { state == .asking ? "needs you" : state.rawValue }

  // Made-up sessions for --demo, one in each state, as the gallery has them.
  static let samples = [
    Session(id: "local_a", title: "Touch Bar ideas", state: .working, since: 0),
    Session(id: "local_b", title: "Inbox triage", state: .asking, since: 0),
    Session(id: "local_c", title: "Display calibration", state: .done, since: Date().timeIntervalSince1970),
    Session(id: "local_d", title: "Editor fixes", state: .idle, since: 0),
    Session(id: "local_e", title: "Release notes", state: .failed, since: Date().timeIntervalSince1970),
  ]
}

final class Sessions {
  static let most = 5 // Clawds the bar has room for
  private static let horizon = 7 * 24 * 60 * 60.0 // seconds: sessions untouched for longer are forgotten
  private static let listed = 8 // in the menu
  private static let green = 60 * 60.0 // seconds a finished one stays green once you're at the Mac

  var onChange: (() -> Void)?
  var onCall: (() -> Void)? // one you haven't taken off finished, or started waiting on you
  // When you last used the keyboard, mouse or trackpad (the Mac says how long ago, and nothing else).
  var touched: () -> Double = {
    Date().timeIntervalSince1970 - CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
  }
  var clock: () -> Double = { Date().timeIntervalSince1970 }
  // Whether one of macOS's own prompts is on screen: these come from its agents, and only their
  // windows' owners are read (no titles, which would take Screen Recording).
  private static let prompters: Set<String> = ["SecurityAgent", "UserNotificationCenter", "universalAccessAuthWarn", "CoreServicesUIAgent", "coreautha"]
  var prompting: () -> Bool = {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.contains { Sessions.prompters.contains($0[kCGWindowOwnerName as String] as? String ?? "") }
  }
  private(set) var bar: [Session] = [] // in the order they began
  private(set) var recent: [Session] = [] // for the menu, the latest first
  private var timer: Timer?
  private let queue = DispatchQueue(label: "app.guzzoline.sessions", qos: .utility)
  private let defaults: UserDefaults
  private let root: URL
  private let running: URL // Claude Code's records of the sessions its processes run

  // What a session's file said, kept until the file is written again.
  private struct Record {
    let id, title: String
    let archived: Bool
    let created, active, turnEdge, wrote: Double // seconds
    let summarized: Bool // its latest message has a summary, so its turn is over
    let failed: Bool // and that turn failed

    init?(_ data: Data) {
      guard let s = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let id = s["sessionId"] as? String else { return nil }
      func time(_ key: String) -> Double { ((s[key] as? Double) ?? 0) / 1000 }
      self.id = id
      title = (s["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
      archived = s["isArchived"] as? Bool ?? false
      created = time("createdAt")
      active = time("lastActivityAt")
      turnEdge = time("lastTurnEdgeAt")
      wrote = time("latestUserFrameAt")
      summarized = (s["postTurnSummaryFor"] as? String) == (s["lastAssistantUuid"] as? String)
      failed = (s["postTurnSummary"] as? [String: Any])?["status_category"] as? String == "failed"
    }

    // Waiting on you, working (its turn, or what it left running), or finished: green (done or
    // failed) for a while, then idle.
    func state(waiting: Bool, busy: Bool, prompted: Bool, lately: Bool) -> Session.State {
      if waiting { return .asking }
      if !summarized || busy { return prompted ? .asking : .working }
      if !lately { return .idle }
      return failed ? .failed : .done
    }
  }

  // What a claude process's record said, kept until the file is written again.
  private struct Run {
    let session: String? // the Claude app's id for it; none for one started in Terminal
    let pid: pid_t
    let started: Double // seconds
    let busy: Bool // working, on its turn or in the background, or asking you something

    init?(_ data: Data) {
      guard let s = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
      session = s["hostSessionId"] as? String
      pid = pid_t(truncatingIfNeeded: s["pid"] as? Int ?? 0)
      started = ((s["startedAt"] as? Double) ?? 0) / 1000
      busy = ["busy", "waiting"].contains(s["status"] as? String ?? "")
    }
  }

  // What you've chosen, kept across launches: what's on the bar and since when, what made way for
  // a newer one and when, what you took off, and when you were first back at the Mac after each
  // finished (with that turn's edge; 0 while you've yet to be). Missing keys read as empty, so
  // older saves still load.
  private struct Choice: Codable, Equatable {
    struct Back: Codable, Equatable { var edge, at: Double }
    var bar: [String: Double] = [:]
    var bumped: [String: Double] = [:]
    var hidden: Set<String> = []
    var back: [String: Back] = [:]

    init() {}
    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      bar = try c.decodeIfPresent([String: Double].self, forKey: .bar) ?? [:]
      bumped = try c.decodeIfPresent([String: Double].self, forKey: .bumped) ?? [:]
      hidden = try c.decodeIfPresent(Set<String>.self, forKey: .hidden) ?? []
      back = try c.decodeIfPresent([String: Back].self, forKey: .back) ?? [:]
    }
  }

  private var records: [String: (written: Date, record: Record)] = [:] // by file
  private var runs: [String: (written: Date, run: Run)] = [:] // by file
  private var choice: Choice
  private var saved: Choice // as it was last saved
  private var firstLaunch: Bool
  private var states: [String: Session.State] = [:] // as last read, to hear what changes
  // All of the above belong to the queue.

  init(defaults: UserDefaults = .standard, root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions"),
       running: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")) {
    self.defaults = defaults
    self.root = root
    self.running = running
    let saved = defaults.data(forKey: "sessions").flatMap { try? JSONDecoder().decode(Choice.self, from: $0) }
    choice = saved ?? Choice()
    self.saved = choice
    firstLaunch = saved == nil
  }

  // Read every second and a half while the Claude app is open.
  func watch(_ on: Bool) {
    guard on != (timer != nil) else { return }
    timer?.invalidate()
    timer = on ? Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.read() } : nil
  }

  // Read off the main thread, or on it when the bar is about to show, so it shows them.
  func read(now wait: Bool = false) {
    let publish = { (found: (bar: [Session], recent: [Session], call: Bool)) in
      if found.bar != self.bar || found.recent != self.recent {
        self.bar = found.bar
        self.recent = found.recent
        self.onChange?()
      }
      if found.call { self.onCall?() }
    }
    if wait { publish(queue.sync { scan() }) } else {
      queue.async { let found = self.scan(); DispatchQueue.main.async { publish(found) } }
    }
  }

  // From the menu: on the bar, or off it and kept off.
  func toggle(_ id: String) {
    queue.async {
      if self.choice.bar[id] != nil {
        self.choice.bar[id] = nil
        self.choice.hidden.insert(id)
      } else {
        self.choice.hidden.remove(id)
        self.choice.bumped[id] = nil
        self.choice.bar[id] = self.clock()
      }
    }
    read()
  }

  private func scan() -> (bar: [Session], recent: [Session], call: Bool) {
    let files = FileManager.default
    let now = clock()
    var found: [(record: Record, waiting: Bool)] = []
    var read = Set<String>()
    let accounts = (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    for account in accounts {
      for dir in (try? files.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [] {
        let waiting = ((try? files.contentsOfDirectory(atPath: dir.appendingPathComponent("waiting-input").path)) ?? []).joined(separator: " ")
        let entries = (try? files.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in entries where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
          // A file last written longer ago than that can't have been active since.
          guard let written = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                now - written.timeIntervalSince1970 < Sessions.horizon else { continue }
          read.insert(file.path)
          var record = records[file.path]?.record
          if records[file.path]?.written != written, let data = try? Data(contentsOf: file) {
            // One caught halfway through being written is read again next time.
            if let fresh = Record(data) {
              record = fresh
              records[file.path] = (written, fresh)
            }
          }
          guard let record, !record.archived else { continue }
          found.append((record, waiting.contains(record.id)))
        }
      }
    }
    records = records.filter { read.contains($0.key) }

    let ids = Set(found.map(\.record.id))
    choice.bar = choice.bar.filter { ids.contains($0.key) }
    choice.bumped = choice.bumped.filter { ids.contains($0.key) }
    choice.hidden = choice.hidden.filter { ids.contains($0) }
    choice.back = choice.back.filter { ids.contains($0.key) }

    // On the first launch, the five last active in the past 12 hours start on the bar.
    if firstLaunch {
      let latest = found.filter { now - $0.record.active < 12 * 60 * 60 }.sorted { $0.record.active > $1.record.active }
      for (r, _) in latest.prefix(Sessions.most) { choice.bar[r.id] = 0 }
      for (r, _) in found where choice.bar[r.id] == nil { choice.bumped[r.id] = now }
      firstLaunch = false
    }
    for (r, _) in found {
      if let at = choice.bumped[r.id] {
        if r.wrote > at { // you wrote to it since it made way
          choice.bumped[r.id] = nil
          choice.bar[r.id] = now
        }
      } else if choice.bar[r.id] == nil, !choice.hidden.contains(r.id) {
        choice.bar[r.id] = now // new
      }
    }
    // Five fit: the one you've been away from longest makes way.
    let active = Dictionary(found.map { ($0.record.id, $0.record.active) }, uniquingKeysWith: max)
    while choice.bar.count > Sessions.most, let out = choice.bar.min(by: { max(active[$0.key] ?? 0, $0.value) < max(active[$1.key] ?? 0, $1.value) })?.key {
      choice.bar[out] = nil
      choice.bumped[out] = now
    }

    var bar: [(created: Double, session: Session)] = []
    var all: [(active: Double, session: Session)] = []
    var call = false
    let touched = self.touched()
    let busy = self.busy()
    let finished = { (r: Record) in r.summarized && !busy.contains(r.id) } // its turn, and what it left running
    let prompted = found.contains { !finished($0.record) } && prompting()
    for (r, waiting) in found {
      let was = states[r.id]
      var lately = true
      if finished(r) {
        // Its hour starts when you're next at the Mac after it finished. One that finished
        // before this was reading counts from when it finished.
        var back = choice.back[r.id].flatMap { $0.edge == r.turnEdge ? $0 : nil }
          ?? Choice.Back(edge: r.turnEdge, at: was == .working || was == .asking ? 0 : r.turnEdge)
        if back.at == 0, touched >= r.turnEdge { back.at = touched }
        choice.back[r.id] = back
        lately = back.at == 0 || now - back.at < Sessions.green
      }
      let state = r.state(waiting: waiting, busy: busy.contains(r.id), prompted: prompted, lately: lately)
      let s = Session(id: r.id, title: r.title, state: state, since: r.turnEdge)
      all.append((r.active, s))
      if choice.bar[r.id] != nil { bar.append((r.created, s)) }
      // Heard when a turn ends or starts waiting on you, even in the session in front of you, as
      // you may have walked away: for any session you haven't taken off, but not at launch.
      if let was, !choice.hidden.contains(r.id),
         state == .asking ? was != .asking : (was == .working || was == .asking) && state != .working {
        call = true
      }
      states[r.id] = state
    }
    states = states.filter { ids.contains($0.key) }
    if choice != saved, let data = try? JSONEncoder().encode(choice) {
      defaults.set(data, forKey: "sessions")
      saved = choice
    }
    let onBar = bar.sorted { $0.created < $1.created }.map(\.session)
    var recent = all.sorted { $0.active > $1.active }.prefix(Sessions.listed).map(\.session)
    recent += onBar.filter { s in !recent.contains { $0.id == s.id } }
    return (onBar, recent, call)
  }

  // The sessions Claude Code is still busy with, by the Claude app's ids for them, from the
  // records its processes keep. A process that ended without clearing its record left it behind,
  // and a newer process may have its number, so a record counts only while its process is running
  // and began before the record did.
  private func busy() -> Set<String> {
    let files = FileManager.default
    var busy = Set<String>()
    var read = Set<String>()
    for file in (try? files.contentsOfDirectory(at: running, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
      // <pid>.json only: the .key file beside each holds that process's secret, and isn't read.
      guard file.pathExtension == "json", pid_t(file.deletingPathExtension().lastPathComponent) != nil,
            let written = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
      read.insert(file.path)
      var run = runs[file.path]?.run
      if runs[file.path]?.written != written, let data = try? Data(contentsOf: file) {
        // One caught halfway through being written is read again next time.
        if let fresh = Run(data) {
          run = fresh
          runs[file.path] = (written, fresh)
        }
      }
      guard let run, run.busy, let session = run.session, run.pid > 0,
            let began = Sessions.began(run.pid), began <= run.started + 1 else { continue }
      busy.insert(session)
    }
    runs = runs.filter { read.contains($0.key) }
    return busy
  }

  // When the running process with this number began, in seconds, or nil when there's none.
  private static func began(_ pid: pid_t) -> Double? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0, Int32(info.kp_proc.p_stat) != SZOMB else { return nil }
    let t = info.kp_proc.p_starttime
    return Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000
  }
}
