// Staying awake with the lid shut while an agent works, for when you close the lid on one and
// go. macOS sleeps when the lid closes whatever apps ask, unless its SleepDisabled setting is
// on, and only root can change that; so a small helper (mac/awake), installed once with your
// password, keeps the setting in step with what this asks for. This asks while any session is
// working or waiting on you, and stops two minutes after the last one finishes; the helper
// turns it off by itself if this quits or the battery runs low.

import AppKit
import IOKit

final class Awake {
  private static let request = "/Users/Shared/Guzzoline/awake"
  private static let daemon = "/Library/LaunchDaemons/app.guzzoline.awake.plist"
  private static let grace = 120.0 // seconds awake after the last session finishes

  var installed: Bool { FileManager.default.fileExists(atPath: Awake.daemon) }
  var enabled: Bool {
    get { UserDefaults.standard.bool(forKey: "awake") }
    set {
      UserDefaults.standard.set(newValue, forKey: "awake")
      update(busy: busy)
    }
  }
  private var busy = false
  private var asking: Bool? // what the request says
  private var quietSince: Date?
  private var graceTimer: Timer?
  private var lidTimer: Timer?
  private var lidShut = false

  // Whether a session is working or waiting on you, as sessions change.
  func update(busy: Bool) {
    self.busy = busy
    guard enabled, installed else { return ask(false) }
    if busy {
      quietSince = nil
      graceTimer?.invalidate()
      graceTimer = nil
      return ask(true)
    }
    if quietSince == nil {
      quietSince = Date()
      graceTimer = Timer.scheduledTimer(withTimeInterval: Awake.grace, repeats: false) { [weak self] _ in
        guard let self else { return }
        self.update(busy: self.busy)
      }
    }
    if let quietSince, Date().timeIntervalSince(quietSince) >= Awake.grace - 1 { ask(false) }
  }

  // When Guzzoline quits: let go, so the helper turns normal sleep back on at once.
  func stop() { ask(false) }

  private func ask(_ on: Bool) {
    guard asking != on else { return }
    asking = on
    // Written in place rather than replaced, so launchd's watch on the file sees it.
    if let handle = FileHandle(forWritingAtPath: Awake.request) {
      handle.truncateFile(atOffset: 0)
      handle.write(Data((on ? "on" : "off").utf8))
      try? handle.close()
    }
    if installed { log("lid-shut awake: \(on ? "asked for" : "let go")") }
    watchLid(on)
  }

  // With the lid shut the screen goes to sleep, so it doesn't spend the battery under the lid.
  private func watchLid(_ on: Bool) {
    lidTimer?.invalidate()
    lidTimer = nil
    lidShut = false
    guard on else { return }
    lidTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.checkLid() }
  }

  private func checkLid() {
    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    defer { IOObjectRelease(root) }
    let property = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
    let shut = (property?.takeRetainedValue() as? Bool) ?? false
    if shut, !lidShut {
      let pmset = Process()
      pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
      pmset.arguments = ["displaysleepnow"]
      try? pmset.run()
      log("lid shut: the screen sleeps, the Mac stays awake")
    }
    lidShut = shut
  }

  // Installs the helper from this app's bundle, or removes it, as root: macOS asks for your
  // password in its own prompt. Off the main thread, so the bar carries on while it asks.
  func install(_ done: @escaping (Bool) -> Void) {
    let source = Bundle.main.resourceURL!.appendingPathComponent("awake").path
    let user = NSUserName()
    run("""
      set -e
      /bin/mkdir -p /Library/PrivilegedHelperTools
      /usr/bin/install -m 755 -o root -g wheel \(quote(source + "/app.guzzoline.awake")) /Library/PrivilegedHelperTools/app.guzzoline.awake
      /usr/bin/install -m 644 -o root -g wheel \(quote(source + "/app.guzzoline.awake.plist")) \(Awake.daemon)
      /bin/mkdir -p /Users/Shared/Guzzoline
      /usr/sbin/chown \(quote(user)) /Users/Shared/Guzzoline
      /bin/chmod 755 /Users/Shared/Guzzoline
      printf off > \(Awake.request)
      /usr/sbin/chown \(quote(user)) \(Awake.request)
      /bin/launchctl bootout system/app.guzzoline.awake 2>/dev/null || true
      /bin/launchctl bootstrap system \(Awake.daemon)
      # The helper from before the app was renamed, if it's there.
      /bin/launchctl bootout system/app.barometer.awake 2>/dev/null || true
      /bin/rm -f /Library/LaunchDaemons/app.barometer.awake.plist /Library/PrivilegedHelperTools/app.barometer.awake
      /bin/rm -rf /Users/Shared/Barometer
      """, done)
  }

  func uninstall(_ done: @escaping (Bool) -> Void) {
    asking = nil
    run("""
      /bin/launchctl bootout system/app.guzzoline.awake 2>/dev/null || true
      /bin/rm -f \(Awake.daemon) /Library/PrivilegedHelperTools/app.guzzoline.awake
      /usr/bin/pmset -a disablesleep 0
      /bin/rm -rf /Users/Shared/Guzzoline
      """, done)
  }

  private func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

  private func run(_ script: String, _ done: @escaping (Bool) -> Void) {
    // AppleScript's own escapes, line breaks included, so the shell gets exactly this script.
    let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
    let source = "do shell script \"" + escaped + "\" with administrator privileges"
    DispatchQueue.global(qos: .userInitiated).async {
      var error: NSDictionary?
      NSAppleScript(source: source)?.executeAndReturnError(&error)
      DispatchQueue.main.async {
        if let error { log("lid-shut helper: \(error[NSAppleScript.errorMessage] ?? error)") }
        done(error == nil)
      }
    }
  }
}
