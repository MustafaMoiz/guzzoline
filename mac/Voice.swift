// Talking to a session: hold its Clawd on the Touch Bar and Claude comes to the front on it; speak,
// let go, and what you said is sent there. The microphone is on only while you hold, and macOS's
// speech recognition turns what it hears into words, on this Mac where it can. The words are typed
// into the session's message box, which takes Accessibility; without it they go on the clipboard.

import AppKit
import ApplicationServices
import AVFoundation
import Speech

// The microphone and speech recognition while a Clawd is held: how loud you are, twenty times a
// second, for the bar's waveform, and the words heard so far. Both on the main thread.
final class Listener {
  static let rate = 20.0 // levels a second

  // What's missing before it can listen: nothing, a question macOS hasn't asked yet, or a
  // permission you've turned down, which only System Settings can give back. From macOS 26 the
  // words come from SpeechAnalyzer, which needs only the microphone.
  enum Need: Equatable { case nothing, asking, microphone, speech }

  // SpeechAnalyzer, from macOS 26, where the tools that built this app know it.
  static var analyzes: Bool {
    #if compiler(>=6.2)
    if #available(macOS 26, *) { return true }
    #endif
    return false
  }

  static var need: Need {
    let mic = AVCaptureDevice.authorizationStatus(for: .audio)
    if mic == .denied || mic == .restricted { return .microphone }
    if analyzes { return mic == .authorized ? .nothing : .asking }
    let speech = SFSpeechRecognizer.authorizationStatus()
    if speech == .denied || speech == .restricted { return .speech }
    return mic == .authorized && speech == .authorized ? .nothing : .asking
  }

  // macOS asks for each in turn: speech recognition where it's needed, then the microphone.
  static func ask() {
    if analyzes {
      AVCaptureDevice.requestAccess(for: .audio) { _ in }
      return
    }
    SFSpeechRecognizer.requestAuthorization { _ in
      AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }
  }

  // For the log: what macOS says about the microphone.
  static var permissions: String {
    let names: [AVAuthorizationStatus: String] = [.authorized: "on", .denied: "off", .restricted: "restricted", .notDetermined: "not asked yet"]
    return "microphone \(names[AVCaptureDevice.authorizationStatus(for: .audio)] ?? "unknown")"
  }

  // Where in System Settings each is given back.
  static func settings(for need: Need) -> URL? {
    let pane = need == .speech ? "Privacy_SpeechRecognition" : "Privacy_Microphone"
    return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
  }

  var onLevel: ((Float) -> Void)?
  var onWords: ((String) -> Void)?
  private(set) var trouble: String? // why recognition failed, when it did, rather than hearing nothing
  private var engine: AVAudioEngine?
  private var recogniser: Recogniser?

  // Starts listening; false if it can't (no microphone, or no speech recognition just now).
  func start() -> Bool {
    cancel()
    trouble = nil
    var made: Recogniser?
    #if compiler(>=6.2)
    if #available(macOS 26, *) { made = Transcriber() }
    #endif
    guard let recogniser = made ?? Dictation() else { return false }
    recogniser.onWords = { [weak self] words in self?.onWords?(words) }
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.channelCount > 0, format.sampleRate > 0 else {
      log("no microphone")
      recogniser.cancel()
      return false
    }
    // How loud, over each twentieth of a second: quiet rooms sit near the bottom, a speaking voice
    // near the top.
    let window = max(1, Int(format.sampleRate / Listener.rate))
    var sum: Float = 0
    var count = 0
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      recogniser.append(buffer)
      guard let samples = buffer.floatChannelData?[0] else { return }
      var levels: [Float] = []
      for i in 0..<Int(buffer.frameLength) {
        sum += samples[i] * samples[i]
        count += 1
        if count == window {
          let decibels = 10 * log10(max(sum / Float(count), 1e-12))
          levels.append(min(1, max(0, (decibels + 54) / 36)))
          sum = 0
          count = 0
        }
      }
      guard !levels.isEmpty else { return }
      DispatchQueue.main.async { levels.forEach { self?.onLevel?($0) } }
    }
    engine.prepare()
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      recogniser.cancel()
      log("the microphone wouldn't start: \((error as NSError).domain) \((error as NSError).code)")
      return false
    }
    self.engine = engine
    self.recogniser = recogniser
    return true
  }

  // Stops listening, and hands over the words once the recogniser has its last of them.
  func finish(_ then: @escaping (String) -> Void) {
    stopAudio()
    guard let recogniser else { return then("") }
    self.recogniser = nil
    recogniser.finish { [weak self] words in
      self?.trouble = recogniser.trouble
      then(words)
    }
  }

  func cancel() {
    stopAudio()
    recogniser?.cancel()
    recogniser = nil
  }

  private func stopAudio() {
    guard let engine else { return }
    engine.stop()
    engine.inputNode.removeTap(onBus: 0)
    self.engine = nil
  }
}

// Turns speech into words as it's heard, given the microphone's audio as it comes.
protocol Recogniser: AnyObject {
  var onWords: ((String) -> Void)? { get set } // the words so far, on the main thread
  var trouble: String? { get } // why it failed, if it couldn't recognise at all
  func append(_ buffer: AVAudioPCMBuffer) // from the audio thread
  func finish(_ then: @escaping (String) -> Void) // on the main thread, with the last words
  func cancel()
}

#if compiler(>=6.2)
// macOS 26's SpeechAnalyzer: on this Mac, whether or not Siri and Dictation are on, in the
// language closest to the Mac's own.
@available(macOS 26, *)
final class Transcriber: Recogniser {
  var onWords: ((String) -> Void)?
  private(set) var trouble: String?
  private let audio: AsyncStream<AVAudioPCMBuffer>
  private let feed: AsyncStream<AVAudioPCMBuffer>.Continuation
  private var settled = "" // finished phrases
  private var guess = "" // the phrase under way, which may still change
  private var then: ((String) -> Void)?
  private var ended = false
  private var cancelled = false

  init() {
    (audio, feed) = AsyncStream<AVAudioPCMBuffer>.makeStream()
    Task { await self.run() }
  }

  // A copy, since the microphone's buffer is only lent for the moment.
  func append(_ buffer: AVAudioPCMBuffer) {
    guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
    copy.frameLength = buffer.frameLength
    let from = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
    let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    for (source, target) in zip(from, to) {
      guard let data = source.mData, let into = target.mData else { continue }
      memcpy(into, data, Int(min(source.mDataByteSize, target.mDataByteSize)))
    }
    feed.yield(copy)
  }

  func finish(_ then: @escaping (String) -> Void) {
    self.then = then
    feed.finish() // what's been heard is finalised
    if ended {
      hand()
    } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.hand() }
    }
  }

  func cancel() {
    then = nil
    cancelled = true
    feed.finish()
  }

  private var words: String { Transcriber.join(settled, guess).trimmingCharacters(in: .whitespacesAndNewlines) }

  private func hand() {
    guard let then else { return }
    self.then = nil
    then(words)
  }

  private func take(_ text: String, final: Bool) {
    if final {
      settled = Transcriber.join(settled, text)
      guess = ""
    } else {
      guess = text
    }
    if !words.isEmpty { onWords?(words) }
  }

  private static func join(_ a: String, _ b: String) -> String {
    if a.isEmpty || b.isEmpty { return a + b }
    return a.last!.isWhitespace || b.first!.isWhitespace ? a + b : a + " " + b
  }

  private func run() async {
    let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en-US")
    // Fast results put words on the bar about a second after they're spoken, not four.
    let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
    do {
      if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        log("downloading speech recognition for \(locale.identifier)")
        try await install.downloadAndInstall()
      }
      // The model stays loaded for a while after, so the next hold starts at once.
      let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
      let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
      try await analyzer.prepareToAnalyze(in: format)
      let (inputs, input) = AsyncStream<AnalyzerInput>.makeStream()
      try await analyzer.start(inputSequence: inputs)
      let reading = Task {
        for try await result in transcriber.results {
          let text = String(result.text.characters)
          let final = result.isFinal
          await MainActor.run { self.take(text, final: final) }
        }
      }
      var converter: AVAudioConverter?
      for await buffer in audio {
        guard let format, buffer.format != format else {
          input.yield(AnalyzerInput(buffer: buffer))
          continue
        }
        if converter == nil {
          converter = AVAudioConverter(from: buffer.format, to: format)
          converter?.primeMethod = .none
          converter?.downmix = true // a microphone array becomes one voice
        }
        if let converter, let converted = Transcriber.convert(buffer, to: format, with: converter) {
          input.yield(AnalyzerInput(buffer: converted))
        }
      }
      input.finish()
      if await MainActor.run(body: { self.cancelled }) {
        await analyzer.cancelAndFinishNow()
      } else {
        try await analyzer.finalizeAndFinishThroughEndOfInput()
      }
      try await reading.value
    } catch {
      let error = error as NSError
      log("speech recognition failed: \(error.domain) \(error.code)")
      await MainActor.run { self.trouble = "Speech recognition failed. Try again in a moment" }
    }
    await MainActor.run {
      self.ended = true
      self.hand()
    }
  }

  private static func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate).rounded(.up)) + 1
    guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
    var given = false
    var error: NSError?
    let status = converter.convert(to: out, error: &error) { _, state in
      if given {
        state.pointee = .noDataNow
        return nil
      }
      given = true
      state.pointee = .haveData
      return buffer
    }
    return status == .error ? nil : out
  }
}

#endif

// Before macOS 26, SFSpeechRecognizer: on this Mac where it can, otherwise through Apple, as
// Dictation does, and only while Siri or Dictation is on.
final class Dictation: Recogniser {
  var onWords: ((String) -> Void)?
  private(set) var trouble: String?
  private let recognizer: SFSpeechRecognizer
  private let request = SFSpeechAudioBufferRecognitionRequest()
  private var task: SFSpeechRecognitionTask?
  private var words = ""
  private var ended = false
  private var then: ((String) -> Void)?

  init?() {
    guard let recognizer = SFSpeechRecognizer() ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
          recognizer.isAvailable else {
      log("speech recognition isn't available")
      return nil
    }
    self.recognizer = recognizer
    recognizer.queue = .main
    request.shouldReportPartialResults = true
    if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
    if #available(macOS 13, *) { request.addsPunctuation = true }
    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      guard let self else { return }
      if let text = result?.bestTranscription.formattedString, !text.isEmpty {
        self.words = text
        self.onWords?(text)
      }
      if error != nil || result?.isFinal == true {
        // 1110 is "no speech detected"; 216 and 301, cancelled. Anything else is a fault, most
        // often Siri and Dictation being off (201).
        if let error = error as NSError?, self.words.isEmpty, ![1110, 216, 301].contains(error.code) {
          self.trouble = "Speech recognition isn't working. Is Dictation on, in System Settings › Keyboard?"
          log("speech recognition failed: \(error.domain) \(error.code)")
        }
        self.ended = true
        self.hand()
      }
    }
  }

  func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }

  func finish(_ then: @escaping (String) -> Void) {
    self.then = then
    request.endAudio()
    if ended {
      hand()
    } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.hand() }
    }
  }

  func cancel() {
    then = nil
    task?.cancel()
  }

  private func hand() {
    guard let then else { return }
    self.then = nil
    task?.cancel()
    then(words)
  }
}

// Sends what was said to a session in the Claude app, as if you'd typed it: with Claude in front on
// that session, the words are typed into its message box and Return is pressed. It types only once
// Accessibility shows Claude's keyboard focus is a text box, and presses Return only when the box
// holds just those words, so it never sends a draft of yours. Otherwise the words go on the clipboard.
enum Courier {
  enum Outcome { case sent, drafted, copied(Why) }
  enum Why { case access, away, noBox }

  private static let queue = DispatchQueue(label: "app.guzzoline.courier")
  private static var prompted = false

  // The Claude app's link to a session: "local_" and an id; anything else isn't one of its sessions.
  static func link(_ id: String) -> URL? {
    guard id.range(of: "^local_[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil else { return nil }
    return URL(string: "claude://code/continue?session=\(id)")
  }

  // Without Accessibility, the first send of a launch shows macOS's own prompt, which opens
  // Accessibility in System Settings, and waits a minute and a half for you to switch Guzzoline on;
  // then it sends that message after all. Otherwise the words go on the clipboard.
  static func deliver(_ text: String, to id: String, waiting: @escaping () -> Void, done: @escaping (Outcome) -> Void) {
    var ask = false
    if !AXIsProcessTrusted() {
      guard !prompted else {
        copy(text)
        done(.copied(.access))
        return
      }
      prompted = true
      ask = true
      _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
      waiting()
    }
    let voiceOver = NSWorkspace.shared.isVoiceOverEnabled
    queue.async {
      if ask {
        let deadline = Date().addingTimeInterval(90)
        while !AXIsProcessTrusted(), Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        guard AXIsProcessTrusted() else {
          DispatchQueue.main.async {
            copy(text)
            done(.copied(.access))
          }
          return
        }
        DispatchQueue.main.async { log("Accessibility switched on") }
      }
      let outcome = attempt(text, id, voiceOver: voiceOver)
      DispatchQueue.main.async {
        if case .copied = outcome { copy(text) }
        done(outcome)
      }
    }
  }

  private static func attempt(_ text: String, _ id: String, voiceOver: Bool) -> Outcome {
    guard let (pid, brought) = claudeInFront(id) else { return .copied(.away) }
    // Brought forward just now (from System Settings, say), it needs a moment to take the keyboard.
    if brought { Thread.sleep(forTimeInterval: 0.7) }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1)
    // Claude draws with Chromium, which describes its page to Accessibility only when asked;
    // it's asked for the moment it takes, and left as it was (always on, for VoiceOver).
    let manual = "AXManualAccessibility" as CFString
    let wasOn = voiceOver || (value(app, manual) as? Bool) == true
    if !wasOn { AXUIElementSetAttributeValue(app, manual, kCFBooleanTrue) }
    defer { if !wasOn { AXUIElementSetAttributeValue(app, manual, kCFBooleanFalse) } }

    guard let box = messageBox(app) else { return .copied(.noBox) }
    guard frontmost() == pid else {
      log("Claude went behind before typing")
      return .copied(.away)
    }
    guard type(text, into: pid) else {
      log("Claude went behind while typing")
      return .copied(.away)
    }
    // What the box holds now: just the words, and they're sent; with more of yours, they wait
    // there with it; without them, they went somewhere else; and if it can't be read, there's no
    // knowing, so they wait there too. Return is pressed only on a box holding just the words.
    let want = plain(text)
    var held: String?
    for _ in 0..<8 {
      Thread.sleep(forTimeInterval: 0.08)
      held = (value(box, kAXValueAttribute) as? String).map(plain)
      if held == want { break }
    }
    guard let held else {
      log("the message box couldn't be read, so the words wait there")
      return .drafted
    }
    guard held == want else {
      if held.contains(want) { return .drafted }
      log("the message box didn't take the words")
      return .copied(.noBox)
    }
    guard frontmost() == pid else { return .drafted }
    press(0x24) // Return
    return .sent
  }

  // Claude's process once it's in front, waiting a few seconds for it, as it may be starting up.
  // It was asked to show the session when the hold began, and is asked again if it isn't in front.
  // Also whether it had to be brought forward.
  private static func claudeInFront(_ id: String) -> (pid_t, Bool)? {
    for i in 0..<80 {
      let front = DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication.map { ($0.bundleIdentifier, $0.processIdentifier) } }
      if let front, front.0 == claudeApp { return (front.1, i > 0) }
      if i == 10, let url = link(id) { DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
      Thread.sleep(forTimeInterval: 0.1)
    }
    return nil
  }

  private static func frontmost() -> pid_t? {
    DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication?.processIdentifier }
  }

  // The box the words go in: Claude's keyboard focus, when that's a text box for a message;
  // otherwise the last such box in its window, which is where a message is written, focused. It
  // looks for three seconds at most: Chromium takes a moment to describe its page the first time.
  private static func messageBox(_ app: AXUIElement) -> AXUIElement? {
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      if let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute) {
        if let focused = element(app, kAXFocusedUIElementAttribute), isMessageBox(focused, in: window) { return editor(focused) }
        if let box = lastMessageBox(in: window, until: deadline) {
          AXUIElementSetAttributeValue(editor(box), kAXFocusedAttribute as CFString, kCFBooleanTrue)
          Thread.sleep(forTimeInterval: 0.12)
          if let focused = element(app, kAXFocusedUIElementAttribute), isMessageBox(focused, in: window) { return editor(focused) }
        }
      }
      Thread.sleep(forTimeInterval: 0.15)
    }
    let role = element(app, kAXFocusedUIElementAttribute).flatMap { value($0, kAXRoleAttribute) as? String } ?? "nothing"
    log("found no message box; Claude's focus is \(role)")
    return nil
  }

  // A text box a message is written in: one of several lines, or one line low in the window, where
  // Claude's message box is (a search box sits at the top). Chromium may describe an editor as a
  // group inside an editable region rather than as a text area.
  private static func isMessageBox(_ element: AXUIElement, in window: AXUIElement) -> Bool {
    let role = value(element, kAXRoleAttribute) as? String
    if role == kAXTextAreaRole { return true }
    let editable = role == kAXTextFieldRole || role == kAXComboBoxRole
      || (role == kAXGroupRole && self.element(element, "AXEditableAncestor") != nil)
    guard editable, let box = frame(element), let whole = frame(window), whole.height > 0 else { return false }
    return box.midY > whole.minY + whole.height * 0.6 // Accessibility measures down from the top
  }

  // The whole editor a box is part of, whose value is everything written in it.
  private static func editor(_ box: AXUIElement) -> AXUIElement {
    element(box, "AXHighestEditableAncestor") ?? box
  }

  // Looks through the window from its end, where the message box is, within a limit.
  private static func lastMessageBox(in window: AXUIElement, until deadline: Date) -> AXUIElement? {
    var stack = [window]
    var budget = 3000
    while let element = stack.popLast(), budget > 0, Date() < deadline {
      budget -= 1
      let role = value(element, kAXRoleAttribute) as? String
      if element != window, isMessageBox(element, in: window) { return element }
      if role == kAXStaticTextRole || role == kAXImageRole { continue }
      if let children = value(element, kAXChildrenAttribute) as? [AXUIElement] { stack.append(contentsOf: children) }
    }
    return nil
  }

  private static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    value(element, name as CFString)
  }

  private static func value(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name, &result) == .success ? result : nil
  }

  private static func element(_ of: AXUIElement, _ name: String) -> AXUIElement? {
    guard let found = value(of, name), CFGetTypeID(found) == AXUIElementGetTypeID() else { return nil }
    return (found as! AXUIElement)
  }

  private static func frame(_ element: AXUIElement) -> CGRect? {
    guard let at = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute),
          CFGetTypeID(at) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, extent = CGSize.zero
    AXValueGetValue(at as! AXValue, .cgPoint, &point)
    AXValueGetValue(size as! AXValue, .cgSize, &extent)
    return CGRect(origin: point, size: extent)
  }

  // Text as a box shows it, for comparing: spaces of every kind as one, and the invisible marks
  // editors leave out.
  private static func plain(_ text: String) -> String {
    let invisible: Set<Character> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}"]
    return String(text.filter { !invisible.contains($0) }).replacingOccurrences(of: "\u{00A0}", with: " ")
      .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }

  // Typed as keystrokes that carry the text itself, so it doesn't matter which keyboard layout is
  // on, and the clipboard is left alone; a few characters at a time, and only while Claude is in
  // front, so none go to another app if you switch away. False if it stopped for that.
  private static func type(_ text: String, into pid: pid_t) -> Bool {
    let source = CGEventSource(stateID: .hidSystemState)
    let units = Array(text.utf16)
    var start = 0
    while start < units.count {
      guard frontmost() == pid else { return false }
      var end = min(start + 16, units.count)
      if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
      var chunk = Array(units[start..<end])
      for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
        event.flags = []
        event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
        event.post(tap: .cghidEventTap)
      }
      start = end
      Thread.sleep(forTimeInterval: 0.004)
    }
    return true
  }

  private static func press(_ key: CGKeyCode) {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
      let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
      event?.flags = []
      event?.post(tap: .cghidEventTap)
    }
  }

  private static func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}
