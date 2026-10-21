import AppKit
import AVFoundation
import TurnkeyCore
import os

// MARK: - Small helpers

extension NSLock {
    @discardableResult
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// Monotonic seconds (same clock everywhere in the app).
func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// True if `p` is inside with at least `mx`/`my` to spare on each side.
    func contains(_ p: CGPoint, marginX mx: CGFloat, marginY my: CGFloat) -> Bool {
        p.x >= minX + mx && p.x <= maxX - mx && p.y >= minY + my && p.y <= maxY - my
    }
}

// MARK: - Settings

/// Everything the focus engine needs; read from background threads through `ConfigBox`.
struct EngineConfig: Codable, Equatable {
    /// Seconds you must keep facing another screen before focus moves.
    var screenDwell: Double = 0.30
    /// Seconds for windows and split panes on the same screen (they need more certainty).
    var windowDwell: Double = 0.50
    /// If you keep typing while looking at another screen/window/pane (reading or copying from it),
    /// focus waits until you've paused typing this long. Stopping first, then looking, switches right away.
    var typingQuiet: Double = 1.5
    /// No switching (and no pointer moves) until this long after you last used the mouse/trackpad.
    var mouseQuiet: Double = 1.5
    /// How much harder it is to switch away from the focused screen (≈ 1 unit per 1% of screen width).
    var hysteresis: Double = 2.0
    /// How far outside a screen (fraction of its size) still counts as "looking at it".
    var awayMargin: Double = 0.25
    var movePointer = true
    /// Same-screen window switching (off: screen switches land in the window you last used there).
    var switchWindows = false
    /// Split-pane switching in terminals and code editors.
    var switchPanes = false
    var paneClickFallback = true
    var electronPanes = true
    var learnFromClicks = true
    /// Per-screen nudge of the boundary (positive = this screen claims more of the edge).
    var screenBias: [String: Double] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EngineConfig()
        screenDwell = try c.decodeIfPresent(Double.self, forKey: .screenDwell) ?? d.screenDwell
        windowDwell = try c.decodeIfPresent(Double.self, forKey: .windowDwell) ?? d.windowDwell
        typingQuiet = try c.decodeIfPresent(Double.self, forKey: .typingQuiet) ?? d.typingQuiet
        mouseQuiet = try c.decodeIfPresent(Double.self, forKey: .mouseQuiet) ?? d.mouseQuiet
        hysteresis = try c.decodeIfPresent(Double.self, forKey: .hysteresis) ?? d.hysteresis
        awayMargin = try c.decodeIfPresent(Double.self, forKey: .awayMargin) ?? d.awayMargin
        movePointer = try c.decodeIfPresent(Bool.self, forKey: .movePointer) ?? d.movePointer
        switchWindows = try c.decodeIfPresent(Bool.self, forKey: .switchWindows) ?? d.switchWindows
        switchPanes = try c.decodeIfPresent(Bool.self, forKey: .switchPanes) ?? d.switchPanes
        paneClickFallback = try c.decodeIfPresent(Bool.self, forKey: .paneClickFallback) ?? d.paneClickFallback
        electronPanes = try c.decodeIfPresent(Bool.self, forKey: .electronPanes) ?? d.electronPanes
        learnFromClicks = try c.decodeIfPresent(Bool.self, forKey: .learnFromClicks) ?? d.learnFromClicks
        screenBias = try c.decodeIfPresent([String: Double].self, forKey: .screenBias) ?? d.screenBias
    }
}

final class ConfigBox {
    static let shared = ConfigBox()
    private let lock = NSLock()
    private var value = EngineConfig()
    var config: EngineConfig {
        get { lock.locked { value } }
        set { lock.locked { value = newValue } }
    }
}

/// User settings, stored in this app's local UserDefaults only.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard
    /// Called after any change that the app needs to react to (camera, dot, login item, hotkey).
    var onChange: (() -> Void)?

    private enum Keys {
        static let config = "engineConfig"
        static let camera = "cameraID"
        static let dot = "showGazeDot"
        static let login = "launchAtLogin"
        static let hotkey = "hotkeyEnabled"
        static let onboarded = "onboardingDone"
    }

    @Published var config: EngineConfig {
        didSet {
            guard config != oldValue else { return }
            ConfigBox.shared.config = config
            if let data = try? JSONEncoder().encode(config) { defaults.set(data, forKey: Keys.config) }
        }
    }
    @Published var cameraID: String? {
        didSet {
            defaults.set(cameraID, forKey: Keys.camera)
            if cameraID != oldValue { onChange?() }
        }
    }
    @Published var showGazeDot: Bool {
        didSet { defaults.set(showGazeDot, forKey: Keys.dot); onChange?() }
    }
    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Keys.login); onChange?() }
    }
    @Published var hotkeyEnabled: Bool {
        didSet { defaults.set(hotkeyEnabled, forKey: Keys.hotkey); onChange?() }
    }
    var onboardingDone: Bool {
        get { defaults.bool(forKey: Keys.onboarded) }
        set { defaults.set(newValue, forKey: Keys.onboarded) }
    }

    private init() {
        if let data = defaults.data(forKey: Keys.config),
           let c = try? JSONDecoder().decode(EngineConfig.self, from: data) {
            config = c
        } else {
            config = EngineConfig()
        }
        cameraID = defaults.string(forKey: Keys.camera)
        showGazeDot = defaults.object(forKey: Keys.dot) as? Bool ?? false
        launchAtLogin = defaults.object(forKey: Keys.login) as? Bool ?? true
        hotkeyEnabled = defaults.object(forKey: Keys.hotkey) as? Bool ?? true
        ConfigBox.shared.config = config
    }

    func resetSwitchingDefaults() {
        let bias = config.screenBias
        var c = EngineConfig()
        c.screenBias = bias
        config = c
    }
}

// MARK: - Live state for the UI

enum TrackingState: String {
    case off, paused, sleeping, noCamera, noFace, away, tracking, needsCalibration
}

struct LiveStatus: Equatable {
    var state: TrackingState = .off
    var facingID: String?
    var facingName: String?
    var yawDeg: Double = 0
    var pitchDeg: Double = 0
    /// Where it thinks you're looking, in global display coordinates (y down).
    var gazePoint: CGPoint?
    /// Expected error around `gazePoint`, in points.
    var sigma: CGSize = .zero
    var faceFound = false
    /// Why focus isn't moving right now (typing, mouse, modifier key), if anything.
    var waiting: String?
}

struct ScreenRow: Identifiable, Equatable {
    let id: String
    var name: String
    var connected: Bool
    var calibrated: Bool
    var samples: Int
    var clickSamples: Int
    var accuracy: String
    var calibratedAt: Date?
}

final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var live = LiveStatus()
    @Published var userPaused = false
    @Published var systemPaused = false
    @Published var axTrusted = false
    @Published var cameraAuthorized = false
    @Published var cameraDenied = false
    @Published var hasModel = false
    @Published var calibrating = false
    @Published var driftWarning: String?
    @Published var landmarks: [CGPoint] = []
    @Published var screenRows: [ScreenRow] = []
    @Published var framesAnalysed = 0
    @Published var cameraName: String?
    @Published var cameraError: String?
    @Published var privateFocusAPI = false
    @Published var uncalibratedScreens: [String] = []
}

/// In-memory event log shown in Settings → Diagnostics (also mirrored to the local unified log).
final class Diagnostics: ObservableObject {
    static let shared = Diagnostics()
    private let logger = Logger(subsystem: "io.github.baraaxalrefai.turnkey", category: "engine")
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    @Published private(set) var lines: [String] = []

    func add(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        let date = Date()
        DispatchQueue.main.async {
            self.lines.append("\(self.formatter.string(from: date))  \(message)")
            if self.lines.count > 400 { self.lines.removeFirst(self.lines.count - 400) }
        }
    }

    func clear() { lines.removeAll() }
}
