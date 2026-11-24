// Codex Resumer — a tiny menu-bar app that continues Codex chats that stopped on a usage limit
// (5-hour or weekly) as soon as the limit resets.
//
// Detection: read-only SQLite query against ~/.codex/thread_history_1.sqlite every 60 s.
// Reset time: a short-lived `codex app-server` call (account/rateLimits/read), only when needed.
// Resume:     open codex://threads/<id> in the Codex desktop app and type the message + Return.

import AppKit
import ApplicationServices
import ServiceManagement
import SQLite3

// MARK: - Settings

enum Settings {
    private static let d = UserDefaults.standard
    static var enabled: Bool {
        get { d.object(forKey: "enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "enabled") }
    }
    /// Thread ids the user unticked: listed in the menu but never resumed.
    static var excluded: Set<String> {
        get { Set(d.stringArray(forKey: "excluded") ?? []) }
        set { d.set(Array(newValue), forKey: "excluded") }
    }
    static var message: String {
        get { d.string(forKey: "message") ?? "continue" }
        set { d.set(newValue, forKey: "message") }
    }
}

let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
    ?? (NSHomeDirectory() + "/.codex")
let codexBundleID = "com.openai.codex"

// MARK: - Paused chats (SQLite)

struct PausedChat {
    let threadID: String
    let turnID: String
    let title: String
}

enum ChatDB {
    /// Chats whose most recent turn failed with `usageLimitExceeded` in the last 8 days.
    static func pausedChats() -> [PausedChat] {
        let path = codexHome + "/thread_history_1.sqlite"
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db); return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        let state = (codexHome + "/state_5.sqlite").replacingOccurrences(of: "'", with: "''")
        let hasState = sqlite3_exec(db, "ATTACH DATABASE '\(state)' AS s", nil, nil, nil) == SQLITE_OK

        let titleSQL = hasState
            ? "(SELECT COALESCE(NULLIF(name,''), NULLIF(title,''), id) FROM s.threads WHERE id = t.thread_id)"
            : "NULL"
        let archivedSQL = hasState
            ? "AND COALESCE((SELECT archived FROM s.threads WHERE id = t.thread_id), 0) = 0"
            : ""
        let sql = """
            SELECT t.thread_id, t.turn_id, \(titleSQL)
            FROM thread_turns t
            WHERE t.status = 'failed'
              AND t.error_json LIKE '%usageLimitExceeded%'
              AND t.started_at > strftime('%s','now') - 8*86400
              AND t.rollout_ordinal = (SELECT MAX(rollout_ordinal) FROM thread_turns x
                                       WHERE x.thread_id = t.thread_id)
              \(archivedSQL)
            ORDER BY t.started_at
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [PausedChat] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func col(_ i: Int32) -> String? {
                sqlite3_column_text(stmt, i).map { String(cString: $0) }
            }
            guard let tid = col(0), let turn = col(1) else { continue }
            let title = (col(2) ?? tid).split(separator: "\n").first.map(String.init) ?? tid
            out.append(PausedChat(threadID: tid, turnID: turn, title: title))
        }
        return out
    }
}

// MARK: - Rate limits (codex app-server)

struct Window {
    let usedPercent: Double
    let resetsAt: Date?
    let minutes: Int
}

struct Limits {
    let primary: Window?
    let secondary: Window?
    let allowed: Bool

    var limited: Bool {
        !allowed || (primary?.usedPercent ?? 0) >= 100 || (secondary?.usedPercent ?? 0) >= 100
    }
    /// When every exhausted window has reset.
    var resumeAt: Date? {
        [primary, secondary].compactMap { $0 }
            .filter { $0.usedPercent >= 100 }
            .compactMap(\.resetsAt).max()
    }
}

enum CodexCLI {
    static func executable() -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            home + "/.local/bin/codex", home + "/.npm-global/bin/codex", home + "/.bun/bin/codex",
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// Spawns `codex app-server`, asks for account/rateLimits/read, and exits. Runs off the main thread.
    static func readLimits(completion: @escaping (Limits?) -> Void) {
        guard let exe = executable() else { completion(nil); return }
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = ["app-server"]
            let input = Pipe(), output = Pipe()
            p.standardInput = input
            p.standardOutput = output
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { DispatchQueue.main.async { completion(nil) }; return }

            let requests = [
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-resumer","version":"1.0"}}}"#,
                #"{"jsonrpc":"2.0","method":"initialized"}"#,
                #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read"}"#,
            ].joined(separator: "\n") + "\n"
            input.fileHandleForWriting.write(requests.data(using: .utf8)!)

            // Watchdog: closing the process ends the blocking read below.
            let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: watchdog)

            var buffer = Data()
            var result: Limits?
            let reader = output.fileHandleForReading
            readLoop: while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer.removeSubrange(buffer.startIndex...nl)
                    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          (obj["id"] as? Int) == 2 else { continue }
                    result = parse(obj["result"] as? [String: Any])
                    break readLoop
                }
            }
            watchdog.cancel()
            try? input.fileHandleForWriting.close()
            if p.isRunning { p.terminate() }
            buffer = Data()
            DispatchQueue.main.async {
                completion(result)
                malloc_zone_pressure_relief(nil, 0) // hand the JSON scratch pages back to the OS
            }
        }
    }

    private static func parse(_ r: [String: Any]?) -> Limits? {
        guard let r, let rl = r["rateLimits"] as? [String: Any] else { return nil }
        func window(_ key: String) -> Window? {
            guard let w = rl[key] as? [String: Any] else { return nil }
            let used = (w["usedPercent"] as? NSNumber)?.doubleValue ?? 0
            let at = (w["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return Window(usedPercent: used, resetsAt: at,
                          minutes: (w["windowDurationMins"] as? NSNumber)?.intValue ?? 0)
        }
        return Limits(primary: window("primary"), secondary: window("secondary"),
                      allowed: r["ordinaryUsageAllowed"] as? Bool ?? true)
    }
}

// MARK: - Typing into the Codex desktop app

enum Typist {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func promptForAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static var codexIsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == codexBundleID
    }

    /// Opens the chat, waits for Codex to show it, focuses the composer, types `text` and presses Return.
    static func send(_ text: String, to threadID: String, completion: @escaping (Bool) -> Void) {
        guard trusted, let url = URL(string: "codex://threads/\(threadID)") else {
            completion(false); return
        }
        NSWorkspace.shared.open(url)
        waitForCodex(deadline: Date().addingTimeInterval(20)) { ok in
            guard ok else { completion(false); return }
            // Give the chat view time to load before focusing the composer.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                guard codexIsFrontmost, let app = NSWorkspace.shared.frontmostApplication else {
                    completion(false); return
                }
                focusComposer(pid: app.processIdentifier)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    guard codexIsFrontmost else { completion(false); return }
                    type(text)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        guard codexIsFrontmost else { completion(false); return }
                        key(36) // Return
                        completion(true)
                    }
                }
            }
        }
    }

    private static func waitForCodex(deadline: Date, _ done: @escaping (Bool) -> Void) {
        if codexIsFrontmost { done(true); return }
        if Date() > deadline { done(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { waitForCodex(deadline: deadline, done) }
    }

    /// Electron hides its accessibility tree until asked; then find the chat composer (a text area).
    private static func focusComposer(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let window = win else { return }
        var budget = 4000
        var found: AXUIElement?
        func walk(_ el: AXUIElement, depth: Int) {
            guard budget > 0, depth < 40 else { return }
            budget -= 1
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
            if (role as? String) == kAXTextAreaRole as String { found = el } // keep the last (bottom) one
            var kids: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
                  let children = kids as? [AXUIElement] else { return }
            for c in children { walk(c, depth: depth + 1) }
        }
        walk(window as! AXUIElement, depth: 0)
        if let found {
            AXUIElementSetAttributeValue(found, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
    }

    private static func type(_ text: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 16, units.count)])
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                e?.post(tap: .cghidEventTap)
            }
            i += 16
        }
    }

    private static func key(_ code: CGKeyCode) {
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    }
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private let menu = NSMenu()
    private var timer: DispatchSourceTimer?

    private var paused: [PausedChat] = []
    private var limits: Limits?
    private var limitsFetchedAt = Date.distantPast
    private var fetching = false
    private var nextCheck = Date.distantPast       // when to re-ask codex about the reset
    private var resuming = false
    private var attempts: [String: Int] = [:]      // failed turn id → resume attempts
    private var lastAttempt: [String: Date] = [:]  // thread id → last time we typed into it
    private var status = ""

    /// Paused chats the user wants resumed (ticked in the menu).
    private var selected: [PausedChat] {
        let skip = Settings.excluded
        return paused.filter { !skip.contains($0.threadID) }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu

        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 60, leeway: .seconds(10))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.tick() }
        updateIcon()
    }

    // Core loop: cheap SQLite poll; only talks to codex while something is paused.
    private func tick() {
        paused = ChatDB.pausedChats().filter { (attempts[$0.turnID] ?? 0) < 3 }
        updateIcon()
        guard Settings.enabled, !selected.isEmpty, !resuming, Date() >= nextCheck else { return }
        refreshLimits { [weak self] l in
            guard let self else { return }
            guard let l else {
                self.nextCheck = Date().addingTimeInterval(300)
                self.status = "Couldn't read usage from codex; retrying in 5 min"
                return
            }
            if l.limited {
                // Wait until the exhausted window(s) reset, plus a small grace period.
                let at = l.resumeAt ?? Date().addingTimeInterval(600)
                self.nextCheck = max(at.addingTimeInterval(20), Date().addingTimeInterval(60))
                self.status = ""
                self.updateIcon()
            } else {
                self.resumeAll()
            }
        }
    }

    private func refreshLimits(_ done: ((Limits?) -> Void)? = nil) {
        guard !fetching else { done?(limits); return }
        fetching = true
        CodexCLI.readLimits { [weak self] l in
            guard let self else { return }
            self.fetching = false
            if let l { self.limits = l; self.limitsFetchedAt = Date() }
            self.rebuildMenu()
            done?(l)
        }
    }

    private func resumeAll(force: Bool = false) {
        guard Typist.trusted else {
            status = "Needs Accessibility permission to type into Codex"
            updateIcon()
            return
        }
        // Never nudge the same chat twice within 15 min (guards against a limit codex doesn't report).
        let now = Date()
        let due = selected.filter { force || now.timeIntervalSince(lastAttempt[$0.threadID] ?? .distantPast) > 900 }
        guard !due.isEmpty else { return }
        resume(queue: due, previous: NSWorkspace.shared.frontmostApplication)
    }

    private func resume(queue: [PausedChat], previous: NSRunningApplication?) {
        guard let chat = queue.first else {
            resuming = false
            nextCheck = Date().addingTimeInterval(30)
            if let previous, previous.bundleIdentifier != codexBundleID,
               previous.bundleIdentifier != Bundle.main.bundleIdentifier {
                previous.activate()
            }
            tick()
            return
        }
        resuming = true
        attempts[chat.turnID, default: 0] += 1
        lastAttempt[chat.threadID] = Date()
        Typist.send(Settings.message, to: chat.threadID) { [weak self] ok in
            guard let self else { return }
            self.status = ok ? "Resumed “\(chat.title)”" : "Couldn't type into Codex for “\(chat.title)”"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.resume(queue: Array(queue.dropFirst()), previous: previous)
            }
        }
    }

    // MARK: UI

    private func updateIcon() {
        let name = selected.isEmpty ? "arrow.clockwise.circle" : "pause.circle"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Codex Resumer")
        img?.isTemplate = true
        item.button?.image = img
        item.button?.appearsDisabled = !Settings.enabled
        let n = selected.count
        if paused.isEmpty {
            item.button?.toolTip = "Codex Resumer — no paused chats"
        } else if n == 0 {
            item.button?.toolTip = "\(paused.count) paused · none selected to resume"
        } else if nextCheck > Date() {
            item.button?.toolTip = "\(n) to resume \(Self.fmt(nextCheck))"
        } else {
            item.button?.toolTip = "\(n) to resume"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        paused = ChatDB.pausedChats().filter { (attempts[$0.turnID] ?? 0) < 3 }
        rebuildMenu()
        if Date().timeIntervalSince(limitsFetchedAt) > 60 { refreshLimits() }
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        func info(_ s: String) {
            let i = NSMenuItem(title: s, action: nil, keyEquivalent: "")
            i.isEnabled = false
            menu.addItem(i)
        }
        func action(_ s: String, _ sel: Selector, key: String = "") -> NSMenuItem {
            let i = NSMenuItem(title: s, action: sel, keyEquivalent: key)
            i.target = self
            menu.addItem(i)
            return i
        }

        if let l = limits {
            if let p = l.primary { info(Self.line(p.minutes >= 1440 ? "Weekly" : "5-hour", p)) }
            if let s = l.secondary { info(Self.line(s.minutes >= 1440 ? "Weekly" : "5-hour", s)) }
        } else {
            info(fetching ? "Reading usage…" : "Usage unknown")
        }

        menu.addItem(.separator())
        if paused.isEmpty {
            info("No chats paused by a limit")
        } else {
            let when = nextCheck > Date() && !selected.isEmpty ? " · resume \(Self.fmt(nextCheck))" : ""
            info("Paused chats — tick to auto-resume\(when)")
            let skip = Settings.excluded
            for c in paused {
                let i = action(Self.clip(c.title), #selector(toggleChat(_:)))
                i.representedObject = c.threadID
                i.state = skip.contains(c.threadID) ? .off : .on
                i.toolTip = "Click to include or skip · hold ⌥ to open in Codex"
                // Holding Option swaps the row for "Open in Codex".
                let open = action("Open “\(Self.clip(c.title, 34))” in Codex", #selector(openChat(_:)))
                open.representedObject = c.threadID
                open.keyEquivalentModifierMask = .option
                open.isAlternate = true
            }
            let now = action("Resume Selected Now", #selector(resumeNow))
            now.isEnabled = !selected.isEmpty
        }
        if !status.isEmpty { info(status) }

        menu.addItem(.separator())
        if !Typist.trusted {
            _ = action("Grant Accessibility Access…", #selector(grantAccess))
        }
        let auto = action("Auto-Resume After Reset", #selector(toggleEnabled))
        auto.state = Settings.enabled ? .on : .off
        _ = action("Message: “\(Self.clip(Settings.message, 24))”…", #selector(editMessage))
        let login = action("Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        _ = action("Quit", #selector(quit), key: "q")
    }

    @objc private func openChat(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let url = URL(string: "codex://threads/\(id)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleChat(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var skip = Settings.excluded
        if skip.contains(id) { skip.remove(id) } else { skip.insert(id) }
        Settings.excluded = skip
        nextCheck = .distantPast
        updateIcon()
        tick()
    }

    @objc private func resumeNow() { if !resuming { resumeAll(force: true) } }

    @objc private func grantAccess() { Typist.promptForAccess() }

    @objc private func toggleEnabled() {
        Settings.enabled.toggle()
        nextCheck = .distantPast
        updateIcon()
        tick()
    }

    @objc private func editMessage() {
        let alert = NSAlert()
        alert.messageText = "Message sent when a limit resets"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = Settings.message
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { Settings.message = v }
        }
    }

    @objc private func toggleLogin() {
        let s = SMAppService.mainApp
        do {
            if s.status == .enabled { try s.unregister() } else { try s.register() }
        } catch {
            status = "Launch at Login failed: \(error.localizedDescription)"
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Formatting

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE h:mm a"; return f
    }()

    static func fmt(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? timeFmt.string(from: d) : dayFmt.string(from: d)
    }

    static func line(_ name: String, _ w: Window) -> String {
        let reset = w.resetsAt.map { " · resets \(fmt($0))" } ?? ""
        return "\(name): \(Int(w.usedPercent.rounded()))% used\(reset)"
    }

    static func clip(_ s: String, _ n: Int = 40) -> String {
        s.count > n ? String(s.prefix(n - 1)) + "…" : s
    }
}

// MARK: - CLI helpers (`--dump` prints state, `--snapshot <png>` renders the menu for docs)

extension App {
    /// The menu's text lines, built from live data. Waits for the usage read.
    static func menuLines() -> [String] {
        var limits: Limits?
        let done = DispatchSemaphore(value: 0)
        CodexCLI.readLimits { limits = $0; done.signal() }
        while done.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        var lines: [String] = []
        if let l = limits {
            for w in [l.primary, l.secondary].compactMap({ $0 }) {
                lines.append(line(w.minutes >= 1440 ? "Weekly" : "5-hour", w))
            }
            lines.append("limited: \(l.limited), resume at: \(l.resumeAt.map(fmt) ?? "-")")
        } else {
            lines.append("Usage unknown (codex not found or no response)")
        }
        let paused = ChatDB.pausedChats()
        lines.append(paused.isEmpty ? "No chats paused by a limit" : "Paused chats — tick to auto-resume")
        let skip = Settings.excluded
        lines += paused.map { "\(skip.contains($0.threadID) ? "    " : "✓ ")\(clip($0.title))  [\($0.threadID)]" }
        lines.append("Accessibility trusted: \(Typist.trusted)")
        return lines
    }

    static func snapshot(to path: String) {
        let raw = menuLines().filter { !$0.hasPrefix("limited:") && !$0.hasPrefix("Accessibility") }
        let rows: [(String, Bool)] = raw.map { line in
            let isChat = line.range(of: #"\[[0-9a-f-]+\]$"#, options: .regularExpression) != nil
            return (line.replacingOccurrences(of: #"\s+\[[0-9a-f-]+\]"#, with: "",
                                              options: .regularExpression), isChat)
        } + [("—", false), ("Resume Selected Now", true), ("—", false),
               ("✓ Auto-Resume After Reset", true), ("Message: “\(Settings.message)”…", true),
               ("Launch at Login", true), ("—", false), ("Quit", true)]
        let w: CGFloat = 340, rowH: CGFloat = 22, pad: CGFloat = 8
        let h = pad * 2 + rows.reduce(0) { $0 + ($1.0 == "—" ? 10 : rowH) }
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale),
                                         pixelsHigh: Int(h * scale), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        rep.size = NSSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.97, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: h), xRadius: 10, yRadius: 10).fill()
        var y = h - pad
        for (text, active) in rows {
            if text == "—" {
                y -= 10
                NSColor(white: 0.85, alpha: 1).setFill()
                NSRect(x: 12, y: y + 4.5, width: w - 24, height: 1).fill()
                continue
            }
            y -= rowH
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.menuFont(ofSize: 13),
                .foregroundColor: active ? NSColor.black : NSColor(white: 0.5, alpha: 1),
            ]
            (text as NSString).draw(at: NSPoint(x: 16, y: y + 3), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

let args = CommandLine.arguments
if args.contains("--dump") {
    App.menuLines().forEach { print($0) }
    exit(0)
}
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    App.snapshot(to: args[i + 1])
    exit(0)
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
