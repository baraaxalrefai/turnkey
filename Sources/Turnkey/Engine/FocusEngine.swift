import AppKit
import TurnkeyCore

/// Decides when to move focus. Rules:
///  • switch only after you've settled on a screen for `screenDwell` (300 ms)
///  • never while you type (until `typingQuiet` after your last key) or use the mouse (`mouseQuiet`)
///  • going back across an edge needs a slightly bigger turn (hysteresis)
///  • looks far from every screen (phone, desk, window) are ignored
///  • land in the window you look at, or the last one you used on that screen
final class FocusEngine {
    private let screens: ScreenRegistry
    private let windows: WindowService
    private let panes: PaneService
    private let input: InputMonitor
    let queue = DispatchQueue(label: "turnkey.engine", qos: .userInteractive)

    /// Called on the engine queue with the latest status (the app forwards it to the UI).
    var onStatus: ((LiveStatus) -> Void)?

    private let flagLock = NSLock()
    private var _active = false
    /// Focus is only ever moved while active (permissions granted, not paused, not calibrating).
    var active: Bool {
        get { flagLock.locked { _active } }
        set { flagLock.locked { _active = newValue } }
    }

    // Frame coalescing: if we're busy (an app is slow to answer), only the newest frame matters.
    private let pendingLock = NSLock()
    private var pending: TrackedFrame?
    private var scheduled = false

    // Engine-queue state
    private var screenDwell = Dwell<String>()
    private var windowDwell = Dwell<CGWindowID>()
    private var paneDwell = Dwell<String>()
    private var focused: FocusedWindow?
    private var focusedCheckedAt = -100.0
    private var lastTarget: String?
    private var lastWindowOnScreen: [String: CGWindowID] = [:]
    private var pointerMemory: [String: CGPoint] = [:]
    private var lastActionAt = -100.0
    private var lastPaneProbeAt = -100.0
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// After every switch we check it actually stuck; an app that refuses focus is left alone for a
    /// few seconds instead of being retried in a loop.
    private enum Attempt: Equatable {
        case screen(String)
        case window(CGWindowID)
    }
    private var pendingCheck: (attempt: Attempt, time: Double)?
    private var blocked: (attempt: Attempt, until: Double)?
    /// Where focus was before the last gaze switch (for the quick "look back" return).
    private var returnTo: Attempt?
    private var returnPanePoint: CGPoint?

    /// Keys within this long after you settle on a new target count as "turn and type", not reading.
    static let turnAndTypeGrace = 0.6
    /// Never switch within this long of a keystroke (don't split a burst of keys).
    static let keyBurstGap = 0.25
    /// Settle time when looking straight back to where focus just was, without having typed.
    static let returnDwell = 0.15
    /// How far inside a window/pane the gaze must be, as a fraction of the expected error.
    static let marginFactor: CGFloat = 0.45

    init(screens: ScreenRegistry, windows: WindowService, panes: PaneService, input: InputMonitor) {
        self.screens = screens
        self.windows = windows
        self.panes = panes
        self.input = input
    }

    func submit(_ frame: TrackedFrame) {
        let needsSchedule: Bool = pendingLock.locked {
            pending = frame
            if scheduled { return false }
            scheduled = true
            return true
        }
        guard needsSchedule else { return }
        queue.async { [weak self] in self?.drain() }
    }

    private func drain() {
        let frame: TrackedFrame? = pendingLock.locked {
            let f = pending
            pending = nil
            scheduled = false
            return f
        }
        if let frame { step(frame) }
    }

    /// Forget dwell timers (e.g. after pausing).
    func reset() {
        queue.async { [weak self] in
            self?.screenDwell.reset()
            self?.windowDwell.reset()
            self?.paneDwell.reset()
            self?.focusedCheckedAt = -100
        }
    }

    // MARK: - Main step

    private func step(_ frame: TrackedFrame) {
        let now = frame.time
        let cfg = ConfigBox.shared.config
        let screenList = screens.screens
        var status = LiveStatus()
        status.faceFound = frame.faceFound
        if let f = frame.features {
            status.yawDeg = f.yaw * 180 / .pi
            status.pitchDeg = f.pitch * 180 / .pi
        }

        guard frame.faceFound else {
            status.state = .noFace
            clearDwells()
            onStatus?(status)
            return
        }
        guard let est = frame.estimate else {
            status.state = .needsCalibration
            onStatus?(status)
            return
        }
        let connected = Set(screenList.map(\.id))
        let available = est.logits.keys.filter { connected.contains($0) && est.uv[$0] != nil }
        guard !available.isEmpty else {
            status.state = .needsCalibration
            onStatus?(status)
            return
        }

        refreshFocused(now: now, screenList: screenList)
        let pointer = windows.pointerLocation()
        let focusedScreen = focused.flatMap { f -> String? in
            f.frame.isNull ? nil : ScreenRegistry.screen(for: f.frame, in: screenList)?.id
        } ?? pointer.flatMap { ScreenRegistry.screen(containing: $0, in: screenList)?.id }
        verifyLastAttempt(now: now, focusedScreen: focusedScreen)

        // Which screen are you facing? Leaving the focused screen needs a margin (hysteresis).
        func score(_ id: String) -> Double { (est.logits[id] ?? -1e9) + (cfg.screenBias[id] ?? 0) }
        let best = available.max { score($0) < score($1) }!
        var target = best
        if let ref = focusedScreen ?? lastTarget, available.contains(ref), ref != best,
           score(best) - score(ref) < cfg.hysteresis {
            target = ref
        }
        lastTarget = target

        guard let geom = screenList.first(where: { $0.id == target }), let uv = est.uv[target] else { return }
        let m = cfg.awayMargin
        let away = uv.u < -m || uv.u > 1 + m || uv.v < -m || uv.v > 1 + m
        let gaze = CGPoint(x: geom.frame.minX + min(max(uv.u, 0.001), 0.999) * geom.frame.width,
                           y: geom.frame.minY + min(max(uv.v, 0.001), 0.999) * geom.frame.height)
        let sigma = sigmaPoints(target, geom: geom)

        status.state = away ? .away : .tracking
        status.facingID = away ? nil : target
        status.facingName = away ? nil : geom.name
        status.gazePoint = away ? nil : gaze
        status.sigma = sigma

        guard !away, active else {
            if away { clearDwells() }
            onStatus?(status)
            return
        }

        let typingIdle = input.typingIdle(now: now)
        let lastKeyAt = now - typingIdle
        let mouseBusy = input.mouseIdle(now: now) < cfg.mouseQuiet
        let modifiers = input.modifiersHeld()
        let gapOK = now - lastActionAt > 0.35
        // Nothing typed since focus last moved: looking straight back undoes a quick look almost instantly.
        let untouchedSinceAction = lastKeyAt < lastActionAt && now - lastActionAt < 6

        /// Typing rule. Typing while already looking at the new target means you're reading while you
        /// type (e.g. copying from it): wait until you pause for `typingQuiet`. If you stopped typing and
        /// then looked over, only avoid cutting into a burst of keys.
        func typingAllows(since dwellStart: Double) -> Bool {
            if lastKeyAt > dwellStart + Self.turnAndTypeGrace { return typingIdle >= cfg.typingQuiet }
            return typingIdle >= Self.keyBurstGap
        }
        func ready(held: Double, needed: Double, dwellStart: Double) -> Bool {
            guard held >= needed else { return false }
            if modifiers { status.waiting = "a modifier key is held"; return false }
            if mouseBusy { status.waiting = "you're using the mouse"; return false }
            if !typingAllows(since: dwellStart) { status.waiting = "you're typing"; return false }
            return gapOK
        }
        defer { onStatus?(status) }

        // 1) Another screen.
        if focusedScreen != target {
            let held = screenDwell.update(target, now: now)
            windowDwell.reset()
            paneDwell.reset()
            if ready(held: held, needed: cfg.screenDwell, dwellStart: screenDwell.since), !isBlocked(.screen(target), now: now) {
                let from = focusedScreen
                if switchScreen(to: geom, gaze: gaze, sigma: sigma, cfg: cfg, pointer: pointer,
                                screenList: screenList, now: now) {
                    returnTo = from.map { .screen($0) }
                    returnPanePoint = nil
                }
            }
            return
        }
        screenDwell.update(target, now: now)

        // 2) Another window on the same screen.
        // You're using Turnkey's own window, or looking at it: leave focus alone.
        guard cfg.switchWindows, let f = focused, f.pid != ownPID else {
            windowDwell.reset()
            paneDwell.reset()
            return
        }
        let mx = sigma.width * Self.marginFactor, my = sigma.height * Self.marginFactor
        let list = windows.windows(maxAge: 0.15)
        let top = list.first(where: { $0.frame.contains(gaze) })
        if top?.isOwn == true {
            windowDwell.reset()
            paneDwell.reset()
            return
        }
        if let w = top, w.id != f.windowID, f.windowID != 0 {
            if w.frame.contains(gaze, marginX: mx, marginY: my) {
                let held = windowDwell.update(w.id, now: now)
                paneDwell.reset()
                let needed = untouchedSinceAction && returnTo == .window(w.id) ? Self.returnDwell : cfg.windowDwell
                if ready(held: held, needed: needed, dwellStart: windowDwell.since), !isBlocked(.window(w.id), now: now) {
                    let from = f.windowID
                    focusWindow(w, reason: "you looked at it", now: now)
                    returnTo = .window(from)
                    returnPanePoint = nil
                }
            } else {
                windowDwell.reset()
            }
            return
        }
        windowDwell.reset()

        // 3) Another split pane of the focused window (terminals and code editors only).
        guard cfg.switchPanes, let w = top, w.id == f.windowID,
              PaneService.isSupported(f.bundleID, electron: cfg.electronPanes) else {
            paneDwell.reset()
            return
        }
        // Don't query the app in the middle of a burst of keys; the dwell keeps running meanwhile.
        guard typingIdle >= Self.keyBurstGap, now - lastPaneProbeAt >= 0.15 else { return }
        lastPaneProbeAt = now
        switch panes.probe(at: gaze, pid: f.pid, bundleID: f.bundleID) {
        case .target(let t) where t.frame.contains(gaze, marginX: mx, marginY: my):
            let held = paneDwell.update(t.key, now: now)
            let isReturn = untouchedSinceAction && (returnPanePoint.map { t.frame.contains($0) } ?? false)
            if ready(held: held, needed: isReturn ? Self.returnDwell : cfg.windowDwell, dwellStart: paneDwell.since) {
                let previous = panes.focusedPoint(pid: f.pid)
                let how = panes.focus(t, pid: f.pid, windowID: f.windowID, bundleID: f.bundleID,
                                      allowClick: cfg.paneClickFallback)
                lastActionAt = now
                paneDwell.reset()
                panes.invalidateCache()
                if how != nil {
                    returnPanePoint = previous
                    returnTo = nil
                }
                Diagnostics.shared.add(how.map { "Pane → \(f.appName) via \($0)\(isReturn ? " (back)" : "")" }
                                       ?? "Pane → \(f.appName) refused focus (click fallback \(cfg.paneClickFallback ? "unavailable" : "off"))")
            }
        default:
            paneDwell.reset()
        }
    }

    // MARK: - Actions

    @discardableResult
    private func switchScreen(to s: ScreenGeom, gaze: CGPoint, sigma: CGSize, cfg: EngineConfig,
                              pointer: CGPoint?, screenList: [ScreenGeom], now: Double) -> Bool {
        let all = windows.windows(maxAge: 0)
        let list = all.filter { !$0.isOwn }
        let onScreen = list.filter { ScreenRegistry.screen(for: $0.frame, in: screenList)?.id == s.id }
        var chosen: WindowInfo?
        var how = ""
        if cfg.switchWindows,
           let w = all.first(where: { $0.frame.contains(gaze) }), !w.isOwn,
           onScreen.contains(w),
           w.frame.contains(gaze, marginX: sigma.width * Self.marginFactor, marginY: sigma.height * Self.marginFactor) {
            chosen = w
            how = "window you looked at"
        }
        if chosen == nil, let last = lastWindowOnScreen[s.id], let w = onScreen.first(where: { $0.id == last }) {
            chosen = w
            how = "last used there"
        }
        if chosen == nil, let w = onScreen.first {
            chosen = w
            how = "frontmost there"
        }
        // Empty screen and the pointer is already there (or stays put): nothing to do for a while.
        if chosen == nil, !cfg.movePointer || pointer.map({ s.frame.contains($0) }) ?? true {
            blocked = (.screen(s.id), now + 3)
            screenDwell.reset()
            return false
        }

        if let w = chosen {
            windows.focus(w)
            lastWindowOnScreen[s.id] = w.id
            focused = FocusedWindow(pid: w.pid, windowID: w.id, frame: w.frame,
                                    bundleID: windows.appMeta(w.pid).bundleID, appName: w.appName)
            focusedCheckedAt = now
        }

        // Move the pointer too, so new windows, Spaces and Mission Control follow you.
        if cfg.movePointer, let pointer, !s.frame.contains(pointer) {
            if let from = ScreenRegistry.screen(containing: pointer, in: screenList) {
                pointerMemory[from.id] = pointer
            }
            var dest = pointerMemory[s.id].flatMap { s.frame.contains($0) ? $0 : nil }
                ?? chosen?.frame.center
                ?? s.frame.center
            if !s.frame.contains(dest) { dest = s.frame.center }
            input.noteSynthetic()
            windows.warpPointer(to: dest)
        }

        lastActionAt = now
        pendingCheck = (.screen(s.id), now)
        screenDwell.reset()
        windowDwell.reset()
        paneDwell.reset()
        panes.invalidateCache()
        Diagnostics.shared.add("Screen → \(s.name): \(chosen.map { "\($0.appName) (\(how))" } ?? "no windows there, pointer only")")
        return true
    }

    private func focusWindow(_ w: WindowInfo, reason: String, now: Double) {
        windows.focus(w)
        focused = FocusedWindow(pid: w.pid, windowID: w.id, frame: w.frame,
                                bundleID: windows.appMeta(w.pid).bundleID, appName: w.appName)
        focusedCheckedAt = now
        if let sid = ScreenRegistry.screen(for: w.frame, in: screens.screens)?.id {
            lastWindowOnScreen[sid] = w.id
        }
        lastActionAt = now
        pendingCheck = (.window(w.id), now)
        windowDwell.reset()
        paneDwell.reset()
        panes.invalidateCache()
        Diagnostics.shared.add("Window → \(w.appName) (\(reason))")
    }

    // MARK: - Helpers

    private func verifyLastAttempt(now: Double, focusedScreen: String?) {
        guard let check = pendingCheck, now - check.time > 0.6, active else { return }
        pendingCheck = nil
        let stuck: Bool
        switch check.attempt {
        case .screen(let id): stuck = focusedScreen == id
        case .window(let wid): stuck = focused?.windowID == wid
        }
        if !stuck {
            blocked = (check.attempt, now + 3)
            Diagnostics.shared.add("Focus didn't stick (\(check.attempt)); not retrying for 3 s")
        }
    }

    private func isBlocked(_ a: Attempt, now: Double) -> Bool {
        guard let b = blocked else { return false }
        if now >= b.until {
            blocked = nil
            return false
        }
        return b.attempt == a
    }

    private func refreshFocused(now: Double, screenList: [ScreenGeom]) {
        guard now - focusedCheckedAt > 0.15 else { return }
        focusedCheckedAt = now
        guard active else { return }
        let f = windows.focusedWindow()
        if let f, f.windowID != 0, !f.frame.isNull,
           let sid = ScreenRegistry.screen(for: f.frame, in: screenList)?.id {
            lastWindowOnScreen[sid] = f.windowID
        }
        focused = f
    }

    private func sigmaPoints(_ id: String, geom: ScreenGeom) -> CGSize {
        // Filled in by the app from the trained model (fraction of screen → points).
        let s = sigmaProvider?(id) ?? (0.12, 0.12)
        return CGSize(width: s.0 * geom.frame.width, height: s.1 * geom.frame.height)
    }

    /// Expected error per screen as fractions (u, v); supplied by the app.
    var sigmaProvider: ((String) -> (Double, Double)?)?

    private func clearDwells() {
        screenDwell.reset()
        windowDwell.reset()
        paneDwell.reset()
    }
}
