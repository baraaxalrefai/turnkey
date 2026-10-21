import AppKit
import AVFoundation
import TurnkeyCore
import SwiftUI

/// Wires everything together. Threads:
///  camera frames → (frame queue) Vision + pipeline → (engine queue) focus decisions → (main) UI.
final class AppDelegate: NSObject {
    let settings = AppSettings.shared
    let state = AppState.shared
    let screens = ScreenRegistry()
    let models = ModelStore()
    let input = InputMonitor()
    let windows = WindowService()
    let camera = CameraService()
    let power = PowerMonitor()
    let hotkey = HotkeyManager()
    let notifier = Notifier()
    let overlay = GazeOverlayController()
    lazy var panes = PaneService(windows: windows)
    lazy var pipeline = TrackingPipeline(models: models)
    lazy var engine = FocusEngine(screens: screens, windows: windows, panes: panes, input: input)

    private var menu: StatusMenuController?
    private var calibration: CalibrationController?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var pollTimer: Timer?

    private var cameraWanted = false
    private var cameraDevice: String?
    private var cameraRetryAfter = 0.0
    private var hotkeyRegistered = false
    private var loginApplied: Bool?

    private let flagLock = NSLock()
    private var _calibrating = false
    private var calibratingFlag: Bool {
        get { flagLock.locked { _calibrating } }
        set { flagLock.locked { _calibrating = newValue } }
    }

    // MARK: - Startup

    fileprivate func launch() {
        AX.configureTimeout()
        state.privateFocusAPI = PrivateAPI.canFocusWindows
        screens.refresh()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.windows.forgetApp(app.processIdentifier)
            }
        }

        models.onModelChanged = { [weak self] model, _ in self?.modelChanged(model) }
        models.onDrift = { [weak self] id in self?.driftDetected(id) }

        camera.onResult = { [weak self] result, time in self?.pipeline.process(result, time: time) }
        camera.onStatus = { [weak self] running, name, error in self?.cameraStatusChanged(running, name, error) }
        pipeline.onFrame = { [weak self] frame in self?.engine.submit(frame) }
        pipeline.onRaw = { [weak self] features, time in
            guard let self, self.calibratingFlag else { return }
            DispatchQueue.main.async { self.calibration?.receive(features, time: time) }
        }
        pipeline.onPreview = { [weak self] points in
            DispatchQueue.main.async { self?.state.landmarks = points }
        }
        engine.onStatus = { [weak self] status in
            DispatchQueue.main.async { self?.liveStatus(status) }
        }
        engine.sigmaProvider = { [weak self] id in
            guard let r = self?.models.model?.regressors[id] else { return nil }
            return (r.sigmaU, r.sigmaV)
        }
        windows.onSyntheticInput = { [weak self] in self?.input.noteSynthetic() }

        input.onClick = { [weak self] point, time in self?.handleClick(at: point, time: time) }
        input.start()
        power.onChange = { [weak self] in self?.updateRunState() }
        power.start()
        hotkey.onPress = { [weak self] in self?.togglePause() }
        notifier.onRecalibrate = { [weak self] in self?.startCalibration(screenIDs: nil) }
        notifier.setup()
        settings.onChange = { [weak self] in self?.applySettings() }

        menu = StatusMenuController(app: self)
        models.load()
        pollPermissions()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.pollPermissions()
        }
        applySettings()
        updateScreenRows()

        if !settings.onboardingDone || !state.cameraAuthorized || !state.axTrusted {
            showOnboarding()
        }
        updateRunState()
        Diagnostics.shared.add("Turnkey started — \(screens.screens.map(\.name).joined(separator: ", ")); window focus via \(PrivateAPI.canFocusWindows ? "SkyLight" : "Accessibility")")
    }

    // MARK: - Run state

    /// Decides whether the camera runs and whether focus may be moved.
    func updateRunState() {
        let sysPaused = power.isSystemPaused
        if state.systemPaused != sysPaused { state.systemPaused = sysPaused }
        let calibrating = calibration != nil
        let preview = (settingsWindow?.isVisible ?? false) || (onboardingWindow?.isVisible ?? false)
        let want = state.cameraAuthorized && !sysPaused &&
            (calibrating || (!state.userPaused && (state.hasModel || preview)))
        let device = settings.cameraID

        if want != cameraWanted || (want && device != cameraDevice) {
            if want, !cameraWanted, uptime() < cameraRetryAfter {
                // A recent start failed; try again a bit later.
            } else {
                cameraWanted = want
                cameraDevice = device
                if want {
                    camera.start(deviceID: device)
                } else {
                    camera.stop()
                    pipeline.reset()
                    var idle = LiveStatus()
                    idle.state = state.userPaused ? .paused : (sysPaused ? .sleeping : .off)
                    state.live = idle
                    state.landmarks = []
                }
            }
        }
        camera.wantsLandmarks = preview
        let fine = settings.config.switchWindows || settings.config.switchPanes
        camera.fps = fine || calibrating ? 15 : 10
        let active = cameraWanted && !calibrating && !state.userPaused && state.axTrusted && state.hasModel
        if engine.active != active {
            engine.active = active
            engine.reset()
        }
        overlay.setVisible(settings.showGazeDot && cameraWanted && !calibrating, screens: screens.screens)
        menu?.refresh()
    }

    private func pollPermissions() {
        let cam = Permissions.cameraStatus
        let camOK = cam == .authorized
        if state.cameraAuthorized != camOK { state.cameraAuthorized = camOK }
        let denied = cam == .denied || cam == .restricted
        if state.cameraDenied != denied { state.cameraDenied = denied }
        let ax = AXIsProcessTrusted()
        if ax != state.axTrusted {
            state.axTrusted = ax
            if ax { input.start() } // key-press timing needs this permission
            Diagnostics.shared.add("Accessibility permission: \(ax ? "granted" : "missing")")
        }
        let frames = camera.framesAnalysed
        if state.framesAnalysed != frames { state.framesAnalysed = frames }
        updateRunState()
    }

    private func applySettings() {
        if settings.hotkeyEnabled != hotkeyRegistered {
            hotkeyRegistered = settings.hotkeyEnabled
            if hotkeyRegistered { hotkey.register() } else { hotkey.unregister() }
        }
        if loginApplied != settings.launchAtLogin {
            loginApplied = settings.launchAtLogin
            LoginItem.set(settings.launchAtLogin)
        }
        updateRunState()
    }

    // MARK: - Events

    private func liveStatus(_ status: LiveStatus) {
        guard cameraWanted else { return }
        state.live = status
        overlay.update(status)
        calibration?.updateLive(status)
        menu?.refresh()
    }

    private func cameraStatusChanged(_ running: Bool, _ name: String?, _ error: String?) {
        if let name { state.cameraName = name }
        state.cameraError = error
        if let error, cameraWanted {
            Diagnostics.shared.add("Camera problem: \(error) — retrying in 10 s")
            cameraWanted = false
            cameraRetryAfter = uptime() + 10
        }
        menu?.refresh()
    }

    private func modelChanged(_ model: GazeModel?) {
        state.hasModel = model != nil
        updateScreenRows()
        updateRunState()
    }

    private func driftDetected(_ id: String) {
        let name = screens.screens.first { $0.id == id }?.name ?? models.screenMeta[id]?.name ?? "a screen"
        state.driftWarning = name
        notifier.notifyDrift(screenName: name)
        menu?.refresh()
    }

    private func screensChanged() {
        screens.refresh()
        overlay.rebuild(screens: screens.screens)
        updateScreenRows()
        updateRunState()
        Diagnostics.shared.add("Screens changed: \(screens.screens.map(\.name).joined(separator: ", "))")
    }

    /// You look where you click: feed the click (with your pose just before it) to the learner.
    private func handleClick(at point: CGPoint, time: Double) {
        guard cameraWanted, calibration == nil, !state.userPaused, state.hasModel,
              let s = screens.screen(containing: point) else { return }
        let learn = settings.config.learnFromClicks
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, let f = self.pipeline.averageFeatures(from: time - 0.45, to: time - 0.05) else { return }
            let u = Double((point.x - s.frame.minX) / s.frame.width)
            let v = Double((point.y - s.frame.minY) / s.frame.height)
            self.models.recordClick(features: f, screen: s.id, u: u, v: v, learn: learn)
        }
    }

    // MARK: - Screens list for Settings

    func updateScreenRows() {
        let connected = screens.screens
        let meta = models.screenMeta
        let report = models.report
        var rows: [ScreenRow] = connected.map { s in
            let r = report?.screen(s.id)
            return ScreenRow(id: s.id, name: s.name, connected: true, calibrated: r != nil,
                             samples: r?.samples ?? 0, clickSamples: r?.clickSamples ?? 0,
                             accuracy: r.map { accuracyText($0, mm: s.sizeMM) } ?? "",
                             calibratedAt: meta[s.id].map { Date(timeIntervalSince1970: $0.calibratedAt) })
        }
        for (id, m) in meta.sorted(by: { $0.key < $1.key }) where !connected.contains(where: { $0.id == id }) {
            let r = report?.screen(id)
            rows.append(ScreenRow(id: id, name: m.name, connected: false, calibrated: true,
                                  samples: r?.samples ?? 0, clickSamples: r?.clickSamples ?? 0,
                                  accuracy: r.map { String(format: "±%.0f%% × ±%.0f%%", $0.sigmaU * 100, $0.sigmaV * 100) } ?? "",
                                  calibratedAt: Date(timeIntervalSince1970: m.calibratedAt)))
        }
        state.screenRows = rows
        state.uncalibratedScreens = state.hasModel ? connected.filter { report?.screen($0.id) == nil }.map(\.name) : []
    }

    private func accuracyText(_ r: ScreenReport, mm: CGSize) -> String {
        if mm.width > 0 {
            return String(format: "±%.1f × ±%.1f cm", r.sigmaU * mm.width / 10, r.sigmaV * mm.height / 10)
        }
        return String(format: "±%.0f%% × ±%.0f%%", r.sigmaU * 100, r.sigmaV * 100)
    }

    // MARK: - Actions (menu, settings, onboarding)

    func togglePause() {
        state.userPaused.toggle()
        Diagnostics.shared.add(state.userPaused ? "Paused" : "Resumed")
        updateRunState()
    }

    func startCalibration(screenIDs: [String]?) {
        guard calibration == nil else { return }
        guard state.cameraAuthorized else {
            showOnboarding()
            return
        }
        screens.refresh()
        let all = screens.screens
        let targets = screenIDs.map { ids in all.filter { ids.contains($0.id) } } ?? all
        guard !targets.isEmpty else { return }
        let c = CalibrationController(targets: targets, allScreens: all, models: models)
        c.onFinish = { [weak self] saved in
            guard let self else { return }
            self.calibration = nil
            self.calibratingFlag = false
            self.state.calibrating = false
            if saved {
                self.state.driftWarning = nil
                Diagnostics.shared.add("Calibration saved for \(targets.map(\.name).joined(separator: ", "))")
            } else {
                Diagnostics.shared.add("Calibration cancelled")
            }
            self.updateScreenRows()
            self.updateRunState()
        }
        calibration = c
        calibratingFlag = true
        state.calibrating = true
        updateRunState()
        c.begin()
    }

    func requestCamera() {
        Permissions.requestCamera { [weak self] _ in self?.pollPermissions() }
    }

    func resetLearned() {
        models.resetLearned()
    }

    func deleteAllData() {
        models.deleteAll()
        state.driftWarning = nil
        updateScreenRows()
    }

    func forgetScreen(_ id: String) {
        models.forgetScreen(id)
        var c = settings.config
        c.screenBias[id] = nil
        settings.config = c
    }

    func finishOnboarding() {
        settings.onboardingDone = true
        onboardingWindow?.close()
    }

    func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(app: self, settings: settings, state: state)
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "Turnkey"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateRunState()
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(app: self, state: state, settings: settings)
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "Set up Turnkey"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            onboardingWindow = w
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateRunState()
    }
}

extension AppDelegate: NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        launch()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        camera.stop()
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Re-evaluate once the window is actually gone (the face preview may no longer need the camera).
        DispatchQueue.main.async { [weak self] in self?.updateRunState() }
    }
}
