import AppKit
import AVFoundation
import Foundation
import ServiceManagement

let outRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MEETREC_OUT"]
                  ?? NSHomeDirectory() + "/Meetings")
let logURL = outRoot.appendingPathComponent("meetrec.log")
let pollSeconds: UInt64 = 2
let startAfterPolls = 2          // mic busy for ~4s before we start
let stopAfterSeconds = 20.0      // mic free for 20s before we call it over
let minMeetingSeconds = 60.0     // shorter auto-recordings are discarded

func log(_ msg: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "[\(f.string(from: Date()))] \(msg)\n"
    print(line, terminator: "")
    try? FileManager.default.createDirectory(at: outRoot, withIntermediateDirectories: true)
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        try? h.close()
    } else {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
    }
}

/// transcribe.sh ships in the app's Resources; fall back to walking up from the binary during development.
func transcribeScript() -> URL? {
    if let r = Bundle.main.url(forResource: "transcribe", withExtension: "sh") { return r }
    var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    for _ in 0..<5 {
        let candidate = dir.appendingPathComponent("transcribe.sh")
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        dir = dir.deletingLastPathComponent()
    }
    return nil
}

func shortName(_ bundleID: String) -> String {
    let known = ["zoom": "zoom", "teams": "teams", "slack": "slack", "chrome": "meet", "safari": "meet",
                 "firefox": "meet", "arc": "meet", "facetime": "facetime", "discord": "discord", "whatsapp": "whatsapp"]
    let lower = bundleID.lowercased()
    return known.first(where: { lower.contains($0.key) })?.value ?? "call"
}

/// Thread-safe holder so audio threads always feed the current live transcribers.
final class LiveSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _me: LiveTranscriber?
    private var _others: LiveTranscriber?
    var me: LiveTranscriber? {
        get { lock.withLock { _me } }
        set { lock.withLock { _me = newValue } }
    }
    var others: LiveTranscriber? {
        get { lock.withLock { _others } }
        set { lock.withLock { _others = newValue } }
    }
}

@MainActor
final class Controller {
    private(set) var recorder: Recorder?
    private(set) var app = ""
    private(set) var manual = false
    private(set) var transcribing = 0
    private(set) var lastTranscript: URL? = Controller.newestTranscript()

    /// Survive restarts: the newest meeting folder that has a transcript.
    static func newestTranscript() -> URL? {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: outRoot, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("transcript.md").path) }
            .max { $0.lastPathComponent < $1.lastPathComponent }?
            .appendingPathComponent("transcript.md")
    }
    var lastMeeting: URL? { lastTranscript?.deletingLastPathComponent() }
    let naming = SpeakerNamingWindow()
    let analyzePrompt = AnalyzePrompt()
    var onChange: () -> Void = {}

    let captions = Captions()
    lazy var captionsWindow: CaptionsWindow = {
        let w = CaptionsWindow(captions: captions)
        w.onAsk = { [weak self] excerpt in
            guard let dir = self?.recorder?.dir ?? self?.lastMeeting else { return }
            openInClaude(dir, excerpt: excerpt)
        }
        w.language = { [weak self] in self?.liveLocale == "pt-BR" ? "Português" : "English" }
        return w
    }()
    private var live: [LiveTranscriber] = []

    var liveEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "liveCaptions") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "liveCaptions"); onChange() }
    }
    var liveLocale: String {
        get { UserDefaults.standard.string(forKey: "liveLocale") ?? "pt-BR" }
        set {
            UserDefaults.standard.set(newValue, forKey: "liveLocale")
            Task { await prepareLiveModel(Locale(identifier: newValue)) }
            if recorder != nil && liveEnabled { Task { await restartLive() } }
            onChange()
        }
    }

    private func startLive(_ r: Recorder) {
        let me = LiveTranscriber(speaker: "Me"), others = LiveTranscriber(speaker: "Others")
        live = [me, others]
        liveSink.me = me
        liveSink.others = others
        let sink = liveSink
        r.onMic = { sink.me?.feed($0) }
        r.onSystem = { sink.others?.feed($0) }
        captions.reset()
        captionsWindow.show()
        let locale = Locale(identifier: liveLocale)
        for t in [me, others] {
            Task {
                do { try await t.start(locale: locale, captions: captions) }
                catch { log("live captions unavailable: \(error.localizedDescription)") }
            }
        }
    }

    /// Detaches the current live transcribers synchronously, then finishes them in the background.
    private func stopLive() {
        let running = live
        live = []
        liveSink.me = nil
        liveSink.others = nil
        Task { for t in running { await t.stop() } }
    }

    /// Language switch mid-call: the recorder keeps feeding the same closures, so swap what's behind them.
    private func restartLive() async {
        guard recorder != nil else { return }
        stopLive()
        let me = LiveTranscriber(speaker: "Me"), others = LiveTranscriber(speaker: "Others")
        live = [me, others]
        liveSink.me = me
        liveSink.others = others
        let locale = Locale(identifier: liveLocale)
        for t in [me, others] {
            do { try await t.start(locale: locale, captions: captions) }
            catch { log("live captions unavailable: \(error.localizedDescription)") }
        }
    }
    private let liveSink = LiveSink()

    func begin(app: String, manual: Bool) {
        guard recorder == nil else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        let dir = outRoot.appendingPathComponent("\(f.string(from: Date()))_\(shortName(app))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let r = Recorder(dir: dir)
        if liveEnabled { startLive(r) }
        do {
            try r.start()
            recorder = r
            self.app = app
            self.manual = manual
            log("● recording (\(app)) → \(dir.path)")
        } catch {
            log("could not start recording: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: dir)
            stopLive()
            captionsWindow.hide()
        }
        onChange()
    }

    func end() {
        guard let r = recorder else { return }
        recorder = nil
        r.stop()
        stopLive()
        Task {
            // leave the last lines up briefly, then get out of the way
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if self.recorder == nil { self.captionsWindow.hide() }
        }
        onChange()
        let duration = Date().timeIntervalSince(r.startedAt)
        log("■ stopped after \(Int(duration / 60))m\(Int(duration) % 60)s")
        if liveEnabled { log("  live caption updates: \(captions.stats)") }

        if !manual && duration < minMeetingSeconds {
            log("  too short, discarded")
            try? FileManager.default.removeItem(at: r.dir)
            return
        }
        let iso = ISO8601DateFormatter()
        let meta: [String: Any] = ["app": app, "started": iso.string(from: r.startedAt),
                                   "ended": iso.string(from: Date()), "seconds": Int(duration)]
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]) {
            try? data.write(to: r.dir.appendingPathComponent("meta.json"))
        }
        let dir = r.dir
        Task {
            do { _ = try await SpeakerIdentifier.shared.identify(dir) }
            catch { log("  could not separate voices: \(error.localizedDescription)") }
            self.transcribe(dir)
        }
    }

    private func transcribe(_ dir: URL) {
        guard let script = transcribeScript() else {
            log("transcribe.sh not found; run it manually on \(dir.path)")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path, dir.path]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        let tlog = dir.appendingPathComponent("transcribe.log")
        FileManager.default.createFile(atPath: tlog.path, contents: nil)
        if let h = try? FileHandle(forWritingTo: tlog) {
            p.standardOutput = h
            p.standardError = h
        }
        p.terminationHandler = { proc in
            let ok = proc.terminationStatus == 0
            Task { @MainActor in
                self.transcribing -= 1
                if ok {
                    self.lastTranscript = dir.appendingPathComponent("transcript.md")
                    log("✓ transcript ready: \(self.lastTranscript!.path)")
                    if let m = MeetingSpeakers.load(dir), m.speakers.contains(where: { !$0.known && $0.seconds >= 5 }) {
                        self.nameSpeakers(dir) { self.analyzePrompt.ask(dir) }
                    } else {
                        self.analyzePrompt.ask(dir)
                    }
                } else {
                    log("✗ transcription failed, see \(tlog.path)")
                }
                self.onChange()
            }
        }
        do {
            try p.run()
            transcribing += 1
            log("  transcribing…")
            onChange()
        } catch {
            log("could not launch transcription: \(error)")
        }
    }

    func nameSpeakers(_ dir: URL, then: @escaping () -> Void = {}) {
        naming.show(dir: dir) { saved in
            if saved { log("  speaker names saved for \(dir.lastPathComponent)") }
            then()
        }
    }

    func watch() async {
        log("watching for calls. Recordings go to \(outRoot.path)")
        var busyPolls = 0
        var lastBusy = Date()
        while true {
            let users = currentMicUsers()
            if recorder == nil {
                busyPolls = users.isEmpty ? 0 : busyPolls + 1
                if busyPolls >= startAfterPolls, let first = users.first {
                    lastBusy = Date()
                    begin(app: first.bundleID, manual: false)
                    if recorder == nil { busyPolls = -30 }  // failed; back off ~1 min before retrying
                }
            } else if manual {
                // manual recordings run until stopped from the menu
            } else if !users.isEmpty {
                lastBusy = Date()
            } else if Date().timeIntervalSince(lastBusy) > stopAfterSeconds {
                end()
                busyPolls = 0
            }
            try? await Task.sleep(nanoseconds: pollSeconds * 1_000_000_000)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = Controller()
    var item: NSStatusItem!

    func applicationDidFinishLaunching(_ note: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        controller.onChange = { [weak self] in self?.refresh() }
        enableLoginOnFirstRun()
        refresh()
        Task {
            await requestPermissions()
            do { try await SpeakerIdentifier.shared.prepare() }
            catch { log("could not load voice models: \(error.localizedDescription)") }
            await prepareLiveModel(Locale(identifier: controller.liveLocale))
            await controller.watch()
        }
    }

    /// The point is to never miss a meeting, so start at login by default (the menu can turn it off).
    private func enableLoginOnFirstRun() {
        guard !UserDefaults.standard.bool(forKey: "loginConfigured") else { return }
        do {
            try SMAppService.mainApp.register()
            log("enabled start at login")
        } catch {
            log("could not enable start at login: \(error.localizedDescription)")
        }
        UserDefaults.standard.set(true, forKey: "loginConfigured")
    }

    /// meetrec://name        → "Who's who?" for the last meeting
    /// meetrec://analyze     → open the last meeting in Claude
    /// meetrec://name?dir=/path/to/meeting (same for analyze)
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "meetrec" {
            let dirParam = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "dir" }?.value
            guard let dir = dirParam.map({ URL(fileURLWithPath: $0) }) ?? controller.lastMeeting else { continue }
            switch url.host {
            case "name": controller.nameSpeakers(dir)
            case "analyze": openInClaude(dir)
            default: log("unknown link \(url)")
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller.end()   // finalize files; transcription keeps running on its own
        return .terminateNow
    }

    /// Trigger both permission prompts at launch instead of in the middle of a call.
    private func requestPermissions() async {
        if !(await AVCaptureDevice.requestAccess(for: .audio)) {
            log("✗ no Microphone permission (System Settings › Privacy & Security › Microphone › MeetRec)")
        }
        let probe = SystemAudioTap()
        do {
            try probe.start { _, _ in }
            try? await Task.sleep(nanoseconds: 500_000_000)
        } catch {
            log("✗ system audio unavailable: \(error.localizedDescription)")
        }
        probe.stop()
    }

    private func refresh() {
        let recording = controller.recorder != nil
        if let button = item.button {
            button.image = menuBarIcon(recording: recording)
        }

        let menu = NSMenu()
        let status: String
        if recording {
            status = controller.manual ? "Recording (manual)" : "Recording \(shortName(controller.app))"
        } else {
            status = "Watching for calls"
        }
        menu.addItem(NSMenuItem(title: status, action: nil, keyEquivalent: ""))
        if controller.transcribing > 0 {
            menu.addItem(NSMenuItem(title: "Transcribing \(controller.transcribing)…", action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(entry(recording ? "Stop recording" : "Start recording now", #selector(toggleRecording)))
        if recording && controller.liveEnabled {
            menu.addItem(entry(controller.captionsWindow.isVisible ? "Hide live captions" : "Show live captions",
                               #selector(toggleCaptionsWindow)))
        }
        menu.addItem(.separator())
        let liveToggle = entry("Live captions during calls", #selector(toggleLive))
        liveToggle.state = controller.liveEnabled ? .on : .off
        menu.addItem(liveToggle)
        let langMenu = NSMenu()
        for (code, name) in [("pt-BR", "Português"), ("en-US", "English")] {
            let i = entry(name, #selector(setLanguage(_:)))
            i.representedObject = code
            i.state = controller.liveLocale == code ? .on : .off
            langMenu.addItem(i)
        }
        let lang = NSMenuItem(title: "Live captions language", action: nil, keyEquivalent: "")
        lang.submenu = langMenu
        menu.addItem(lang)
        menu.addItem(.separator())
        if let dir = controller.lastMeeting, MeetingSpeakers.load(dir) != nil {
            menu.addItem(entry("Name speakers in last meeting…", #selector(nameLast)))
        }
        if controller.lastMeeting != nil {
            menu.addItem(entry("Analyze last meeting with Claude…", #selector(analyzeLast)))
        }
        if controller.lastTranscript != nil {
            menu.addItem(entry("Open last transcript", #selector(openLast)))
        }
        menu.addItem(entry("Open Meetings folder", #selector(openFolder)))
        menu.addItem(entry("Open log", #selector(openLog)))
        menu.addItem(.separator())
        let login = entry("Start at login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(entry("Quit MeetRec", #selector(quit), key: "q"))
        item.menu = menu
    }

    private func entry(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc func toggleRecording() {
        if controller.recorder != nil { controller.end() } else { controller.begin(app: "manual", manual: true) }
    }
    @objc func toggleCaptionsWindow() {
        if controller.captionsWindow.isVisible { controller.captionsWindow.hide() } else { controller.captionsWindow.show() }
        refresh()
    }
    @objc func toggleLive() { controller.liveEnabled.toggle() }
    @objc func setLanguage(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? String { controller.liveLocale = code }
    }
    @objc func analyzeLast() { if let d = controller.lastMeeting { openInClaude(d) } }
    @objc func nameLast() { if let d = controller.lastMeeting { controller.nameSpeakers(d) } }
    @objc func openLast() { if let u = controller.lastTranscript { NSWorkspace.shared.open(u) } }
    @objc func openFolder() {
        try? FileManager.default.createDirectory(at: outRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.open(outRoot)
    }
    @objc func openLog() { NSWorkspace.shared.open(logURL) }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            log("start-at-login change failed: \(error.localizedDescription)")
        }
        refresh()
    }
    @objc func quit() { NSApp.terminate(nil) }
}

/// Menu bar glyph matching the app icon: a speech bubble holding a small waveform.
/// Template (adapts to light/dark) when idle; adds a red dot while recording.
func menuBarIcon(recording: Bool) -> NSImage {
    let img = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
        let ink = recording ? NSColor.labelColor : NSColor.black
        ink.setStroke()
        ink.setFill()
        let bubble = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 4.5, width: 15, height: 11), xRadius: 3.5, yRadius: 3.5)
        bubble.lineWidth = 1.5
        bubble.stroke()
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 4, y: 5))
        tail.line(to: NSPoint(x: 3, y: 1.5))
        tail.line(to: NSPoint(x: 7.5, y: 4.6))
        tail.close()
        tail.fill()
        for (i, h) in [3.0, 6.0, 4.0].enumerated() {
            NSBezierPath(roundedRect: NSRect(x: 5.25 + Double(i) * 3, y: 10 - h / 2, width: 1.5, height: h),
                         xRadius: 0.75, yRadius: 0.75).fill()
        }
        if recording {
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: 13, y: 11, width: 7, height: 7)).fill()
        }
        return true
    }
    img.isTemplate = !recording
    img.accessibilityDescription = "MeetRec"
    return img
}

// MARK: - entry point

// Command-line helpers (used for testing and scripting):
//   MeetRec diarize <meeting-dir>            separate + identify voices, rebuild transcript
//   MeetRec name <meeting-dir> S1=Ana ...    name voices (teaches the library), rebuild transcript
/// Runs async CLI work without making the top level async (which would stall the app's main actor).
func runBlocking(_ body: @escaping @Sendable () async -> Void) {
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        await body()
        done.signal()
    }
    done.wait()
}

let cliArgs = Array(CommandLine.arguments.dropFirst())
if cliArgs.first == "diarize", cliArgs.count == 2 {
    let dir = URL(fileURLWithPath: cliArgs[1])
    runBlocking {
      do {
        let m = try await SpeakerIdentifier.shared.identify(dir)
        rebuildTranscript(dir)
        for s in m.speakers { print("\(s.id)\t\(s.label)\t\(Int(s.seconds))s\t\(s.distance.map { String(format: "%.2f", $0) } ?? "-")") }
    } catch {
        print("error: \(error)")
        exit(1)
      }
    }
    exit(0)
}
if cliArgs.first == "name", cliArgs.count >= 3 {
    let dir = URL(fileURLWithPath: cliArgs[1])
    var names: [String: String] = [:]
    for pair in cliArgs.dropFirst(2) {
        let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
        if kv.count == 2 { names[kv[0]] = kv[1] }
    }
    try applySpeakerNames(names, in: dir)
    print("saved \(names.count) name(s); library: \(VoiceLibrary.load().names.joined(separator: ", "))")
    exit(0)
}
if CommandLine.arguments.dropFirst().first == "mics" {
    let users = currentMicUsers()
    print(users.isEmpty ? "nobody is using the mic" : users.map { "\($0.pid)\t\($0.bundleID)" }.joined(separator: "\n"))
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
