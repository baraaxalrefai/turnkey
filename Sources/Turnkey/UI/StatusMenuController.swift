import AppKit

/// The eye icon in the menu bar.
final class StatusMenuController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private weak var app: AppDelegate?

    private let facingItem = NSMenuItem(title: "Facing: —", action: nil, keyEquivalent: "")
    private let headItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let warningItem = NSMenuItem(title: "", action: #selector(warningClicked), keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "g")
    private let calibrateItem = NSMenuItem(title: "Calibrate Screens…", action: #selector(calibrate), keyEquivalent: "")
    private let dotItem = NSMenuItem(title: "Show Gaze Dot", action: #selector(toggleDot), keyEquivalent: "")
    private let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
    private let setupItem = NSMenuItem(title: "Setup Guide…", action: #selector(openSetup), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "Quit Turnkey", action: #selector(quit), keyEquivalent: "q")

    private var liveTimer: Timer?
    private var symbol = ""

    init(app: AppDelegate) {
        self.app = app
        super.init()
        pauseItem.keyEquivalentModifierMask = [.control, .option, .command]
        for item in [warningItem, pauseItem, calibrateItem, dotItem, settingsItem, setupItem, quitItem] {
            item.target = self
        }
        facingItem.isEnabled = false
        headItem.isEnabled = false
        menu.autoenablesItems = false
        menu.addItem(facingItem)
        menu.addItem(headItem)
        menu.addItem(warningItem)
        menu.addItem(.separator())
        menu.addItem(pauseItem)
        menu.addItem(calibrateItem)
        menu.addItem(dotItem)
        menu.addItem(.separator())
        menu.addItem(settingsItem)
        menu.addItem(setupItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.toolTip = "Turnkey"
        refresh()
    }

    // MARK: Updating

    func refresh() {
        updateIcon()
        guard let app else { return }
        let state = app.state
        pauseItem.title = state.userPaused ? "Resume" : "Pause"
        dotItem.state = app.settings.showGazeDot ? .on : .off
        calibrateItem.isEnabled = !state.calibrating
        if let w = warningText() {
            warningItem.title = w
            warningItem.isHidden = false
        } else {
            warningItem.isHidden = true
        }
        updateLive()
    }

    private func warningText() -> String? {
        guard let app else { return nil }
        let s = app.state
        if !s.cameraAuthorized { return "⚠︎ Camera access needed — Open Setup…" }
        if !s.axTrusted { return "⚠︎ Accessibility permission needed — Open Setup…" }
        if !s.hasModel { return "⚠︎ Not calibrated yet — Calibrate…" }
        if let d = s.driftWarning { return "⚠︎ Focus keeps missing on \(d) — Recalibrate…" }
        if let first = s.uncalibratedScreens.first { return "⚠︎ \(first) isn't calibrated — Calibrate…" }
        if let e = s.cameraError { return "⚠︎ \(e)" }
        return nil
    }

    func updateLive() {
        guard let app else { return }
        let s = app.state
        let live = s.live
        let text: String
        if s.userPaused {
            text = "Paused"
        } else if s.systemPaused {
            text = "Paused while locked or asleep"
        } else {
            switch live.state {
            case .tracking: text = "Facing: \(live.facingName ?? "—")" + (live.waiting.map { " — waiting, \($0)" } ?? "")
            case .away: text = "Facing: away from the screens"
            case .noFace: text = "Can't see your face"
            case .needsCalibration: text = "Needs calibration"
            case .noCamera: text = "Camera unavailable"
            case .off, .paused, .sleeping: text = "Off"
            }
        }
        facingItem.title = text
        if live.faceFound, !s.userPaused {
            headItem.title = String(format: "Head: yaw %.1f° · pitch %.1f°", live.yawDeg, live.pitchDeg)
            headItem.isHidden = false
        } else {
            headItem.isHidden = true
        }
    }

    private func updateIcon() {
        guard let app else { return }
        let s = app.state
        let name: String
        if s.userPaused || s.systemPaused {
            name = "eye.slash"
        } else if warningText() != nil {
            name = "eye.trianglebadge.exclamationmark"
        } else {
            name = "eye"
        }
        guard name != symbol, let button = statusItem.button else { return }
        symbol = name
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Turnkey")
        image?.isTemplate = true
        button.image = image
    }

    fileprivate func startLiveUpdates() {
        refresh()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.updateLive() }
        RunLoop.main.add(t, forMode: .common)
        liveTimer = t
    }

    fileprivate func stopLiveUpdates() {
        liveTimer?.invalidate()
        liveTimer = nil
    }

    // MARK: Actions

    @objc private func warningClicked() {
        guard let app else { return }
        let s = app.state
        if !s.cameraAuthorized || !s.axTrusted {
            app.showOnboarding()
        } else {
            app.startCalibration(screenIDs: nil)
        }
    }

    @objc private func togglePause() { app?.togglePause() }
    @objc private func calibrate() { app?.startCalibration(screenIDs: nil) }
    @objc private func toggleDot() { app?.settings.showGazeDot.toggle() }
    @objc private func openSettings() { app?.showSettings() }
    @objc private func openSetup() { app?.showOnboarding() }
    @objc private func quit() { NSApp.terminate(nil) }
}

extension StatusMenuController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) { startLiveUpdates() }
    func menuDidClose(_ menu: NSMenu) { stopLiveUpdates() }
}
