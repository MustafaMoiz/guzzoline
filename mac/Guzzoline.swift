// Guzzoline: Claude plan usage on the Touch Bar while the Claude app is in front.
//
// It reads Claude Code's sign-in from the Keychain (macOS asks you first), asks the usage API
// how much of each limit is spent, and shows a theme in a system-wide Touch Bar: drawn natively
// with Metal where a theme has been ported, otherwise a web page from the app's bundle. To its
// right, a Clawd for each of your Claude Code sessions in the Claude app; touch one to read its
// title, and lift to open it. A sound says when one finishes or waits on you. Usage numbers
// (never the sign-in) are also saved for the gallery.

import AppKit
import Metal
import ObjectiveC
import ServiceManagement
import WebKit

let claudeApp = "com.anthropic.claudefordesktop"
let themes = [("walk", "Walk"), ("phosphor", "Phosphor"), ("engraving", "Engraving"), ("marquee", "Marquee"), ("incense", "Incense")]
let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
let cacheFile = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Library/Application Support/Guzzoline/usage.json")
let logFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Guzzoline.log")

// What happened, in ~/Library/Logs/Guzzoline.log (never the sign-in).
func log(_ message: String) {
  let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
  if let handle = try? FileHandle(forWritingTo: logFile) {
    handle.seekToEndOfFile()
    handle.write(Data(line.utf8))
    try? handle.close()
  } else {
    try? Data(line.utf8).write(to: logFile)
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

// MARK: - The themes, served from the bundle under guzzoline://app/ so their modules load.

final class BundleFiles: NSObject, WKURLSchemeHandler {
  let root: URL
  init(root: URL) { self.root = root.standardizedFileURL }

  func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    guard let url = task.request.url else { return }
    let path = url.path.isEmpty || url.path == "/" ? "index.html" : String(url.path.dropFirst())
    let file = root.appendingPathComponent(path).standardizedFileURL
    guard file.path.hasPrefix(root.path), let data = try? Data(contentsOf: file) else {
      task.didFailWithError(URLError(.fileDoesNotExist))
      return
    }
    let types = ["html": "text/html", "js": "text/javascript", "css": "text/css", "woff2": "font/woff2", "woff": "font/woff", "json": "application/json", "svg": "image/svg+xml", "png": "image/png"]
    let headers = ["Content-Type": types[file.pathExtension] ?? "application/octet-stream"]
    task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
    task.didReceive(data)
    task.didFinish()
  }

  func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

// MARK: - Usage, from the same API Claude Code's /usage reads.

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

  // Switching apps asks again, which mustn't put the next read off.
  func every(_ seconds: TimeInterval) {
    guard timer?.timeInterval != seconds else { return }
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in self?.fetch() }
  }

  // Claude Code keeps its sign-in in the login keychain; the first read asks you to allow it.
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

  func fetch() {
    // Asked to wait, it waits, rather than being refused every minute.
    guard Date() >= waitUntil else { return }
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
          self.note = "Sign in to Claude Code to see your usage"
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
      token = nil // Claude Code renews its sign-in when it next runs; read it again then
      signedOut = true
      note = "Open Claude Code to renew its sign-in"
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

  var payload: String {
    let body: [String: Any] = ["usage": usage ?? [:], "working": working, "note": usage == nil ? note : ""]
    let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
    return String(data: data, encoding: .utf8) ?? "{}"
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

final class App: NSObject, NSApplicationDelegate, NSTouchBarDelegate, WKScriptMessageHandler {
  let barID = NSTouchBarItem.Identifier("app.guzzoline.bar")
  let usage = Usage()
  var web: WKWebView!
  var host: NSWindow!
  let frameView = NSView()
  let barView = NSView() // the Touch Bar item: the copied web frames, or a native theme's layer and the crew
  var copying = false
  // Themes drawn natively; --web shows every theme as a web page instead.
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
  var limitsNow: [Limit] = []
  let demo = CommandLine.arguments.contains("--demo")
  var status: NSStatusItem!
  var touchBar: NSTouchBar!
  var shown = false
  var ready = false
  let defaults = UserDefaults.standard

  // The theme picked from the menu is kept; --theme <id> is for one run, as --always is.
  var theme: String {
    get {
      let args = CommandLine.arguments
      if let i = args.firstIndex(of: "--theme"), i + 1 < args.count { return args[i + 1] }
      return defaults.string(forKey: "theme") ?? "walk"
    }
    set { defaults.set(newValue, forKey: "theme") }
  }

  // Native when the theme has been ported and there are numbers to draw; until then, the web
  // page shows what's missing (a sign-in, say).
  var drawsNatively: Bool {
    !CommandLine.arguments.contains("--web") && nativeThemes[theme] != nil && (demo || !limitsNow.isEmpty)
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

    let config = WKWebViewConfiguration()
    let root = Bundle.main.resourceURL!.appendingPathComponent("web")
    config.setURLSchemeHandler(BundleFiles(root: root), forURLScheme: "guzzoline")
    config.userContentController.add(self, name: "guzzoline")
    web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1004, height: 30), configuration: config)
    web.setValue(false, forKey: "drawsBackground")

    // WebKit draws in another process, which the Touch Bar can't show. So the page runs in an
    // invisible, click-through window, and the Touch Bar shows frames copied from it.
    host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1004, height: 30), styleMask: .borderless, backing: .buffered, defer: false)
    host.isOpaque = false
    host.backgroundColor = .clear
    host.alphaValue = 0
    host.ignoresMouseEvents = true
    host.level = .statusBar
    host.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    host.contentView = web
    frameView.wantsLayer = true
    frameView.layer?.contentsGravity = .resize
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
    if !demo { usage.fetch() }

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

  // --demo shows the made-up numbers the gallery starts with, instead of yours, and doesn't
  // read the sign-in at all.
  func applyTheme() {
    nativeTimer?.invalidate()
    native = nil
    crew = nil
    touchedID = nil
    barView.subviews.forEach { $0.removeFromSuperview() }
    // The crew takes the right of the bar, and the theme is laid out for what's left.
    let row = drawsNatively ? device.flatMap { Crew(device: $0, count: sessionsNow.count) } : nil
    laidOutFor = row == nil ? 0 : sessionsNow.count
    let width = barWidth - Crew.width(laidOutFor)
    if drawsNatively, let device, let made = nativeThemes[theme]?(device, width) {
      native = made
      let view = TouchView(frame: NSRect(x: 0, y: 0, width: CGFloat(width) / 2, height: CGFloat(barHeight) / 2))
      view.onTap = { [weak made] in made?.tap() }
      view.layer = made.layer
      view.wantsLayer = true
      barView.addSubview(view)
      if let row {
        crew = row
        let crewView = CrewView(frame: NSRect(x: view.frame.maxX, y: 0, width: CGFloat(barWidth - width) / 2, height: view.frame.height))
        crewView.layer = row.layer
        crewView.wantsLayer = true
        crewView.onTouch = { [weak self] x in self?.touched(x) }
        crewView.onLift = { [weak self] onRow in self?.lifted(onRow) }
        barView.addSubview(crewView)
        reading.frame = view.frame
        reading.isHidden = true
        barView.addSubview(reading)
        // --touch <n> holds a finger on the nth Clawd, for screenshots.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--touch"), i + 1 < args.count, let n = Int(args[i + 1]) {
          touched(CGFloat(22 + 72 * (n - 1) + 25))
        }
      }
      ready = false
      web.load(URLRequest(url: URL(string: "about:blank")!)) // the page stops drawing
      host.orderOut(nil)
      // Ticks 60 times a second, in every run loop mode so an open menu doesn't stall it.
      let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.drawNative() }
      RunLoop.main.add(timer, forMode: .common)
      nativeTimer = timer
      log("theme \(theme), drawn natively, beside \(laidOutFor) sessions")
    } else {
      frameView.frame = barView.bounds
      frameView.autoresizingMask = [.width, .height]
      barView.addSubview(frameView)
      ready = false
      let live = demo ? "" : "&live"
      web.load(URLRequest(url: URL(string: "guzzoline://app/index.html?solo=\(theme)\(live)")!))
      if shown { host.orderFrontRegardless() }
      log("theme \(theme), drawn as a web page")
    }
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
    if drawsNatively != (native != nil) { applyTheme() }
    push()
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
  // sliding along moves to the next. Off the row, nothing's shown.
  func touched(_ x: CGFloat?) {
    guard let crew else { return }
    let list = sessionsNow
    guard let x, !list.isEmpty else {
      crew.touched = -1
      touchedID = nil
      reading.isHidden = true
      crewDrawn = 0
      return
    }
    let i = max(0, min(list.count - 1, Crew.slot(at: x)))
    if crew.touched != i { crewDrawn = 0 }
    crew.touched = i
    touchedID = list[i].id
    reading.show(list[i])
  }

  // Lifting on the row opens that session in the Claude app.
  func lifted(_ onRow: Bool) {
    let id = touchedID
    crew?.touched = -1
    touchedID = nil
    reading.isHidden = true
    crewDrawn = 0
    guard onRow, let id, !demo else { return }
    // The app takes "last" or local_ and an id; anything else isn't one of its sessions.
    guard id.range(of: "^local_[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil,
          let url = URL(string: "claude://code/continue?session=\(id)") else { return }
    NSWorkspace.shared.open(url)
    log("opened session \(id)")
  }

  // 60 frames a second while Claude works or something moves; 6 while the bar is still, since
  // those frames would be the same. The theme and the crew keep their own pace.
  func drawNative() {
    guard shown, let native, let state = BarState(limits: demo ? demoLimits() : limitsNow, working: usage.working) else { return }
    let now = CACurrentMediaTime()
    if state.working || native.busy || now - lastDrawn >= 1.0 / 6 - 0.002 {
      native.render(state, dt: min(0.1, now - lastDrawn), t: now)
      lastDrawn = now
    }
    if let crew, crew.busy || now - crewDrawn >= 1.0 / 6 - 0.002 {
      crew.render(sessionsNow, dt: min(0.1, now - crewDrawn), t: now)
      crewDrawn = now
    }
  }

  // Shown as the menu says, and read more often then. While it's hidden the page's window is
  // put away too, so the page stops drawing. Sessions are read while Claude is open, to hear
  // when one finishes.
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
      if native == nil { host.orderFrontRegardless() }
      shown = SystemModal.present(touchBar, barID)
      log("Touch Bar \(shown ? "shown" : "not available")")
    }
    if !show, shown {
      SystemModal.dismiss(touchBar)
      shown = false
      host.orderOut(nil)
    }
    usage.every(show ? 60 : 300)
    sessions.watch(open && !demo)
    claudeOpen = open
    updateAwake()
  }

  // The sound for a session that finishes or waits on you: one of the Mac's alert sounds, to begin
  // with the one chosen for the Mac in System Settings › Sound.
  static let sounds = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

  var sound: String? {
    get {
      guard let picked = defaults.string(forKey: "sound") else {
        let mac = ((defaults.string(forKey: "com.apple.sound.beep.sound") ?? "") as NSString).lastPathComponent
        return App.sounds.first { mac.hasPrefix($0 + ".") } ?? "Glass"
      }
      return App.sounds.contains(picked) ? picked : nil
    }
    set { defaults.set(newValue ?? "", forKey: "sound") }
  }

  func call() {
    guard let sound else { return }
    NSSound(named: sound)?.play()
    log("a session wants you")
  }

  // A copy of each frame the page draws (12 to 24 a second), one copy in flight at a time.
  func copyFrame() {
    guard shown, !copying else { return }
    copying = true
    let config = WKSnapshotConfiguration()
    config.afterScreenUpdates = false
    web.takeSnapshot(with: config) { [weak self] image, _ in
      self?.copying = false
      // Handed to the layer as it is, so nothing redraws it on the way to the Touch Bar.
      if let frame = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) { self?.frameView.layer?.contents = frame }
    }
  }

  func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
    let item = NSCustomTouchBarItem(identifier: identifier)
    item.view = barView
    return item
  }

  // The page says when it's ready for numbers, and when it has drawn a frame.
  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    if message.body as? String == "frame" {
      copyFrame()
      return
    }
    log("page ready")
    ready = true
    push()
  }

  func push() {
    guard ready, native == nil, !demo else { return }
    web.evaluateJavaScript("window.guzzoline && window.guzzoline.live(\(usage.payload))")
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
