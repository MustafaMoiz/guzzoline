// Guzzoline: Claude plan usage on the Touch Bar while the Claude app is in front.
//
// It asks Claude Code how much of each limit is spent (through its own /usage) and shows a theme
// in a system-wide Touch Bar, drawn with Metal and Core Graphics. To its right, a Clawd for each
// of your Claude Code sessions in the Claude app: touch one to read its title, lift to open it,
// hold it to talk to it. A sound says when one finishes or waits on you. Usage numbers (never the
// sign-in) are also saved for the gallery.

import AppKit
import Metal
import ObjectiveC
import ServiceManagement

let claudeApp = "com.anthropic.claudefordesktop"
let themes = [("walk", "Walk"), ("phosphor", "Phosphor"), ("engraving", "Engraving"), ("marquee", "Marquee"), ("incense", "Incense")]
let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
let cacheFile = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Library/Application Support/Guzzoline/usage.json")
let logFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Guzzoline.log")

// What happened, in ~/Library/Logs/Guzzoline.log: never the sign-in, never what you said. Lines
// go in order from any thread, and past a megabyte the log moves to Guzzoline.old.log.
private let logQueue = DispatchQueue(label: "app.guzzoline.log")

func log(_ message: String) {
  let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
  logQueue.async {
    let files = FileManager.default
    if let size = (try? files.attributesOfItem(atPath: logFile.path))?[.size] as? Int, size > 1_000_000 {
      let old = logFile.deletingLastPathComponent().appendingPathComponent("Guzzoline.old.log")
      try? files.removeItem(at: old)
      try? files.moveItem(at: logFile, to: old)
    }
    if let handle = try? FileHandle(forWritingTo: logFile) {
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: Data(line.utf8))
      try? handle.close()
    } else {
      try? Data(line.utf8).write(to: logFile)
    }
  }
}

// MARK: - A Touch Bar shown over every app's, through the private API Pock and others use.

enum SystemModal {
  private static let dfr = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY)

  static func hideCloseBox() {
    typealias Fn = @convention(c) (Bool) -> Void
    guard let symbol = dlsym(dfr, "DFRSystemModalShowsCloseBoxWhenFrontMost") else { return }
    unsafeBitCast(symbol, to: Fn.self)(false)
  }

  // Placement 1 takes the whole bar, Control Strip included.
  static func present(_ bar: NSTouchBar, _ id: NSTouchBarItem.Identifier) -> Bool {
    let cls: AnyClass = NSTouchBar.self
    let withPlacement = NSSelectorFromString("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")
    if let method = class_getClassMethod(cls, withPlacement) {
      typealias Fn = @convention(c) (AnyClass, Selector, NSTouchBar, Int64, NSString?) -> Void
      unsafeBitCast(method_getImplementation(method), to: Fn.self)(cls, withPlacement, bar, 1, id.rawValue as NSString)
      return true
    }
    let plain = NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
    if let method = class_getClassMethod(cls, plain) {
      typealias Fn = @convention(c) (AnyClass, Selector, NSTouchBar, NSString?) -> Void
      unsafeBitCast(method_getImplementation(method), to: Fn.self)(cls, plain, bar, id.rawValue as NSString)
      return true
    }
    return false
  }

  static func dismiss(_ bar: NSTouchBar) {
    let cls: AnyClass = NSTouchBar.self
    let selector = NSSelectorFromString("dismissSystemModalTouchBar:")
    guard let method = class_getClassMethod(cls, selector) else { return }
    typealias Fn = @convention(c) (AnyClass, Selector, NSTouchBar) -> Void
    unsafeBitCast(method_getImplementation(method), to: Fn.self)(cls, selector, bar)
  }
}

// MARK: - Usage, from Claude Code's own /usage, or the API it reads.

final class Usage {
  var onChange: (() -> Void)?
  private(set) var usage: [String: Any]?
  private(set) var note = "Reading usage…"
  private(set) var working = false
  private(set) var signedOut = false // no sign-in to read with, or it has lapsed
  private var token: String?
  private var readingToken = false
  private var waitUntil = Date.distantPast
  private var previous: [String: Double] = [:]
  private var workingUntil = Date.distantPast
  private var timer: Timer?
  private var lastRead = Date.distantPast
  private var direct = false // Claude Code's command wouldn't run, so the API is asked instead

  // A read every five minutes while the bar shows, and one as it shows if the last is older;
  // none while it's hidden, when nothing would show the numbers. Each read runs Claude Code for a
  // few seconds, and the API refuses reads much closer together.
  var showing = false {
    didSet { if showing, !oldValue { readIfDue() } }
  }

  func start() {
    timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.readIfDue() }
  }

  private func readIfDue() {
    guard showing, Date().timeIntervalSince(lastRead) >= 300 else { return }
    fetch()
  }

  // Without Claude Code's command: its sign-in, from the login keychain. macOS asks you to allow
  // each new build, since the keychain knows a build by its fingerprint unless Apple signed it.
  private static func readToken() -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "Claude Code-credentials",
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = json["claudeAiOauth"] as? [String: Any] else { return nil }
    return oauth["accessToken"] as? String
  }

  // Where Claude Code's command is, as its installers put it: one of yours or the system's, never
  // another account's.
  private static let home = FileManager.default.homeDirectoryForCurrentUser.path
  private static let folders = ["\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.npm-global/bin", "/opt/homebrew/bin", "/usr/local/bin"]

  private static func claudeCommand() -> URL? {
    for folder in folders {
      let place = URL(fileURLWithPath: folder).appendingPathComponent("claude")
      let real = place.resolvingSymlinksInPath().path
      guard FileManager.default.isExecutableFile(atPath: real),
            let owner = (try? FileManager.default.attributesOfItem(atPath: real))?[.ownerAccountID] as? NSNumber,
            owner.uint32Value == getuid() || owner.uint32Value == 0 else { continue }
      return place
    }
    return nil
  }

  // Where Claude Code's command is installed, the numbers come from its own /usage, run out of
  // sight (no model, no conversation, nothing saved). Claude Code reads its sign-in itself, and
  // renews it when it has lapsed, so Guzzoline never touches the sign-in or the keychain, and
  // macOS has nothing to ask about. Without the command, the sign-in is read from the keychain.
  private var running = false

  private func readThroughClaude(_ claude: URL) {
    guard !running else { return }
    running = true
    DispatchQueue.global(qos: .utility).async {
      let output = Usage.run(claude, ["-p", "/usage", "--no-session-persistence", "--output-format", "json"])
      let report = output.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["result"] as? String
      let usage = report.flatMap { UsageReport.usage(from: $0) }
      DispatchQueue.main.async {
        self.running = false
        if let usage {
          self.received(200, usage)
        } else if output == nil {
          // It wouldn't run at all (a launcher that can't find Node, say): ask the API instead,
          // from now on. A refusal or an odd report doesn't count; those keep the last numbers.
          log("Claude Code's command wouldn't run, so usage is read from the API")
          self.direct = true
          self.fetch()
        } else if let report, report.range(of: "log ?in|sign ?in|logged out", options: [.regularExpression, .caseInsensitive]) != nil {
          log("Claude Code isn't signed in")
          self.signedOut = true
          self.note = "Sign in to Claude Code: run claude in Terminal once"
          self.onChange?()
        } else {
          // Refused for now, most likely: the last numbers stay up.
          log(report == nil ? "Claude Code's /usage didn't answer" : "Claude Code's /usage gave no numbers")
        }
      }
    }
  }

  // Runs a command for its output, for a minute at most, with the folders it may need (Node's, for
  // an npm install) on its path: an app started from the Dock has only the system's.
  private static func run(_ command: URL, _ arguments: [String]) -> Data? {
    let process = Process()
    let out = Pipe()
    process.executableURL = command
    process.arguments = arguments
    process.currentDirectoryURL = cacheFile.deletingLastPathComponent()
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = ([command.deletingLastPathComponent().path] + folders + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    // Read as it writes, so a long report can't fill the pipe and hold it up.
    var data = Data()
    let reading = DispatchGroup()
    reading.enter()
    DispatchQueue.global(qos: .utility).async {
      data = out.fileHandleForReading.readDataToEndOfFile()
      reading.leave()
    }
    let deadline = Date().addingTimeInterval(60)
    while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
    if process.isRunning { process.terminate() }
    guard reading.wait(timeout: .now() + 2) == .success, !process.isRunning, process.terminationStatus == 0 else { return nil }
    return data
  }

  func fetch() {
    // Asked to wait, it waits, rather than being refused every minute.
    guard Date() >= waitUntil else { return }
    lastRead = Date()
    if !direct, let claude = Usage.claudeCommand() {
      try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
      readThroughClaude(claude)
      return
    }
    if let token {
      request(token)
      return
    }
    // Read off the main thread: while macOS asks you about it, the bar and the menu carry on.
    guard !readingToken else { return }
    readingToken = true
    DispatchQueue.global(qos: .userInitiated).async {
      let found = Usage.readToken()
      DispatchQueue.main.async {
        self.readingToken = false
        self.token = found
        self.signedOut = found == nil
        if let found { self.request(found) } else {
          log("no Claude Code sign-in in the keychain")
          self.note = "To see your usage, install Claude Code and sign in"
          self.onChange?()
        }
      }
    }
  }

  private func request(_ token: String) {
    var request = URLRequest(url: usageURL)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    URLSession.shared.dataTask(with: request) { data, response, _ in
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      let retry = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
      let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
      DispatchQueue.main.async { self.received(status, json, retry: retry) }
    }.resume()
  }

  private func received(_ status: Int, _ json: [String: Any]?, retry: String? = nil) {
    log("usage read: status \(status)\(retry.map { ", retry after \($0)" } ?? ""), limits \((json?.keys.sorted() ?? []).joined(separator: ", "))")
    if status == 401 {
      token = nil // read again once it's renewed
      signedOut = true
      note = "Claude Code's sign-in has lapsed: run claude in Terminal once"
    } else if status == 200, let json {
      usage = json
      signedOut = false
      note = ""
      // Until Claude Code tells us directly, a limit that moved since the last read means
      // Claude has been working.
      var now: [String: Double] = [:]
      for (key, value) in json {
        if let u = (value as? [String: Any])?["utilization"] as? Double { now[key] = u }
      }
      if now.contains(where: { key, u in u > (previous[key] ?? u) }) { workingUntil = Date().addingTimeInterval(90) }
      previous = now
      save(json)
    } else {
      note = "Couldn’t read usage (\(status))"
      if status == 429, let seconds = retry.flatMap(Double.init), seconds > 0 {
        waitUntil = Date().addingTimeInterval(min(seconds, 3600))
        log("waiting \(Int(seconds / 60)) minutes before reading usage again")
      }
    }
    working = Date() < workingUntil
    onChange?()
  }

  // The numbers last read, so the bar has them as it opens: the first read can be refused if
  // the last was only a minute ago.
  static func saved() -> [String: Any]? {
    guard let data = try? Data(contentsOf: cacheFile),
          let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    return record["usage"] as? [String: Any]
  }

  private func save(_ json: [String: Any]) {
    let record: [String: Any] = ["fetchedAt": ISO8601DateFormatter().string(from: Date()), "usage": json]
    guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted]) else { return }
    try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: cacheFile)
  }

}

// A Touch Bar view that passes a tap on to its theme.
final class TouchView: NSView {
  var onTap: (() -> Void)?

  override init(frame: NSRect) {
    super.init(frame: frame)
    allowedTouchTypes = [.direct]
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  override func touchesBegan(with event: NSEvent) { onTap?() }
}

// MARK: - The app: a menu bar icon, the Touch Bar, and when to show it.

final class App: NSObject, NSApplicationDelegate, NSTouchBarDelegate {
  let barID = NSTouchBarItem.Identifier("app.guzzoline.bar")
  let usage = Usage()
  let barView = NSView() // the Touch Bar item: the theme's layer and the crew
  let statusLine = StatusView() // in the theme's place, until there are numbers to draw
  let nativeThemes: [String: (MTLDevice, Int) -> NativeTheme?] = [
    "walk": { WalkTheme(device: $0, width: $1) },
    "phosphor": { PhosphorTheme(device: $0, width: $1) },
    "engraving": { EngravingTheme(device: $0, width: $1) },
    "marquee": { MarqueeTheme(device: $0, width: $1) },
    "incense": { IncenseTheme(device: $0, width: $1) },
  ]
  lazy var device = MTLCreateSystemDefaultDevice()
  var native: NativeTheme?
  var nativeTimer: Timer?
  var lastDrawn = 0.0
  let sessions = Sessions()
  let awake = Awake()
  var panel: Panel?
  var claudeOpen = false
  var crew: Crew?
  var crewDrawn = 0.0
  var laidOutFor = 0 // how many sessions the bar has room for
  let reading = ReadingView()
  var touchedID: String?
  // Talking to a session (Voice.swift): hold its Clawd, speak, let go.
  static let holdTime = 0.5
  let listener = Listener()
  let card = VoiceCard()
  var holdFrom = 0.0 // when the finger came to rest on the Clawd it's on; 0 when it isn't resting
  var talkingTo: Session? // from the end of the hold until what you said is sent
  var holdSpent = false // the hold asked for a permission instead, so letting go does nothing more
  var settingsOnLift: URL? // System Settings, opened when you let go
  var relayoutPending = false // sessions came or went while you spoke
  // The Touch Bar stops taking a finger that hasn't moved since keys and trackpad went quiet, and
  // dims, once the keyboard backlight's timeout has passed (it waits a minute at most, whatever
  // the setting; at five seconds a still finger is dropped mid-sentence). No app can keep it
  // lit. You're almost surely still holding and talking, so the recording carries on, and the
  // end of what you say stands in for letting go.
  var touchTakenAt = 0.0 // when macOS took the touch away; 0 while it hasn't
  var heardAt = 0.0 // when the words last changed
  var loudAt = 0.0 // when you were last louder than the room
  var limitsNow: [Limit] = []
  let demo = CommandLine.arguments.contains("--demo")
  var status: NSStatusItem!
  var touchBar: NSTouchBar!
  var shown = false
  let defaults = UserDefaults.standard

  // The theme picked from the menu is kept; --theme <id> is for one run, as --always is.
  var theme: String {
    get {
      let args = CommandLine.arguments
      if let i = args.firstIndex(of: "--theme"), i + 1 < args.count { return args[i + 1] }
      let picked = defaults.string(forKey: "theme") ?? "walk"
      return nativeThemes[picked] == nil ? "walk" : picked
    }
    set { defaults.set(newValue, forKey: "theme") }
  }

  // Numbers to draw: yours, or with --demo the gallery's. --demo --note <text> shows the bar
  // without them, saying so, as it is before the first read or without a sign-in.
  var hasNumbers: Bool { demo ? !CommandLine.arguments.contains("--note") : !limitsNow.isEmpty }

  var statusText: String {
    let args = CommandLine.arguments
    if demo, let i = args.firstIndex(of: "--note"), i + 1 < args.count { return args[i + 1] }
    return usage.note
  }

  // When the bar shows: with Claude in front, while Claude is open (in front or not), or with
  // every app. The menu's choice is kept; --always is for one run.
  enum Showing: String, CaseIterable {
    case front, open, always
    var title: String {
      switch self {
      case .front: return "When Claude Is in Front"
      case .open: return "While Claude Is Open"
      case .always: return "With Every App"
      }
    }
  }

  var showing: Showing {
    get {
      if CommandLine.arguments.contains("--always") { return .always }
      if let saved = defaults.string(forKey: "showing").flatMap(Showing.init(rawValue:)) { return saved }
      return defaults.bool(forKey: "always") ? .always : .front // the setting before there were three
    }
    set { defaults.set(newValue.rawValue, forKey: "showing") }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    log("launched: theme \(theme), showing \(showing.rawValue), arguments \(CommandLine.arguments.dropFirst().joined(separator: " "))")
    // uninstall.sh: stop opening at login, and quit.
    if CommandLine.arguments.contains("--forget-login") {
      openAtLogin(false)
      exit(0)
    }

    barView.wantsLayer = true
    barView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      barView.widthAnchor.constraint(equalToConstant: 1004),
      barView.heightAnchor.constraint(equalToConstant: 30),
    ])
    if demo { limitsNow = demoLimits() } else {
      limitsNow = Usage.saved().map(limits(fromUsage:)) ?? []
      sessions.read(now: true)
    }
    sessions.onChange = { [weak self] in self?.sessionsChanged() }
    sessions.onCall = { [weak self] in self?.call() }
    if !demo { log("permissions: \(Listener.permissions), Accessibility \(AXIsProcessTrusted() ? "on" : "off")") }
    listener.onLevel = { [weak self] level in
      self?.card.add(level)
      if level > 0.35 { self?.loudAt = CACurrentMediaTime() }
    }
    listener.onWords = { [weak self] words in
      self?.card.hear(words)
      self?.heardAt = CACurrentMediaTime()
    }
    applyTheme()

    touchBar = NSTouchBar()
    touchBar.delegate = self
    touchBar.defaultItemIdentifiers = [barID]
    SystemModal.hideCloseBox()

    status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    status.button?.image = App.mascot()
    status.button?.setAccessibilityLabel("Guzzoline")
    // A click opens the panel; a right click, a small menu.
    status.button?.target = self
    status.button?.action = #selector(statusClicked)
    status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    let panel = Panel()
    panel.device = device
    panel.state = { [weak self] in self?.panelState() ?? PanelState() }
    panel.bar = { [weak self] in self.flatMap { BarState(limits: $0.demo ? demoLimits() : $0.limitsNow, working: $0.usage.working) } }
    panel.crew = { [weak self] in self?.sessionsNow ?? [] }
    panel.themeMaker = { [weak self] id in self?.nativeThemes[id] }
    panel.view.onHit = { [weak self] hit in self?.panelHit(hit) }
    panel.onOpen = { [weak self] in if self?.demo == false { self?.usage.fetch() } }
    self.panel = panel
    // --panel opens it at launch, for screenshots; --panel-png <folder> also draws it there in
    // each theme's dress (the live bars, drawn by the GPU, aren't in the pictures).
    let args = CommandLine.arguments
    if args.contains("--panel") || args.contains("--panel-png"), let button = status.button {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        panel.open(below: button)
        guard let i = args.firstIndex(of: "--panel-png"), i + 1 < args.count else { return }
        var state = self.panelState()
        for (id, _) in themes {
          state.theme = id
          panel.view.skin = Skin.of(id)
          panel.view.arrange(state)
          guard let rep = panel.view.bitmapImageRepForCachingDisplay(in: panel.view.bounds) else { continue }
          panel.view.cacheDisplay(in: panel.view.bounds, to: rep)
          try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]).appendingPathComponent("panel-\(id).png"))
        }
        panel.refresh()
        log("panel drawn to \(args[i + 1])")
      }
    }
    if CommandLine.arguments.contains("--open-at-login") { openAtLogin(true) }

    usage.onChange = { [weak self] in self?.usageChanged() }
    if !demo {
      usage.fetch()
      usage.start()
    }

    // Which app is in front, and whether Claude is running at all.
    let center = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                 NSWorkspace.didTerminateApplicationNotification] {
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        self?.update(front: name == NSWorkspace.didActivateApplicationNotification ? app?.bundleIdentifier : nil)
      }
    }
    update()
  }

  // Your sessions, or with --demo the gallery's made-up ones.
  var sessionsNow: [Session] { demo ? Session.samples : sessions.bar }

  // Lays the bar out afresh: the theme (or the status line) on the left, the crew on the right.
  func applyTheme() {
    // Not while you're speaking to a Clawd: the row stays put under your finger until you let go.
    if card.phase == .listening {
      relayoutPending = true
      return
    }
    relayoutPending = false
    nativeTimer?.invalidate()
    native = nil
    crew = nil
    touchedID = nil
    barView.subviews.forEach { $0.removeFromSuperview() }
    guard let device else {
      log("no Metal device, so nothing to draw with")
      return
    }
    // The crew takes the right of the bar, and the theme is laid out for what's left; until there
    // are numbers to draw, what's missing is said there instead.
    let row = Crew(device: device, count: sessionsNow.count)
    laidOutFor = row == nil ? 0 : sessionsNow.count
    let width = barWidth - Crew.width(laidOutFor)
    let left = NSRect(x: 0, y: 0, width: CGFloat(width) / 2, height: CGFloat(barHeight) / 2)
    if hasNumbers, let made = nativeThemes[theme]?(device, width) {
      native = made
      let view = TouchView(frame: left)
      view.onTap = { [weak made] in made?.tap() }
      view.layer = made.layer
      view.wantsLayer = true
      barView.addSubview(view)
    } else {
      statusLine.frame = left
      statusLine.dress(theme)
      statusLine.text = hasNumbers ? "Couldn't draw this theme" : statusText
      barView.addSubview(statusLine)
    }
    if let row {
      crew = row
      let crewView = CrewView(frame: NSRect(x: left.maxX, y: 0, width: CGFloat(barWidth - width) / 2, height: left.height))
      crewView.layer = row.layer
      crewView.wantsLayer = true
      crewView.onTouch = { [weak self] x in self?.touched(x) }
      crewView.onLift = { [weak self] x, cancelled in self?.lifted(x, cancelled: cancelled) }
      barView.addSubview(crewView)
      reading.frame = left
      reading.isHidden = true
      barView.addSubview(reading)
      card.frame = left
      card.dress(theme)
      barView.addSubview(card)
      // --touch <n> holds a finger on the nth Clawd, for screenshots; --ring <0-1> shows its
      // hold that far along.
      let args = CommandLine.arguments
      if let i = args.firstIndex(of: "--touch"), i + 1 < args.count, let n = Int(args[i + 1]) {
        touched(Crew.center(of: n - 1))
        holdFrom = 0 // held for a picture, not to talk
        if let r = args.firstIndex(of: "--ring"), r + 1 < args.count, let p = Double(args[r + 1]) { reading.hold = p }
      }
      if demo, card.phase == .off { demoVoice(args) }
    }
    ticking(shown)
    log("theme \(theme), \(native == nil ? "without numbers yet" : "drawn natively"), beside \(laidOutFor) sessions")
    if panel?.isOpen == true { panel?.refresh() } // dressed in the theme now picked
  }

  // The latest numbers, or the last saved ones while a read is refused; none while Claude Code's
  // sign-in has lapsed, so the bar says why rather than showing old numbers.
  func usageChanged() {
    if usage.signedOut {
      limitsNow = []
    } else if let json = usage.usage ?? Usage.saved() {
      limitsNow = limits(fromUsage: json)
    }
    if hasNumbers != (native != nil) { applyTheme() } else { statusLine.text = statusText }
  }

  // A session came or went, and the theme makes room; otherwise the crew acts out the change.
  func sessionsChanged() {
    guard !demo else { return }
    log("sessions: " + sessionsNow.map { "\($0.id.prefix(14)) \($0.word)" }.joined(separator: "; "))
    if native != nil, sessionsNow.count != laidOutFor {
      // The new layout fades in over the old, rather than jumping.
      let fade = CATransition()
      fade.type = .fade
      fade.duration = 0.35
      barView.layer?.add(fade, forKey: "relayout")
      applyTheme()
    }
    crewDrawn = 0
    updateAwake()
    if panel?.isOpen == true { panel?.refresh() }
  }

  // Awake with the lid shut while any session, on the bar or not, works or waits on you, and
  // only while Claude is open: a session can't run without it.
  func updateAwake() {
    guard !demo else { return }
    awake.update(busy: claudeOpen && sessions.recent.contains { $0.state == .working || $0.state == .asking })
  }

  func applicationWillTerminate(_ notification: Notification) {
    awake.stop()
  }

  // A finger on the crew shows that session's title over the usage and lights its Clawd;
  // sliding along moves to the next. Off the row, nothing's shown. Resting on one starts a hold.
  // Where a finger is along the crew, in pixels from its left; it's on the row between its ends.
  // While you speak, it only says whether letting go sends or cancels, and only a clear slide off
  // the row (a Clawd's width past its end) cancels, so a finger rolling as you talk doesn't.
  func onRow(_ x: CGFloat?, slack: CGFloat = 0) -> Bool {
    guard let x else { return false }
    return x >= -slack && x <= CGFloat(Crew.width(laidOutFor)) + slack
  }

  func touched(_ x: CGFloat?) {
    guard let crew else { return }
    if talkingTo != nil {
      if card.phase == .listening {
        let off = !onRow(x, slack: 72)
        if off != card.cancelling { log(off ? "slid off the row" : "back on the row") }
        card.cancelling = off
      }
      return
    }
    guard !holdSpent else { return }
    if card.phase == .note { card.hide() } // a new touch puts the last word away
    let list = sessionsNow
    guard let x, onRow(x), !list.isEmpty else {
      crew.touched = -1
      touchedID = nil
      reading.isHidden = true
      reading.hold = 0
      holdFrom = 0
      crewDrawn = 0
      return
    }
    let i = max(0, min(list.count - 1, Crew.slot(at: x)))
    if crew.touched != i {
      crewDrawn = 0
      holdFrom = CACurrentMediaTime() // resting on another starts the hold over
      reading.hold = 0
    }
    crew.touched = i
    touchedID = list[i].id
    reading.show(list[i])
  }

  // Lifting on the row opens that session in the Claude app, or, after a hold, sends what you
  // said to it; lifting off the row does neither.
  func lifted(_ x: CGFloat?, cancelled: Bool) {
    if cancelled, talkingTo == nil { log("a touch was cancelled by macOS") }
    let id = touchedID
    crew?.touched = -1
    touchedID = nil
    reading.isHidden = true
    reading.hold = 0
    holdFrom = 0
    crewDrawn = 0
    if talkingTo != nil {
      guard card.phase == .listening else { return } // already on its way
      log("let go at \(x.map { String(Int($0)) } ?? "no point") of \(Crew.width(laidOutFor)) px\(cancelled ? ", taken by macOS" : "")")
      if cancelled, !card.cancelling {
        touchTakenAt = CACurrentMediaTime()
        card.handsFree = true
        log("the Touch Bar stopped taking the touch; listening until you pause")
        return
      }
      endTalking(send: !card.cancelling && onRow(x, slack: 72))
      return
    }
    if holdSpent {
      holdSpent = false
      if let url = settingsOnLift { NSWorkspace.shared.open(url) }
      settingsOnLift = nil
      return
    }
    guard !cancelled, onRow(x), let id, !demo, let url = Courier.link(id) else { return }
    NSWorkspace.shared.open(url)
    log("opened session \(id)")
  }

  // A finger resting on a Clawd: the ring fills, and when it's full you're talking to that session.
  // One waiting on your answer is answered in Claude, so holding it just opens it.
  func holdOn(_ now: Double) {
    guard holdFrom > 0, talkingTo == nil, !holdSpent, let id = touchedID,
          let s = sessionsNow.first(where: { $0.id == id }), s.state != .asking else { return }
    let held = now - holdFrom
    reading.hold = min(1, held / App.holdTime)
    if held >= App.holdTime { startTalking(to: s) }
  }

  // Sends what was heard, or cancels.
  func endTalking(send: Bool) {
    guard let s = talkingTo, card.phase == .listening else { return }
    touchTakenAt = 0
    card.handsFree = false
    guard send else {
      listener.cancel()
      talkingTo = nil
      card.show(note: "Cancelled", for: 1.2)
      log("cancelled talking to \(s.id)")
      relayoutIfPending()
      return
    }
    card.send()
    if demo {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.delivered(.sent, to: s) }
    } else {
      listener.finish { [weak self] words in self?.send(words, to: s) }
    }
  }

  // Once macOS has taken the touch, a pause sends: quiet for a moment after the last words, or
  // the words unchanged a little longer in a noisy room. Nothing heard at all gives up.
  func waitForPause(_ now: Double) {
    guard touchTakenAt > 0, card.phase == .listening else { return }
    guard heardAt > 0 else {
      if now - touchTakenAt > 6 {
        touchTakenAt = 0
        card.handsFree = false
        listener.cancel()
        talkingTo = nil
        card.show(note: "Didn't catch that. Hold and speak again", for: 2.5)
        log("heard nothing after the Touch Bar took the touch")
        relayoutIfPending()
      }
      return
    }
    let steady = now - heardAt, quiet = now - loudAt
    if (steady > 1.6 && quiet > 1.2) || steady > 3.5 || now - touchTakenAt > 60 {
      log("you paused; sending")
      endTalking(send: true)
    }
  }

  func startTalking(to s: Session) {
    holdFrom = 0
    touchTakenAt = 0
    heardAt = 0
    loudAt = CACurrentMediaTime()
    reading.hold = 0
    let need = demo ? .nothing : Listener.need
    guard need == .nothing else {
      // The hold asks instead; letting go then does nothing more, or opens System Settings.
      holdSpent = true
      reading.isHidden = true
      if need == .asking {
        Listener.ask()
        card.show(note: "Allow Guzzoline to listen, then hold again", for: 5)
      } else {
        settingsOnLift = Listener.settings(for: need)
        let what = need == .microphone ? "the microphone" : "speech recognition"
        card.show(note: "Guzzoline isn't allowed \(what). Let go to open System Settings", for: 5)
      }
      log("talking needs \(need)")
      return
    }
    if !demo {
      guard listener.start() else {
        holdSpent = true
        reading.isHidden = true
        card.show(note: "Couldn't start listening. Try again in a moment", for: 3)
        return
      }
      // Claude comes to the front on the session, so you can see where it's going as you speak.
      if let url = Courier.link(s.id) { NSWorkspace.shared.open(url) }
    }
    talkingTo = s
    reading.isHidden = true
    card.begin(title: s.title)
    log("listening for \(s.id)")
  }

  // What was heard, typed into the session and sent; the words themselves are never logged.
  func send(_ words: String, to s: Session) {
    let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      talkingTo = nil
      if let trouble = listener.trouble {
        card.show(note: trouble, for: 5)
      } else {
        card.show(note: "Didn't catch that. Hold and speak again", for: 2.5)
      }
      log("heard nothing for \(s.id)")
      relayoutIfPending()
      return
    }
    Courier.deliver(text, to: s.id, waiting: { [weak self] in
      self?.card.show(note: "Switch Guzzoline on in Accessibility, and this message goes through", for: 90)
    }) { [weak self] outcome in self?.delivered(outcome, to: s, length: text.count) }
  }

  func delivered(_ outcome: Courier.Outcome, to s: Session, length: Int = 0) {
    talkingTo = nil
    switch outcome {
    case .sent: card.show(note: "Sent to", name: s.title, check: true, for: 2)
    case .drafted: card.show(note: "Added to your draft in", name: s.title, for: 3.5)
    case .copied(.access): card.show(note: "Copied. Guzzoline needs Accessibility to send. Already on? Remove it with – and add it back", for: 6)
    case .copied(.away): card.show(note: "Copied, as Claude wasn't in front. Paste it there", for: 4)
    case .copied(.noBox): card.show(note: "Copied. Paste it into Claude", for: 4)
    }
    log("\(length) characters for \(s.id): \(outcome)")
    relayoutIfPending()
  }

  func relayoutIfPending() {
    guard relayoutPending else { return }
    relayoutPending = false
    applyTheme()
  }

  // --listening <n> talks to the nth Clawd in a made-up voice, and --sent <n> shows it sent: for
  // pictures of the bar.
  func demoVoice(_ args: [String]) {
    let pick = { (flag: String) -> Session? in
      guard let i = args.firstIndex(of: flag), i + 1 < args.count, let n = Int(args[i + 1]),
            n >= 1, n <= self.sessionsNow.count else { return nil }
      return self.sessionsNow[n - 1]
    }
    if let s = pick("--sent") {
      card.show(note: "Sent to", name: s.title, check: true, for: .infinity)
      return
    }
    guard let s = pick("--listening") else { return }
    crew?.touched = sessionsNow.firstIndex(of: s) ?? -1
    touchedID = s.id
    startTalking(to: s)
    card.cancelling = args.contains("--cancelling") // as if the finger had slid off
    let start = CACurrentMediaTime()
    let said = "Can you make the waveform glow a little warmer on Phosphor, and slow the lamps down a touch?".split(separator: " ")
    let timer = Timer(timeInterval: 1 / Listener.rate, repeats: true) { [weak self] _ in
      guard let self, self.card.phase == .listening else { return }
      let t = CACurrentMediaTime() - start
      // Syllables, four or so a second, in phrases that rise and fall, with a breath between.
      let phrase = 0.5 + 0.5 * sin(t * 1.3)
      let syllable = 0.5 + 0.5 * sin(t * 26 + 2 * sin(t * 3.7))
      let breath = t.truncatingRemainder(dividingBy: 3.4) > 3.0 ? 0.15 : 1
      self.card.add(Float(min(1, 0.05 + Double.random(in: 0...0.05) + 0.85 * breath * (0.3 + 0.7 * syllable) * (0.35 + 0.65 * phrase))))
      let heard = min(said.count, Int(t / 0.32))
      if heard > 0 { self.card.hear(said.prefix(heard).joined(separator: " ")) }
    }
    RunLoop.main.add(timer, forMode: .common)
  }

  // Ticks 60 times a second while the bar shows, in every run loop mode so an open menu doesn't
  // stall it; while it's hidden, not at all.
  func ticking(_ on: Bool) {
    nativeTimer?.invalidate()
    nativeTimer = nil
    guard on else { return }
    let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.drawNative() }
    RunLoop.main.add(timer, forMode: .common)
    nativeTimer = timer
  }

  // 60 frames a second while Claude works or something moves; 6 while the bar is still, since
  // those frames would be the same. The theme and the crew keep their own pace.
  func drawNative() {
    guard shown else { return }
    let now = CACurrentMediaTime()
    holdOn(now)
    waitForPause(now)
    card.tick(now)
    if let crew {
      crew.hearing = talkingTo.flatMap { t in sessionsNow.firstIndex { $0.id == t.id } } ?? -1
      crew.loudness = card.loudness
    }
    if let native, let state = BarState(limits: demo ? demoLimits() : limitsNow, working: usage.working),
       state.working || native.busy || now - lastDrawn >= 1.0 / 6 - 0.002 {
      native.render(state, dt: min(0.1, now - lastDrawn), t: now)
      lastDrawn = now
    }
    if let crew, crew.busy || now - crewDrawn >= 1.0 / 6 - 0.002 {
      crew.render(sessionsNow, dt: min(0.1, now - crewDrawn), t: now)
      crewDrawn = now
    }
  }

  // Shown as the panel says, and read more often then. Sessions are read while Claude is open, to
  // hear when one finishes.
  func update(front: String? = nil) {
    let workspace = NSWorkspace.shared
    let inFront = (front ?? workspace.frontmostApplication?.bundleIdentifier) == claudeApp
    let open = workspace.runningApplications.contains { $0.bundleIdentifier == claudeApp && !$0.isTerminated }
    let show: Bool
    switch showing {
    case .front: show = inFront
    case .open: show = open
    case .always: show = true
    }
    if show, !shown {
      if !demo { sessions.read(now: true) } // so it shows them as they are now
      shown = SystemModal.present(touchBar, barID)
      ticking(shown)
      log("Touch Bar \(shown ? "shown" : "not available")")
    }
    if !show, shown {
      SystemModal.dismiss(touchBar)
      shown = false
      ticking(false)
      // Speaking to a session on a bar that's gone: it stops, and nothing is sent.
      if talkingTo != nil { endTalking(send: false) }
    }
    usage.showing = show
    sessions.watch(open && !demo)
    claudeOpen = open
    updateAwake()
  }

  // The sound for a session that finishes or waits on you: one of the Mac's alert sounds, to begin
  // with the one chosen for the Mac in System Settings › Sound.
  static let sounds = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

  var sound: String? {
    get {
      guard let picked = defaults.string(forKey: "sound") else { return macSound }
      return App.sounds.contains(picked) ? picked : nil
    }
    set { defaults.set(newValue ?? "", forKey: "sound") }
  }

  func call() {
    guard let sound else { return }
    NSSound(named: sound)?.play()
    log("a session wants you")
  }

  func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
    let item = NSCustomTouchBarItem(identifier: identifier)
    item.view = barView
    return item
  }

  // MARK: Panel

  @objc func statusClicked() {
    guard let button = status.button else { return }
    let event = NSApp.currentEvent
    guard event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true else {
      panel?.toggle(below: button)
      return
    }
    panel?.close()
    let menu = NSMenu()
    let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "")
    refresh.target = self
    menu.addItem(refresh)
    if awake.installed {
      let remove = NSMenuItem(title: "Remove the Lid-Shut Helper…", action: #selector(removeAwake), keyEquivalent: "")
      remove.target = self
      menu.addItem(remove)
    }
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Quit Guzzoline", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.isFlipped ? button.bounds.height + 5 : -5), in: button)
  }

  // The sound picked, kept while sound is off; to begin with, the Mac's own alert sound.
  var lastSound: String {
    get { defaults.string(forKey: "lastSound").flatMap { App.sounds.contains($0) ? $0 : nil } ?? macSound }
    set { defaults.set(newValue, forKey: "lastSound") }
  }

  var macSound: String {
    let mac = ((defaults.string(forKey: "com.apple.sound.beep.sound") ?? "") as NSString).lastPathComponent
    return App.sounds.first { mac.hasPrefix($0 + ".") } ?? "Glass"
  }

  func panelState() -> PanelState {
    let onBar = Set(sessionsNow.map(\.id))
    var state = PanelState()
    state.sessions = (demo ? Session.samples : sessions.recent).map { ($0, onBar.contains($0.id)) }
    state.showing = showing.rawValue
    state.muted = sound == nil
    state.tone = sound ?? lastSound
    state.theme = theme
    if #available(macOS 13, *) { state.login = SMAppService.mainApp.status == .enabled }
    state.awake = awake.enabled && awake.installed
    return state
  }

  func panelHit(_ hit: PanelView.Hit) {
    switch hit {
    case .session(let id):
      if !demo { sessions.toggle(id) }
    case .showing(let id):
      showing = Showing(rawValue: id) ?? .front
      update()
    case .mute:
      if let sound { lastSound = sound }
      sound = sound == nil ? lastSound : nil
    case .tone(let name):
      sound = name
      lastSound = name
      NSSound(named: name)?.play()
    case .theme(let id):
      guard id != theme else { break }
      theme = id
      applyTheme()
    case .login:
      if #available(macOS 13, *) { openAtLogin(SMAppService.mainApp.status != .enabled) }
    case .awake:
      // The first time, a window explains it and macOS asks for your password, so the panel
      // gets out of their way.
      if !awake.installed { panel?.close() }
      toggleAwake()
    case .quit:
      NSApp.terminate(nil)
    }
    if panel?.isOpen == true { panel?.refresh() }
  }

  // The first time, the helper is installed: macOS asks for your password once.
  @objc func toggleAwake() {
    if awake.installed {
      awake.enabled.toggle()
      return
    }
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Stay awake with the lid shut?"
    alert.informativeText = "While an agent is working, Guzzoline will keep your Mac awake even with the lid shut, and let it sleep again two minutes after the last one finishes, or if the battery drops below 20%. It needs a small helper to change the Mac's sleep setting; macOS will ask for your password once to install it."
    alert.addButton(withTitle: "Install Helper")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    awake.install { [weak self] ok in
      guard let self else { return }
      log("lid-shut helper \(ok ? "installed" : "not installed")")
      if ok { self.awake.enabled = true }
      self.updateAwake()
    }
  }

  @objc func removeAwake() {
    awake.uninstall { [weak self] ok in
      log("lid-shut helper \(ok ? "removed" : "not removed")")
      if ok { self?.awake.enabled = false }
    }
  }

  @objc func refresh() { usage.fetch() }

  // A login item, listed in System Settings › General › Login Items.
  func openAtLogin(_ on: Bool) {
    guard #available(macOS 13, *) else { return }
    do {
      if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
      log("open at login: \(on ? "on" : "off")")
    } catch {
      log("open at login failed: \(error.localizedDescription)")
    }
  }

  // Clawd in the menu bar, as a template image.
  static func mascot() -> NSImage {
    let rows = [
      "..#############..", "..#############..", "..##.#######.##..", "..##.#######.##..",
      "#################", "#################", "..#############..", "..#############..",
      "..#.#.......#.#..", "..#.#.......#.#..",
    ]
    let unit: CGFloat = 1.1
    let image = NSImage(size: NSSize(width: 17 * unit, height: 10 * unit), flipped: true) { _ in
      NSColor.black.setFill()
      for (r, row) in rows.enumerated() {
        for (c, ch) in row.enumerated() where ch == "#" {
          NSRect(x: CGFloat(c) * unit, y: CGFloat(r) * unit, width: unit, height: unit).fill()
        }
      }
      return true
    }
    image.isTemplate = true
    return image
  }
}

@main
enum Main {
  static func main() {
    let app = NSApplication.shared
    let delegate = App() // kept alive by this frame: NSApplication holds its delegate weakly
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
  }
}
