// Barometer: Claude plan usage on the Touch Bar while the Claude app is in front.
//
// It reads Claude Code's sign-in from the Keychain (macOS asks you first), asks the usage API
// how much of each limit is spent, and shows a theme, a web page from the app's bundle, in a
// system-wide Touch Bar. Usage numbers (never the sign-in) are also saved for the gallery.

import AppKit
import ObjectiveC
import ServiceManagement
import WebKit

let claudeApp = "com.anthropic.claudefordesktop"
let themes = [("walk", "Walk"), ("phosphor", "Phosphor"), ("engraving", "Engraving"), ("marquee", "Marquee"), ("incense", "Incense")]
let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
let cacheFile = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Library/Application Support/Barometer/usage.json")
let logFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Barometer.log")

// What happened, in ~/Library/Logs/Barometer.log (never the sign-in).
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

// MARK: - The themes, served from the bundle under barometer://app/ so their modules load.

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
  private var token: String?
  private var previous: [String: Double] = [:]
  private var workingUntil = Date.distantPast
  private var timer: Timer?

  func every(_ seconds: TimeInterval) {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in self?.fetch() }
  }

  // Claude Code keeps its sign-in in the login keychain; the first read asks you to allow it.
  private func readToken() -> String? {
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
    if token == nil { token = readToken() }
    guard let token else {
      log("no Claude Code sign-in in the keychain")
      note = "Sign in to Claude Code to see your usage"
      onChange?()
      return
    }
    var request = URLRequest(url: usageURL)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    URLSession.shared.dataTask(with: request) { data, response, _ in
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
      DispatchQueue.main.async { self.received(status, json) }
    }.resume()
  }

  private func received(_ status: Int, _ json: [String: Any]?) {
    log("usage read: status \(status), limits \((json?.keys.sorted() ?? []).joined(separator: ", "))")
    if status == 401 {
      token = nil // Claude Code renews its sign-in when it next runs; read it again then
      note = "Open Claude Code to renew its sign-in"
    } else if status == 200, let json {
      usage = json
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
    }
    working = Date() < workingUntil
    onChange?()
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

// MARK: - The app: a menu bar icon, the Touch Bar, and when to show it.

final class App: NSObject, NSApplicationDelegate, NSTouchBarDelegate, WKScriptMessageHandler {
  let barID = NSTouchBarItem.Identifier("app.barometer.bar")
  let usage = Usage()
  var web: WKWebView!
  var host: NSWindow!
  let frameView = NSView()
  var copying = false
  var status: NSStatusItem!
  var touchBar: NSTouchBar!
  var shown = false
  var ready = false
  let defaults = UserDefaults.standard

  var theme: String {
    get { defaults.string(forKey: "theme") ?? "walk" }
    set { defaults.set(newValue, forKey: "theme") }
  }

  // "Show with Every App" from the menu is kept; --always is for one run.
  var always: Bool {
    get { CommandLine.arguments.contains("--always") || defaults.bool(forKey: "always") }
    set { defaults.set(newValue, forKey: "always") }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    log("launched: theme \(theme), always \(always), arguments \(CommandLine.arguments.dropFirst().joined(separator: " "))")

    let config = WKWebViewConfiguration()
    let root = Bundle.main.resourceURL!.appendingPathComponent("web")
    config.setURLSchemeHandler(BundleFiles(root: root), forURLScheme: "barometer")
    config.userContentController.add(self, name: "barometer")
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
    frameView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      frameView.widthAnchor.constraint(equalToConstant: 1004),
      frameView.heightAnchor.constraint(equalToConstant: 30),
    ])
    load()

    touchBar = NSTouchBar()
    touchBar.delegate = self
    touchBar.defaultItemIdentifiers = [barID]
    SystemModal.hideCloseBox()

    status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    status.button?.image = App.mascot()
    status.button?.setAccessibilityLabel("Barometer")
    status.menu = menu()
    if CommandLine.arguments.contains("--open-at-login") { openAtLogin(true) }

    usage.onChange = { [weak self] in self?.push() }
    usage.fetch()

    let center = NSWorkspace.shared.notificationCenter
    center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      self?.update(front: app?.bundleIdentifier)
    }
    update(front: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
  }

  // --demo shows the made-up numbers the gallery starts with, instead of yours.
  func load() {
    ready = false
    let live = CommandLine.arguments.contains("--demo") ? "" : "&live"
    web.load(URLRequest(url: URL(string: "barometer://app/index.html?solo=\(theme)\(live)")!))
  }

  // Shown while Claude is in front (or always, if chosen), and read more often then. While it's
  // hidden the page's window is put away too, so the page stops drawing.
  func update(front: String?) {
    let show = always || front == claudeApp
    if show, !shown {
      host.orderFrontRegardless()
      shown = SystemModal.present(touchBar, barID)
      log("Touch Bar \(shown ? "shown" : "not available")")
    }
    if !show, shown {
      SystemModal.dismiss(touchBar)
      shown = false
      host.orderOut(nil)
    }
    usage.every(show ? 60 : 300)
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
    item.view = frameView
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
    guard ready, !CommandLine.arguments.contains("--demo") else { return }
    web.evaluateJavaScript("window.barometer && window.barometer.live(\(usage.payload))")
  }

  // MARK: Menu

  func menu() -> NSMenu {
    let menu = NSMenu()
    for (id, name) in themes {
      let item = NSMenuItem(title: name, action: #selector(pick(_:)), keyEquivalent: "")
      item.representedObject = id
      item.state = id == theme ? .on : .off
      item.target = self
      menu.addItem(item)
    }
    menu.addItem(.separator())
    let alwaysItem = NSMenuItem(title: "Show with Every App", action: #selector(toggleAlways(_:)), keyEquivalent: "")
    alwaysItem.state = always ? .on : .off
    alwaysItem.target = self
    menu.addItem(alwaysItem)
    let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r")
    refresh.target = self
    menu.addItem(refresh)
    if #available(macOS 13, *) {
      let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
      login.state = SMAppService.mainApp.status == .enabled ? .on : .off
      login.target = self
      menu.addItem(login)
    }
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Quit Barometer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    return menu
  }

  @objc func pick(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? String else { return }
    theme = id
    status.menu = menu()
    load()
  }

  @objc func toggleAlways(_ sender: NSMenuItem) {
    always.toggle()
    status.menu = menu()
    update(front: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
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
    status.menu = menu()
  }

  @objc func toggleLogin(_ sender: NSMenuItem) {
    guard #available(macOS 13, *) else { return }
    openAtLogin(SMAppService.mainApp.status != .enabled)
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

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
