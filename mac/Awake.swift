// Staying awake with the lid shut while an agent works, for when you close the lid on one and
// go. macOS sleeps when the lid closes whatever apps ask, unless its SleepDisabled setting is
// on, and only root can change that; so a small helper (the script below), installed once with
// your password, keeps the setting in step with what this asks for. This asks while any session
// is working or waiting on you, and stops two minutes after the last one finishes; the helper
// turns it off by itself if this quits or the battery runs low.

import AppKit
import IOKit

final class Awake {
  private static let daemon = "/Library/LaunchDaemons/app.guzzoline.awake.plist"
  private static let helper = "/Library/PrivilegedHelperTools/app.guzzoline.awake"
  // The request the helper reads lives in a folder only root can change, so no other account on
  // the Mac can put something in its place. A helper installed before kept it in /Users/Shared;
  // the request goes wherever the installed helper watches, so that one keeps working.
  private static let folder = "/Library/Application Support/Guzzoline"
  private static var request: String {
    (NSDictionary(contentsOfFile: daemon)?["WatchPaths"] as? [String])?.first ?? folder + "/awake"
  }
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
      try? handle.truncate(atOffset: 0)
      try? handle.write(contentsOf: Data((on ? "on" : "off").utf8))
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

  // Installs the helper, or removes it, as root: macOS asks for your password in its own prompt.
  // The helper's script and launchd's instructions are written from this app itself, not copied
  // from files anyone could change. Root only ever touches folders that only root can change.
  func install(_ done: @escaping (Bool) -> Void) {
    let user = NSUserName()
    run("""
      set -e
      umask 022
      /bin/mkdir -p /Library/PrivilegedHelperTools
      /bin/cat > \(Awake.helper).new <<'GUZZOLINE'
      \(Awake.script)
      GUZZOLINE
      /usr/sbin/chown root:wheel \(Awake.helper).new
      /bin/chmod 755 \(Awake.helper).new
      /bin/mv -f \(Awake.helper).new \(Awake.helper)
      /bin/cat > \(Awake.daemon).new <<'GUZZOLINE'
      \(Awake.plist)
      GUZZOLINE
      /usr/sbin/chown root:wheel \(Awake.daemon).new
      /bin/chmod 644 \(Awake.daemon).new
      /bin/mv -f \(Awake.daemon).new \(Awake.daemon)
      /usr/bin/install -d -o root -g wheel -m 755 \(quote(Awake.folder))
      /usr/bin/install -o \(quote(user)) -g staff -m 644 /dev/null \(quote(Awake.folder + "/awake"))
      /bin/launchctl bootout system/app.guzzoline.awake 2>/dev/null || true
      /bin/launchctl bootstrap system \(Awake.daemon)
      """) { ok in
      if ok { Awake.forgetSharedRequest() }
      done(ok)
    }
  }

  func uninstall(_ done: @escaping (Bool) -> Void) {
    asking = nil
    run("""
      /bin/launchctl bootout system/app.guzzoline.awake 2>/dev/null || true
      /bin/rm -f \(Awake.daemon) \(Awake.helper)
      /usr/bin/pmset -a disablesleep 0
      /bin/rm -rf \(quote(Awake.folder))
      """) { ok in
      if ok { Awake.forgetSharedRequest() }
      done(ok)
    }
  }

  // An earlier helper's request, in /Users/Shared: removed as you, never as root, and only if
  // it's your own folder.
  private static func forgetSharedRequest() {
    let old = "/Users/Shared/Guzzoline"
    var info = stat()
    guard lstat(old, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { return }
    try? FileManager.default.removeItem(atPath: old)
  }

  // What launchd runs as root: it keeps SleepDisabled in step with the request, on only while
  // the request says "on", Guzzoline is running for the account that asked, and the Mac is
  // plugged in or has 20% of its battery or more; off in every other case, including any doubt.
  private static let script = #"""
    #!/bin/sh
    # Guzzoline's helper, keeping the Mac awake with the lid shut while an agent works. launchd
    # runs it as root whenever Guzzoline changes its request, and once a minute. Remove it from
    # Guzzoline's menu (right click), or with uninstall.sh.
    REQUEST="/Library/Application Support/Guzzoline/awake"
    want=0
    owner=$(/usr/bin/stat -f %u "$REQUEST" 2>/dev/null)
    if [ "$(/bin/cat "$REQUEST" 2>/dev/null)" = "on" ] && [ -n "$owner" ] && /usr/bin/pgrep -x -U "$owner" Guzzoline >/dev/null; then
      battery=$(/usr/bin/pmset -g batt)
      level=$(printf '%s\n' "$battery" | /usr/bin/grep -Eo '[0-9]+%' | /usr/bin/head -n 1 | /usr/bin/tr -d '%')
      if printf '%s\n' "$battery" | /usr/bin/grep -q "'AC Power'" || [ "${level:-0}" -ge 20 ]; then
        want=1
      fi
    fi
    now=$(/usr/bin/pmset -g | /usr/bin/awk '/SleepDisabled/ { print $2 }')
    if [ "$now" != "$want" ]; then
      /usr/bin/pmset -a disablesleep "$want"
    fi
    """#

  private static let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>app.guzzoline.awake</string>
      <key>ProgramArguments</key>
      <array>
        <string>\(helper)</string>
      </array>
      <key>WatchPaths</key>
      <array>
        <string>\(folder)/awake</string>
      </array>
      <key>StartInterval</key>
      <integer>60</integer>
      <key>RunAtLoad</key>
      <true/>
    </dict>
    </plist>
    """

  private func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

  // On the main thread, which NSAppleScript needs, once the click that asked has been handled; the
  // bar waits while macOS's password prompt is up, which names Guzzoline as the one asking.
  private func run(_ script: String, _ done: @escaping (Bool) -> Void) {
    // AppleScript's own escapes, line breaks included, so the shell gets exactly this script.
    let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
    let source = "do shell script \"" + escaped + "\" with administrator privileges"
    DispatchQueue.main.async {
      var error: NSDictionary?
      NSAppleScript(source: source)?.executeAndReturnError(&error)
      if let error { log("lid-shut helper: \(error[NSAppleScript.errorMessage] ?? error)") }
      done(error == nil)
    }
  }
}
