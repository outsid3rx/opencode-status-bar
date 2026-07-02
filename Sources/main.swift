import Cocoa

// Simple file logger. Writes to ~/Library/Logs/OpenCodeStatusBar/OpenCodeStatusBar.log
// and mirrors to NSLog so Console.app can also see the messages.
final class Logger {
    static let shared = Logger()
    private let dateFormatter = DateFormatter()
    private let queue = DispatchQueue(label: "com.local.opencodestatusbar.logger")
    private var fileHandle: FileHandle?

    init() {
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let logDir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/OpenCodeStatusBar")
        let fm = FileManager.default
        try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true, attributes: nil)
        let logPath = (logDir as NSString).appendingPathComponent("OpenCodeStatusBar.log")
        fm.createFile(atPath: logPath, contents: nil, attributes: nil)
        fileHandle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
    }

    func log(_ message: String) {
        let line = "[\(dateFormatter.string(from: Date()))] \(message)\n"
        queue.async { [weak self] in
            guard let self = self, let data = line.data(using: .utf8) else { return }
            do {
                try self.fileHandle?.write(contentsOf: data)
                try self.fileHandle?.synchronize()
            } catch {
                // If logging fails, avoid infinite loops; fall back to NSLog only.
            }
            NSLog("OpenCodeStatusBar: %@", message)
        }
    }
}

// Custom-drawn toggle. NSSwitch can't show its accent inside a menu (the menu's vibrant, non-key
// window draws the implicit accent gray), so we render the track + knob as layers and fill the
// "on" color explicitly. Layer-hosted so the knob can slide on Apple's switch spring (CASpringAnimation),
// with the track color crossfading; CA animations run in the render server, so they play during menu tracking.
final class ToggleView: NSView {
    static let w: CGFloat = 33, h: CGFloat = 16
    private let track = CALayer()
    private let knob = CALayer()
    private var lastToggle = Date.distantPast   // debounce: ignore a re-click within a short window
    private var hovered = false
    var isOn: Bool { didSet { updateState(animated: true) } }
    var onToggle: ((Bool) -> Void)?

    init(isOn: Bool) {
        self.isOn = isOn
        super.init(frame: NSRect(x: 0, y: 0, width: ToggleView.w, height: ToggleView.h))
        layer = CALayer()
        wantsLayer = true
        track.frame = bounds
        track.cornerRadius = bounds.height / 2
        layer?.addSublayer(track)
        let kh = bounds.height - 4, kw = kh + 3   // capsule: a touch wider than tall, like modern macOS
        knob.bounds = CGRect(x: 0, y: 0, width: kw, height: kh)
        knob.cornerRadius = kh / 2
        knob.backgroundColor = NSColor.white.cgColor
        layer?.addSublayer(knob)
        updateState(animated: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: ToggleView.w, height: ToggleView.h) }

    private func knobCenter() -> CGPoint {
        let kw = knob.bounds.width
        return CGPoint(x: isOn ? bounds.width - kw / 2 - 2 : kw / 2 + 2, y: bounds.height / 2)
    }

    // Track fill. ON = accent. OFF = an explicit mid gray (the system's faint off color disappears on a
    // light menu, and a dynamic NSColor's .cgColor can latch the wrong appearance → white-on-white), so
    // pick black-on-light / white-on-dark from our OWN effectiveAppearance. Hover nudges it darker.
    private func trackColor() -> CGColor {
        if isOn {
            let accent = NSColor.controlAccentColor
            return (hovered ? (accent.blended(withFraction: 0.10, of: .white) ?? accent) : accent).cgColor
        }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let base: CGFloat = dark ? 1.0 : 0.0
        let alpha: CGFloat = (dark ? 0.30 : 0.34) + (hovered ? 0.10 : 0)
        return NSColor(white: base, alpha: alpha).cgColor
    }

    private func updateState(animated: Bool) {
        let toColor = trackColor()
        let toPos = knobCenter()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated {
            let spring = CASpringAnimation(keyPath: "position")
            spring.fromValue = NSValue(point: knob.presentation()?.position ?? knob.position)
            spring.toValue = NSValue(point: toPos)
            spring.damping = 16; spring.stiffness = 260; spring.mass = 1; spring.initialVelocity = 0
            spring.duration = spring.settlingDuration
            knob.add(spring, forKey: "position")
            let col = CABasicAnimation(keyPath: "backgroundColor")
            col.fromValue = track.presentation()?.backgroundColor ?? track.backgroundColor
            col.toValue = toColor
            col.duration = 0.2
            track.add(col, forKey: "backgroundColor")
        }
        knob.position = toPos
        track.backgroundColor = toColor
        CATransaction.commit()
    }

    // Recolor when the view actually lands in the menu (its effectiveAppearance only resolves to the
    // menu's light/dark then, not at init), so the off gray matches the menu it's drawn on.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateState(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateState(animated: false) }
    override func mouseExited(with event: NSEvent) { hovered = false; updateState(animated: false) }

    override func mouseDown(with event: NSEvent) {
        guard Date().timeIntervalSince(lastToggle) > 0.1 else { return }
        lastToggle = Date()
        isOn.toggle()
        onToggle?(isOn)
    }
}

// A session row as a custom view so a flexible spacer can pin the timer + pill to the true trailing
// edge (a plain menu-item title can't cross the menu's reserved shortcut/submenu-arrow column).
// Layout: [icon] name  <spacer>  timer  [pill], with timer+pill pinned right via autoresizing.
final class SessionRowView: NSView {
    let id: String
    var onClick: (() -> Void)?
    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let timerField = NSTextField(labelWithString: "")
    private let pillView = NSImageView()
    private let pad: CGFloat = 14, iconSize: CGFloat = 16, rowH: CGFloat = 24, timerW: CGFloat = 74
    private let highlightView = NSVisualEffectView()  // system selection material = exact native highlight
    private var hovered = false
    private var iconBaseTint: NSColor?       // tint when not hovered (template icons); white on hover
    private var pillNormal: NSImage?, pillSelected: NSImage?

    init(id: String, width: CGFloat) {
        self.id = id
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: rowH))
        autoresizingMask = [.width]
        highlightView.material = .selection
        highlightView.state = .active
        highlightView.isEmphasized = true
        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = 5
        highlightView.isHidden = true
        addSubview(highlightView)
        iconView.frame = NSRect(x: pad, y: (rowH - iconSize) / 2, width: iconSize, height: iconSize)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.autoresizingMask = [.maxXMargin]
        addSubview(iconView)
        nameField.font = .menuFont(ofSize: 0)
        nameField.textColor = .labelColor
        nameField.lineBreakMode = .byTruncatingTail
        nameField.frame = NSRect(x: pad + iconSize + 8, y: (rowH - 16) / 2, width: 160, height: 16)
        nameField.autoresizingMask = [.maxXMargin]
        addSubview(nameField)
        timerField.font = NSFont.monospacedSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize - 2, weight: .regular)
        timerField.textColor = .secondaryLabelColor
        timerField.alignment = .right
        timerField.autoresizingMask = [.minXMargin]
        addSubview(timerField)
        pillView.imageScaling = .scaleNone
        pillView.autoresizingMask = [.minXMargin]
        addSubview(pillView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setIcon(_ img: NSImage?) { iconView.image = img }

    func configure(icon: NSImage?, iconTint: NSColor?, name: String, timer: String?,
                   pillNormal: NSImage?, pillSelected: NSImage?, pillInset: CGFloat, timerGap: CGFloat) {
        let w = bounds.width
        iconView.image = icon
        iconBaseTint = iconTint
        iconView.contentTintColor = hovered ? .white : iconTint
        nameField.stringValue = name
        self.pillNormal = pillNormal; self.pillSelected = pillSelected
        let pill = hovered ? pillSelected : pillNormal
        var pillLeft = w - pillInset
        if let pill = pill {
            pillView.isHidden = false
            pillView.image = pill
            pillView.frame = NSRect(x: w - pillInset - pill.size.width, y: (rowH - pill.size.height) / 2,
                                    width: pill.size.width, height: pill.size.height)
            pillLeft = pillView.frame.minX
        } else { pillView.isHidden = true }
        if let timer = timer {
            timerField.isHidden = false
            timerField.stringValue = timer
            timerField.frame = NSRect(x: pillLeft - timerGap - timerW, y: (rowH - 16) / 2, width: timerW, height: 16)
        } else { timerField.isHidden = true }
    }
    // Custom views don't get the menu's automatic hover highlight, so draw it ourselves.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }
    private func setHover(_ h: Bool) {
        hovered = h
        highlightView.isHidden = !h
        nameField.textColor = h ? .white : .labelColor
        timerField.textColor = h ? .white : .secondaryLabelColor
        iconView.contentTintColor = h ? .white : iconBaseTint
        if !pillView.isHidden { pillView.image = h ? pillSelected : pillNormal }
    }
    override func layout() {
        super.layout()
        highlightView.frame = bounds.insetBy(dx: 5, dy: 0)
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

final class StatusController: NSObject, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let stateDir = (NSHomeDirectory() as NSString).appendingPathComponent(".local/state/opencode/statusbar/state.d")
    let configDir = (NSHomeDirectory() as NSString).appendingPathComponent(".config/opencode")
    let pluginInstallDir = (NSHomeDirectory() as NSString).appendingPathComponent(".config/opencode/plugins")
    let isAutoLaunch = ProcessInfo.processInfo.arguments.contains("--auto-launch")

    var pollTimer: Timer?
    var animTimer: Timer?
    var spinTimer: Timer?      // rotates the working-state spinner while the menu is open
    var spinAngle: CGFloat = 0
    var frameIdx = 0

    let launchedAt = Date()
    var notNeededSince: Date?
    let launchGrace: TimeInterval = 5   // settle time after launch before we may quit
    let idleQuitDelay: TimeInterval = 3 // "not needed" must persist this long before quitting
    let bootstrapTimeout: TimeInterval = 300 // auto-launched app waits this long for the first session
    var hasSeenSessions = false           // true once any session file has appeared
    // "Hide idle after" setting (seconds): hide a resting session's ROW once it's been quiet this long.
    // Render-only — it never deletes the file or affects liveness (that's pid-driven now), and the
    // most-recent session is always kept visible (floor at one). 0 = Never. Defaults to 30 min.
    var stalePruneAge: TimeInterval { UserDefaults.standard.object(forKey: "hideIdleAfter") as? Double ?? 1800 }

    struct Session {
        var id: String, state: String, label: String, project: String
        var entrypoint: String  // always "cli" for the terminal-only build
        var termProgram: String // TERM_PROGRAM for CLI sessions: "Apple_Terminal", "iTerm.app", …
        var pid: Int32          // the session's OpenCode process; kill(pid,0) drives liveness. 0 = pre-upgrade file.
        var started: Bool       // true once the session had real activity (a prompt/tool); a merely-opened
                                // conversation seeds started=false and stays out of the dropdown.
        var startedAt: Double, ts: Double
        var seq: Int            // monotonic write counter from the plugin; detects changes even when
                                // mtime stays the same across multiple writes in one second.
        var eff: String = ""   // effective state, recomputed once per tick in evaluate()

        init(json o: [String: Any], id: String) {
            self.id = id
            self.state = o["state"] as? String ?? "idle"
            self.label = o["label"] as? String ?? ""
            self.project = o["project"] as? String ?? ""
            self.entrypoint = o["entrypoint"] as? String ?? ""
            self.termProgram = o["term_program"] as? String ?? ""
            self.pid = Int32(truncatingIfNeeded: (o["pid"] as? NSNumber)?.intValue ?? 0)
            self.started = o["started"] as? Bool ?? false
            self.startedAt = (o["startedAt"] as? NSNumber)?.doubleValue ?? 0
            self.ts = (o["ts"] as? NSNumber)?.doubleValue ?? 0
            self.seq = (o["seq"] as? NSNumber)?.intValue ?? 0
        }
    }
    var sessions: [String: Session] = [:]  // id -> latest parsed per-session state
    var fileMTimes: [String: Date] = [:]   // "<id>.json" -> last-parsed mtime (re-parse only on change)
    var fileSeqs: [String: Int] = [:]      // "<id>.json" -> last-parsed seq counter (mtime can alias)
    var soundPrev: [String: String] = [:]  // id -> previous raw state (completion-sound edge)
    var turnStart: [String: Double] = [:]  // id -> active turn start (1-min sound gate)
    var menuIsOpen = false                  // refresh the dropdown's per-session timers only while open
    var sessionMenuItems: [(item: NSMenuItem, id: String)] = []
    var activeBase = ""        // label without the elapsed clock
    var startedAt: Double = 0  // unix seconds the current turn began (0 = no clock)
    var activeColor: NSColor? = nil

    let brand = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1) // #d97757, current accent orange
    let amber = NSColor(srgbRed: 0.95, green: 0.73, blue: 0.18, alpha: 1) // "awaiting permission" yellow dot
    enum AnimStyle: String, CaseIterable { case spinner, terminal }
    var animStyle: AnimStyle = .terminal // default to the terminal-style spinner
    var showTimer = false
    var iconSystem = false // false = brand Orange; true = adaptive black/white (template image)
    var playCompletionSound = true // chime whenever a working session reaches done
    var playPermissionSound = true // chime whenever a session awaits permission
    lazy var completionSound: NSSound? = {
        guard let p = Bundle.main.path(forResource: "completion", ofType: "mp3"),
              let s = NSSound(contentsOfFile: p, byReference: true) else { return nil }
        s.volume = 0.7 // the clip is loud at full system volume; play it a bit softer
        return s
    }()
    var iconColor: NSColor? { iconSystem ? nil : brand } // nil => render as an adaptive template
    let spinnerGlyphs = ["✻", "✽", "✶", "✳", "✢"]
    let spinnerPeaks: [CGFloat] = [1.0, 1.0, 1.0, 1.0, 1.0]
    let terminalGlyphs = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    lazy var glyphMasks: [AnimStyle: [NSImage]] = [
        .spinner: spinnerGlyphs.map { StatusController.glyphMask($0) },
        .terminal: terminalGlyphs.map { StatusController.centeredGlyphMask($0) },
    ]
    func glyphs(for style: AnimStyle) -> [String] {
        switch style {
        case .spinner: return spinnerGlyphs
        case .terminal: return terminalGlyphs
        }
    }
    func peaks(for style: AnimStyle) -> [CGFloat] {
        switch style {
        case .spinner: return spinnerPeaks
        case .terminal: return Array(repeating: 1.0, count: terminalGlyphs.count)
        }
    }
    func animConfig(for style: AnimStyle) -> (sub: Int, dip: CGFloat, cycle: Double) {
        switch style {
        case .spinner: return (sub: 18, dip: 0.14, cycle: 3.8)
        case .terminal: return (sub: 1, dip: 1.0, cycle: 0.8)
        }
    }
    var fps: Double {
        let cfg = animConfig(for: animStyle)
        return Double(glyphs(for: animStyle).count * cfg.sub) / cfg.cycle
    }
    var frameCount: Int {
        let cfg = animConfig(for: animStyle)
        return glyphs(for: animStyle).count * cfg.sub
    }

    override init() {
        super.init()
        Logger.shared.log("=== App launched ===")
        Logger.shared.log("arguments: \(ProcessInfo.processInfo.arguments)")
        Logger.shared.log("autoLaunch: \(isAutoLaunch)")
        Logger.shared.log("stateDir: \(stateDir)")
        Logger.shared.log("pluginInstallDir: \(pluginInstallDir)")
        let d = UserDefaults.standard
        if d.object(forKey: "showTimer") != nil { showTimer = d.bool(forKey: "showTimer") }
        if d.object(forKey: "iconSystem") != nil { iconSystem = d.bool(forKey: "iconSystem") }
        if d.object(forKey: "completionSound") != nil { playCompletionSound = d.bool(forKey: "completionSound") }
        if d.object(forKey: "permissionSound") != nil { playPermissionSound = d.bool(forKey: "permissionSound") }
        if let s = d.string(forKey: "animStyle"), let st = AnimStyle(rawValue: s) { animStyle = st }
        Logger.shared.log("settings: completionSound=\(playCompletionSound) permissionSound=\(playPermissionSound) animStyle=\(animStyle.rawValue) completionSoundLoaded=\(completionSound != nil)")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        render(label: "", color: iconColor, animate: false, startedAt: 0)
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        tick()
        ensurePluginInstalled()
        checkForUpdate()
    }

    // Re-runs on first launch AND on every app version change, so upgrades pick up plugin changes.
    func ensurePluginInstalled() {
        let d = UserDefaults.standard
        let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        guard d.string(forKey: "installedPluginVersion") != current,
              let bundled = Bundle.main.path(forResource: "opencode-status-bar", ofType: "js") else { return }
        DispatchQueue.global().async {
            let fm = FileManager.default
            do {
                try fm.createDirectory(atPath: self.pluginInstallDir, withIntermediateDirectories: true, attributes: nil)
            } catch {
                Logger.shared.log("could not create plugin dir: \(error.localizedDescription)")
                return
            }
            let dest = (self.pluginInstallDir as NSString).appendingPathComponent("opencode-status-bar.js")
            try? fm.removeItem(atPath: dest)
            do {
                try fm.copyItem(atPath: bundled, toPath: dest)
                UserDefaults.standard.set(current, forKey: "installedPluginVersion")
                Logger.shared.log("copied plugin to \(dest)")
            } catch {
                Logger.shared.log("failed to copy plugin: \(error.localizedDescription)")
            }
        }
    }

    // MARK: update check

    var currentVersion: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0" }
    let releaseAPIURL = "https://api.github.com/repos/outsid3rx/opencode-status-bar/releases/latest"
    let releasePageURL = "https://github.com/outsid3rx/opencode-status-bar/releases/latest"

    // Once/day: cache GitHub's latest release tag in UserDefaults. Nothing sent to us.
    func checkForUpdate() {
        let d = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        if now - d.double(forKey: "lastUpdateCheck") < 86400 { return }
        guard let url = URL(string: releaseAPIURL) else { return }
        var req = URLRequest(url: url)
        req.setValue("OpenCodeStatusBar", forHTTPHeaderField: "User-Agent") // GitHub API requires a UA
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else { return }
            let ver = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            UserDefaults.standard.set(ver, forKey: "latestVersion")
            UserDefaults.standard.set(now, forKey: "lastUpdateCheck")
        }.resume()
    }

    // Numeric component-wise compare so "0.0.10" > "0.0.9".
    func versionIsNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    @objc func openLatestRelease() {
        if let url = URL(string: releasePageURL) { NSWorkspace.shared.open(url) }
    }

    // MARK: menu

    // The poll timer runs in .common mode, so it keeps firing while the menu tracks; we use that
    // to live-update the per-session elapsed clocks. menuNeedsUpdate rebuilds the rows on each open.
    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        spinTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.spinTick() }
        RunLoop.main.add(t, forMode: .common)  // .common so it fires during menu tracking
        spinTimer = t
    }
    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        sessionMenuItems.removeAll()
        spinTimer?.invalidate(); spinTimer = nil
    }

    func spinTick() {
        spinAngle += 5   // 30fps * 5° = 150°/s ≈ 0.42 rev/s, a calm spin
        guard let img = rotatedSpinner(spinAngle) else { return }
        let now = Date().timeIntervalSince1970
        for (item, id) in sessionMenuItems {
            guard let s = sessions[id], let v = item.view as? SessionRowView else { continue }
            let eff = s.eff.isEmpty ? effectiveState(s, now: now) : s.eff
            if eff == "thinking" || eff == "tool" { v.setIcon(img) }
        }
    }

    // The session SET only changes on reopen (NSMenu can't add/remove rows reliably mid-track).
    func refreshOpenMenuRows() {
        let now = Date().timeIntervalSince1970
        for (item, id) in sessionMenuItems {
            guard let s = sessions[id], let v = item.view as? SessionRowView else { continue }
            let eff = s.eff.isEmpty ? effectiveState(s, now: now) : s.eff
            configureSessionRow(v, s, eff: eff)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        checkForUpdate() // refreshes the update cache for next open (gated to once a day)

        sessionMenuItems.removeAll()
        let now = Date().timeIntervalSince1970
        // Terminal sessions surface as soon as they are alive. Any active state counts as started.
        let ordered = sessions.values.sorted { $0.ts > $1.ts }   // most-recent first
        // Hide rows idle past the threshold, but ALWAYS keep the most-recent started session (floor at
        // one) so the dropdown never goes empty while a session is alive. Hiding is render-only; the file
        // (and thus liveness) is untouched — see stalePruneAge and the pid-driven reap in evaluate().
        var visible = ordered.filter { s in
            let eff = s.eff.isEmpty ? effectiveState(s, now: now) : s.eff
            let resting = !(eff == "permission" || eff == "thinking" || eff == "tool")
            return !(stalePruneAge > 0 && resting && now - s.ts > stalePruneAge)
        }
        if visible.isEmpty, let lead = ordered.first { visible = [lead] }   // floor: never empty while alive

        if !visible.isEmpty {
            menu.addItem(header("Sessions"))
            for s in visible {
                let eff = s.eff.isEmpty ? effectiveState(s, now: now) : s.eff
                let view = SessionRowView(id: s.id, width: CGFloat(uiConfig()["boxWidth"] ?? 300))
                let sid = s.id, tp = s.termProgram
                view.onClick = { [weak self] in menu.cancelTracking(); self?.openSession(sid, termProgram: tp) }
                configureSessionRow(view, s, eff: eff)
                let it = NSMenuItem()
                it.view = view
                menu.addItem(it)
                sessionMenuItems.append((it, s.id))  // kept so tick() can live-update the timers
            }
            menu.addItem(.separator())
        }

        menu.addItem(header("Options"))

        menu.addItem(toggleRow(title: "Show timer", isOn: showTimer) { [weak self] on in
            self?.showTimer = on
            UserDefaults.standard.set(on, forKey: "showTimer")
            self?.applyTitle()
        })
        menu.addItem(toggleRow(title: "Completion sound", isOn: playCompletionSound) { [weak self] on in
            self?.playCompletionSound = on
            UserDefaults.standard.set(on, forKey: "completionSound")
        })
        menu.addItem(toggleRow(title: "Permission sound", isOn: playPermissionSound) { [weak self] on in
            self?.playPermissionSound = on
            UserDefaults.standard.set(on, forKey: "permissionSound")
        })

        let animParent = NSMenuItem(title: "Animation Style", action: nil, keyEquivalent: "")
        let animSub = NSMenu()
        for style in AnimStyle.allCases {
            let it = NSMenuItem(title: style == .terminal ? "Terminal" : "Spinner", action: #selector(chooseStyle(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = style.rawValue
            it.state = animStyle == style ? .on : .off
            animSub.addItem(it)
        }
        animParent.submenu = animSub
        menu.addItem(animParent)

        let colorParent = NSMenuItem(title: "Color theme", action: nil, keyEquivalent: "")
        let colorSub = NSMenu()
        for (sys, name) in [(false, "Orange"), (true, "System")] {
            let it = NSMenuItem(title: name, action: #selector(chooseColor(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = sys
            it.state = iconSystem == sys ? .on : .off
            colorSub.addItem(it)
        }
        colorParent.submenu = colorSub
        menu.addItem(colorParent)

        let hideParent = NSMenuItem(title: "Hide idle sessions", action: nil, keyEquivalent: "")
        let hideSub = NSMenu()
        let curHide = stalePruneAge
        for (name, secs) in [("5 minutes", 300.0), ("15 minutes", 900.0), ("30 minutes", 1800.0), ("1 hour", 3600.0), ("Never", 0.0)] {
            let it = NSMenuItem(title: name, action: #selector(chooseHideIdle(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = secs
            it.state = curHide == secs ? .on : .off
            hideSub.addItem(it)
        }
        hideParent.submenu = hideSub
        menu.addItem(hideParent)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Version \(currentVersion)", action: nil, keyEquivalent: ""))
        if let latest = UserDefaults.standard.string(forKey: "latestVersion"), versionIsNewer(latest, than: currentVersion) {
            let up = NSMenuItem(title: "Update available", action: #selector(openLatestRelease), keyEquivalent: "")
            up.target = self
            menu.addItem(up)
        }
        let q = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)
    }

    func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    func toggleRow(title: String, isOn: Bool, onToggle: @escaping (Bool) -> Void) -> NSMenuItem {
        let width = CGFloat(uiConfig()["boxWidth"] ?? 300), height: CGFloat = 24, leftInset: CGFloat = 14, rightInset: CGFloat = 12
        let row = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        row.autoresizingMask = [.width]

        // Dim a trailing parenthetical (e.g. the "(1m+)" qualifier) so it reads as a secondary note.
        let labelFont = NSFont.menuFont(ofSize: 0)
        let attr = NSMutableAttributedString(string: title, attributes: [.font: labelFont, .foregroundColor: NSColor.labelColor])
        if let r = title.range(of: " (") {
            attr.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(r.lowerBound..<title.endIndex, in: title))
        }
        let label = NSTextField(labelWithAttributedString: attr)
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(x: leftInset, y: (height - label.frame.height) / 2))
        label.autoresizingMask = [.maxXMargin]
        row.addSubview(label)

        let toggle = ToggleView(isOn: isOn)
        toggle.onToggle = onToggle
        toggle.setFrameOrigin(NSPoint(x: width - toggle.frame.width - rightInset, y: (height - toggle.frame.height) / 2))
        toggle.autoresizingMask = [.minXMargin]
        row.addSubview(toggle)

        let item = NSMenuItem()
        item.view = row
        return item
    }

    func sessionMenuLine(_ s: Session) -> String {
        let now = Date().timeIntervalSince1970
        let eff = s.eff.isEmpty ? effectiveState(s, now: now) : s.eff  // cached by evaluate() each tick
        // The icon carries the state (spinner / amber dot / caret); the row text is just the project,
        // plus a live timer while working since the spinner can't convey elapsed.
        var line = truncated(sessionName(s))
        if eff == "thinking" || eff == "tool", s.startedAt > 0 {
            line += "  " + elapsed(max(0, Int(now - s.startedAt)))
        }
        return line
    }

    // Live layout knobs read fresh from ~/.config/opencode/statusbar/uiconfig.json each render, so numeric
    // tweaks (timer column, pill offset, gap) take effect on the next menu open with NO rebuild.
    func uiConfig() -> [String: Double] {
        let p = (configDir as NSString).appendingPathComponent("statusbar/uiconfig.json")
        guard let d = FileManager.default.contents(atPath: p),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return j.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    func configureSessionRow(_ v: SessionRowView, _ s: Session, eff: String) {
        let cfg = uiConfig()
        let now = Date().timeIntervalSince1970
        let nameMax = Int(cfg["nameMax"] ?? 16)
        let working = (eff == "thinking" || eff == "tool") && s.startedAt > 0
        let resting = !(eff == "permission" || eff == "thinking" || eff == "tool")  // the dim caret
        let tag = surfaceTag(s.entrypoint)
        v.configure(icon: sessionSymbol(s, eff: eff),
                    iconTint: resting ? .tertiaryLabelColor : .labelColor,  // caret dim; spinner matches the name font; amber image ignores tint
                    name: truncated(sessionName(s), max: nameMax, keep: nameMax),
                    timer: working ? elapsed(max(0, Int(now - s.startedAt))) : nil,
                    pillNormal: tag.isEmpty ? nil : pillImage(tag),
                    pillSelected: tag.isEmpty ? nil : pillImage(tag, selected: true),
                    pillInset: CGFloat(cfg["pillInset"] ?? 12),
                    timerGap: CGFloat(cfg["timerGap"] ?? 10))
    }

    func statusText(_ s: Session, eff: String) -> String {
        switch eff {
        case "permission":       return "Awaiting permission"
        case "thinking", "tool": return workingLabel(s)
        default:                 return s.state == "done" ? "Done" : "Idle"
        }
    }

    // Just the repo/cwd; the surface (CLI/APP) renders as a trailing badge instead of inline.
    func sessionName(_ s: Session) -> String {
        s.project.isEmpty ? "session" : s.project
    }

    // Terminal sessions show a CLI pill.
    func surfaceTag(_ entrypoint: String) -> String {
        return entrypoint.isEmpty ? "" : "CLI"
    }

    // CLI/APP pill rendered as an image so it can sit inside the row text (right after the timer)
    // rather than as a system badge pinned to the menu edge with a fixed, uncloseable gap.
    func pillImage(_ text: String, selected: Bool = false) -> NSImage {
        let t = text as NSString
        let font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold)  // mono -> 3 chars = uniform width
        let pad: CGFloat = 7, h: CGFloat = 15
        let cfg = uiConfig()
        let dy = CGFloat(cfg["pillTextY"] ?? -1)  // negative nudges the text down (it reads top-heavy)
        // Pill bg is a tunable gray per mode (black-on-light / white-on-dark at a low alpha) so light
        // mode can be lightened independently. On a selected (blue) row it's a light translucent pill.
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let bgAlpha = CGFloat(cfg[dark ? "pillBgDark" : "pillBgLight"] ?? (dark ? 0.14 : 0.10))
        let bg = selected ? NSColor.white.withAlphaComponent(0.22)
                          : (dark ? NSColor.white : NSColor.black).withAlphaComponent(bgAlpha)
        let fg = selected ? NSColor.white : NSColor.labelColor
        let w = ceil(t.size(withAttributes: [.font: font]).width) + pad * 2
        return NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            bg.setFill()
            NSBezierPath(roundedRect: rect, xRadius: h / 2, yRadius: h / 2).fill()
            let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
            let ts = t.size(withAttributes: a)
            t.draw(at: NSPoint(x: (rect.width - ts.width) / 2, y: (rect.height - ts.height) / 2 + dy), withAttributes: a)
            return true
        }
    }

    func sessionSymbol(_ s: Session, eff: String) -> NSImage? {
        switch eff {
        case "permission":       return symbolImage("exclamationmark.circle.fill", tint: amber)
        case "thinking", "tool": return rotatedSpinner(spinAngle)
        default:                 return restingCaret   // done/idle merged: dim "ready for input" caret
        }
    }

    // The shell-style prompt caret (U+276F), dimmed and centered in
    // a square that matches the spinner gutter so the resting rows align with the working ones.
    lazy var restingCaret: NSImage? = {
        let glyph = "\u{276F}" as NSString
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let side = spinnerBase?.size.width ?? 15
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            let g = glyph.size(withAttributes: attrs)
            glyph.draw(at: NSPoint(x: (side - g.width) / 2, y: (side - g.height) / 2), withAttributes: attrs)
            return true
        }
        img.isTemplate = true   // tint via contentTintColor: dim (tertiary) normally, white on hover
        return img
    }()

    // Pre-rendered into a padded SQUARE canvas with the glyph centered, so rotation pivots on the
    // visual center (an off-center pivot makes the spinner orbit/wobble instead of spinning in place).
    lazy var spinnerBase: NSImage? = {
        let name: String
        if #available(macOS 15.0, *) { name = "progress.indicator" } else { name = "rays" }
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        guard let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return nil }
        let side = ceil(max(sym.size.width, sym.size.height)) + 2
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            sym.draw(in: NSRect(x: (side - sym.size.width) / 2, y: (side - sym.size.height) / 2,
                                width: sym.size.width, height: sym.size.height))
            return true
        }
        img.isTemplate = true
        return img
    }()

    func rotatedSpinner(_ angleDeg: CGFloat) -> NSImage? {
        guard let base = spinnerBase else { return nil }
        let size = base.size
        let img = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.rotate(by: -angleDeg * .pi / 180)
            ctx.translateBy(x: -size.width / 2, y: -size.height / 2)
            base.draw(in: rect)
            return true
        }
        img.isTemplate = true
        return img
    }

    func symbolImage(_ name: String, tint: NSColor? = nil) -> NSImage? {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        if let tint = tint, #available(macOS 12.0, *) {
            return img.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tint]))
        }
        img.isTemplate = true
        return img
    }

    // Keep the bar narrow: over `max` chars, show the first `keep` + an ellipsis (full text stays in the tooltip).
    func truncated(_ s: String, max: Int = 20, keep: Int = 18) -> String {
        s.count > max ? String(s.prefix(keep)) + "…" : s
    }

    // Rank a session's EFFECTIVE state for surfacing (higher = more important), so a session
    // awaiting YOUR permission is never hidden behind one merely thinking. `eff` yields
    // permission / thinking / tool / done / idle (waiting is never emitted).
    func priority(of eff: String) -> Int {
        switch eff {
        case "permission":       return 2
        case "thinking", "tool": return 1
        default:                 return 0   // idle / unknown
        }
    }

    func workingLabel(_ s: Session) -> String {
        if !s.label.isEmpty { return s.label }
        return s.state == "tool" ? "Working…" : "Thinking…"
    }

    // "1m 1s" / "43s" — elapsed-clock style.
    func elapsed(_ secs: Int) -> String {
        let m = secs / 60, s = secs % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }

    @objc func quit() { NSApp.terminate(nil) }

    // Row click. Bring the terminal app to the front (zero permission). Targeting the exact
    // window/tab needs a one-time Automation grant, deferred to a future build.
    func openSession(_ id: String, termProgram: String) {
        // Map TERM_PROGRAM to a name `open -a` understands; most terminals match verbatim.
        let app: String
        switch termProgram {
        case "Apple_Terminal": app = "Terminal"
        case "iTerm.app":      app = "iTerm"
        case "vscode":         app = "Visual Studio Code"
        case "WarpTerminal":   app = "Warp"
        case "":               return  // unknown surface, nothing to focus
        default:               app = termProgram  // Ghostty, WezTerm, Tabby, Hyper, kitty, …
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", app]
        try? p.run()
    }


    @objc func chooseColor(_ sender: NSMenuItem) {
        guard let sys = sender.representedObject as? Bool else { return }
        iconSystem = sys
        UserDefaults.standard.set(iconSystem, forKey: "iconSystem")
        evaluate(prevStates: sessions.mapValues { $0.state }) // re-render the current state in the new color
    }

    @objc func chooseHideIdle(_ sender: NSMenuItem) {
        guard let secs = sender.representedObject as? Double else { return }
        UserDefaults.standard.set(secs, forKey: "hideIdleAfter")
    }

    @objc func chooseStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let st = AnimStyle(rawValue: raw) else { return }
        animStyle = st
        UserDefaults.standard.set(raw, forKey: "animStyle")
        animTimer?.invalidate(); animTimer = nil // recreate at the new style's fps
        frameIdx = 0
        evaluate(prevStates: sessions.mapValues { $0.state })
    }

    // MARK: state polling

    func tick() {
        // Snapshot raw states from the previous tick *before* reloading state files,
        // so evaluate() can detect transitions (e.g. thinking -> permission).
        let prevStates = sessions.mapValues { $0.state }
        checkLifecycle()
        reloadSessions()
        evaluate(prevStates: prevStates)
        if menuIsOpen { refreshOpenMenuRows() }
    }

    // The .json session files currently in state.d/ (ignores the .tmp files mid-write).
    func stateFileNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: stateDir)) ?? []).filter { $0.hasSuffix(".json") }
    }

    // Refresh `sessions` from state.d/, re-parsing only files whose mtime changed (writes are
    // atomic renames, so a content update bumps mtime and is never read torn).
    func reloadSessions() {
        let fm = FileManager.default
        let files = stateFileNames()
        let present = Set(files)
        for key in Array(fileMTimes.keys) where !present.contains(key) {
            fileMTimes[key] = nil
            fileSeqs[key] = nil
            sessions[(key as NSString).deletingPathExtension] = nil
        }
        for f in files {
            let full = (stateDir as NSString).appendingPathComponent(f)
            guard let data = fm.contents(atPath: full),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let seq = (o["seq"] as? NSNumber)?.intValue ?? 0
            // Prefer the plugin's monotonic seq counter; fall back to mtime for pre-upgrade files.
            if seq > 0 {
                if fileSeqs[f] == seq { continue }
                fileSeqs[f] = seq
            } else {
                guard let attrs = try? fm.attributesOfItem(atPath: full),
                      let m = attrs[.modificationDate] as? Date else { continue }
                if fileMTimes[f] == m { continue }
                fileMTimes[f] = m
            }
            let id = (f as NSString).deletingPathExtension
            sessions[id] = Session(json: o, id: id)
        }
    }

    func evaluate(prevStates: [String: String]) {
        let now = Date().timeIntervalSince1970
        var chime = false
        var permissionChime = false

        for id in Array(sessions.keys) {
            guard var s = sessions[id] else { continue }
            let prevState = prevStates[id] ?? ""
            s.eff = effectiveState(s, now: now)   // compute once per tick; the menu + tooltip reuse it
            // Reap on PROCESS death, not idle time: a session leaves only when its OpenCode process is
            // gone (closed/crashed terminal, quit app), so an idle-but-open session stays and the icon
            // holds. Pre-upgrade files have no pid (0) — fall back to the old idle+age prune so they
            // can't linger forever. This is also what keeps state.d self-cleaning (no growing cache).
            let dead = s.pid > 0 ? !pidAlive(s.pid)
                                 : (s.eff == "idle" && stalePruneAge > 0 && now - s.ts > stalePruneAge)
            if dead {
                try? FileManager.default.removeItem(atPath: (stateDir as NSString).appendingPathComponent(id + ".json"))
                sessions[id] = nil; fileMTimes[id + ".json"] = nil; fileSeqs[id + ".json"] = nil; soundPrev[id] = nil; turnStart[id] = nil
                continue
            }

            // Permission sound edge. If the user doesn't want the chime, they can toggle it off.
            if prevState != "permission" && s.state == "permission" {
                Logger.shared.log("permission edge detected session=\(id) playPermissionSound=\(playPermissionSound)")
                if playPermissionSound {
                    permissionChime = true
                }
            }

            sessions[id] = s
            if soundEdgeDone(s, now: now) { chime = true }
        }
        for id in Array(soundPrev.keys) where sessions[id] == nil { soundPrev[id] = nil; turnStart[id] = nil }
        if (chime && playCompletionSound) || permissionChime {
            let played = completionSound?.play() ?? false
            Logger.shared.log("playSound chime=\(chime) completionEnabled=\(playCompletionSound) permissionChime=\(permissionChime) played=\(played)")
        }

        // Surface the single highest-priority session (permission > working > …); ties broken by
        // recency, so within a tier the most recently active session wins.
        let lead = sessions.values.max { a, b in
            let pa = priority(of: a.eff), pb = priority(of: b.eff)
            return pa == pb ? a.ts < b.ts : pa < pb
        }
        statusItem.button?.toolTip = lead.map(sessionMenuLine)  // names repo + surface + state on hover

        guard let lead = lead else { renderResting(); return }
        switch lead.eff {
        case "permission":
            render(label: statusText(lead, eff: lead.eff), color: amber, animate: false, startedAt: 0, dot: true)
        case "thinking", "tool":
            render(label: statusText(lead, eff: lead.eff), color: iconColor, animate: true, startedAt: lead.startedAt)
        case "done":
            render(label: "Done", color: iconColor, animate: false, startedAt: 0)
        default:
            renderResting()
        }
    }

    func renderResting() { render(label: "", color: iconColor, animate: false, startedAt: 0) }

    // Per-session effective state with an absolute age cap. Event-based only: no transcript fallback.
    // "done" stays "done" so the menu bar can show "Done" instead of collapsing to an empty icon.
    func effectiveState(_ s: Session, now: Double) -> String {
        if s.state == "thinking" || s.state == "tool" || s.state == "permission" {
            let cap: Double = s.state == "permission" ? 7200 : 900
            if now - s.ts > cap { return "idle" }
            return s.state
        }
        return s.state == "done" ? "done" : s.state
    }

    // Detect a session's working->done edge for the chime. Updates the per-session bookkeeping
    // every call and returns true exactly once per edge.
    func soundEdgeDone(_ s: Session, now: Double) -> Bool {
        let prev = soundPrev[s.id] ?? ""
        if s.state == "thinking" || s.state == "tool", s.startedAt > 0 { turnStart[s.id] = s.startedAt }
        var edge = false
        if s.state == "done", prev != "done", let st = turnStart[s.id], st > 0 { edge = true }
        if s.state == "done" { turnStart[s.id] = 0 }
        soundPrev[s.id] = s.state
        return edge
    }

    // MARK: self-quit lifecycle

    func sessionCount() -> Int { stateFileNames().count }

    // Liveness probe: is this session's OpenCode process still alive? kill(pid,0) returns 0 if the
    // process exists; EPERM = exists but not ours (won't happen, same user); ESRCH = gone.
    func pidAlive(_ pid: Int32) -> Bool {
        if pid <= 0 { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    // Stay while a session is active. Auto-launches (from the plugin) quit after a short
    // debounced grace when no sessions remain. Manual launches stay alive indefinitely so
    // the user can open the app from Finder/Spotlight and keep it in the menu bar.
    func checkLifecycle() {
        let now = Date()
        let age = now.timeIntervalSince(launchedAt)
        let sessions = sessionCount()
        Logger.shared.log("checkLifecycle age=\(String(format: "%.1f", age)) sessions=\(sessions) autoLaunch=\(isAutoLaunch) hasSeenSessions=\(hasSeenSessions)")
        if age < launchGrace { return }
        if sessions > 0 {
            hasSeenSessions = true
            notNeededSince = nil
            return
        }
        if !isAutoLaunch {
            Logger.shared.log("manual launch, no sessions, staying alive")
            return
        }
        // Auto-launched from the plugin: give OpenCode time to emit its first event
        // and write a state file. Don't start the idle timer until we've seen at least
        // one session, or until the bootstrap timeout expires.
        if !hasSeenSessions, age < bootstrapTimeout {
            Logger.shared.log("auto-launch bootstrap grace, waiting for first session")
            return
        }
        if let since = notNeededSince {
            let idle = now.timeIntervalSince(since)
            Logger.shared.log("auto-launch idle for \(String(format: "%.1f", idle))s")
            if idle >= idleQuitDelay {
                Logger.shared.log("auto-launch quitting")
                NSApp.terminate(nil)
            }
        } else {
            Logger.shared.log("auto-launch no sessions, starting idle timer")
            notNeededSince = now
        }
    }

    // MARK: render

    func render(label: String, color: NSColor?, animate: Bool, startedAt: Double, dot: Bool = false) {
        Logger.shared.log("render label='\(label)' animate=\(animate) startedAt=\(startedAt) dot=\(dot)")
        guard let button = statusItem.button else { return }
        button.contentTintColor = nil // we paint the icon color ourselves; template-tint is unreliable
        activeBase = label
        activeColor = color
        self.startedAt = startedAt

        if animate {
            if animTimer == nil {
                let t = Timer(timeInterval: 1.0 / fps, repeats: true) { [weak self] _ in self?.animStep() }
                RunLoop.main.add(t, forMode: .common)
                animTimer = t
            }
        } else {
            animTimer?.invalidate(); animTimer = nil
            frameIdx = 0
            button.image = dot ? dotIcon(color: color) : restingIcon(color: color)
        }
        applyTitle()
        if button.image == nil { button.image = dot ? dotIcon(color: color) : restingIcon(color: color) }
    }

    func animStep() {
        frameIdx = (frameIdx + 1) % frameCount
        statusItem.button?.image = iconImage(color: activeColor, frame: frameIdx)
        applyTitle() // refresh the elapsed clock
    }

    func applyTitle() {
        guard let button = statusItem.button else { return }
        var text = activeBase
        if showTimer, startedAt > 0 {
            text += "  " + elapsed(max(0, Int(Date().timeIntervalSince1970 - startedAt)))
        }
        if text.isEmpty {
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            return
        }
        button.imagePosition = .imageLeading
        // labelColor adapts: white on a dark menu bar, black on a light one. Monospaced
        // digits keep the elapsed clock from nudging neighboring menu bar icons.
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .regular),
        ]
        button.attributedTitle = NSAttributedString(string: " \(text)", attributes: attrs)
    }

    // MARK: icon

    func iconImage(color: NSColor?, frame: Int) -> NSImage {
        let cfg = animConfig(for: animStyle)
        let gs = glyphs(for: animStyle)
        let ps = peaks(for: animStyle)
        let i = (frame / cfg.sub) % gs.count
        let local = cfg.sub > 1 ? (CGFloat(frame % cfg.sub) + 0.5) / CGFloat(cfg.sub) : 0.5 // 0…1 within this glyph
        // Scale envelope per glyph: rise, hold at peak, fall, so each lands before the swap.
        let env: CGFloat
        if local < 0.30 { let u = local / 0.30; env = u * u * (3 - 2 * u) }
        else if local > 0.70 { let u = (1 - local) / 0.30; env = u * u * (3 - 2 * u) }
        else { env = 1 }
        let scale = cfg.dip + (ps[i] - cfg.dip) * env
        // Terminal glyphs look best as an adaptive black/white template; colored fill makes them
        // look like noisy dots on a tinted menu bar.
        let drawColor = animStyle == .terminal ? nil : color
        return spinnerIcon(color: drawColor, glyph: i, scale: scale)
    }

    // nil color => adaptive template image (system draws it black/white per the menu bar).
    func spinnerIcon(color: NSColor?, glyph: Int, scale: CGFloat) -> NSImage {
        let s: CGFloat = 18
        guard let masks = glyphMasks[animStyle], glyph < masks.count else { return NSImage(size: NSSize(width: s, height: s)) }
        let mask = masks[glyph]
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            let dw = s * scale
            let r = NSRect(x: (s - dw) / 2, y: (s - dw) / 2, width: dw, height: dw)
            if let c = color {
                c.setFill(); r.fill()
                mask.draw(in: r, from: .zero, operation: .destinationIn, fraction: 1.0)
            } else {
                mask.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            return true
        }
        img.isTemplate = (color == nil)
        return img
    }

    // Rasterize a single glyph into a centered 60x60 alpha mask filling ~92%.
    static func glyphMask(_ g: String) -> NSImage {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 180), .foregroundColor: NSColor.black,
        ]
        let str = NSAttributedString(string: g, attributes: attrs)
        let sz = str.size()
        let big = NSImage(size: sz, flipped: false) { _ in str.draw(at: .zero); return true }
        guard let rep = big.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) else {
            return NSImage(size: NSSize(width: 60, height: 60))
        }
        let w = rep.pixelsWide, h = rep.pixelsHigh, data = rep.bitmapData!
        var minx = w, miny = h, maxx = -1, maxy = -1
        for y in 0..<h { for x in 0..<w where data[(y*w+x)*4+3] > 20 {
            minx = min(minx, x); maxx = max(maxx, x); miny = min(miny, y); maxy = max(maxy, y)
        }}
        guard maxx >= 0 else { return NSImage(size: NSSize(width: 60, height: 60)) }
        let bw = CGFloat(maxx - minx + 1), bh = CGFloat(maxy - miny + 1)
        let out: CGFloat = 60, fill = out * 0.92
        let scale = fill / max(bw, bh)
        let dw = bw * scale, dh = bh * scale
        // NSBitmapImageRep origin is top-left; convert the bbox to bottom-left for drawing.
        let srcRect = NSRect(x: CGFloat(minx), y: CGFloat(h - maxy - 1), width: bw, height: bh)
        return NSImage(size: NSSize(width: out, height: out), flipped: false) { _ in
            big.draw(in: NSRect(x: (out - dw)/2, y: (out - dh)/2, width: dw, height: dh),
                     from: srcRect, operation: .sourceOver, fraction: 1.0)
            return true
        }
    }

    // Same idea, but keep the glyph's natural cell center instead of cropping to its ink bbox.
    // This prevents terminal braille dots from jumping around as the glyph changes.
    static func centeredGlyphMask(_ g: String) -> NSImage {
        let fontSize: CGFloat = 72
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.black,
        ]
        let str = NSAttributedString(string: g, attributes: attrs)
        let sz = str.size()
        let out: CGFloat = 60
        return NSImage(size: NSSize(width: out, height: out), flipped: false) { _ in
            str.draw(at: NSPoint(x: (out - sz.width) / 2, y: (out - sz.height) / 2))
            return true
        }
    }

    func restingIcon(color: NSColor?) -> NSImage {
        return restingCaret ?? spinnerIcon(color: color, glyph: 0, scale: 1)
    }

    func dotIcon(color: NSColor?) -> NSImage {
        let s: CGFloat = 18, d: CGFloat = 9
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            (color ?? .systemYellow).setFill()
            NSBezierPath(ovalIn: NSRect(x: (s - d) / 2, y: (s - d) / 2, width: d, height: d)).fill()
            return true
        }
        img.isTemplate = (color == nil)
        return img
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = StatusController()
app.run()
