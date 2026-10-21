import AppKit
import TurnkeyCore

/// "Follow the dot" calibration: one screen at a time, ~16 spots each (including extra spots along the
/// edges a screen shares with its neighbours), about 30 seconds per screen.
final class CalibrationController: NSObject {
    private let targets: [ScreenGeom]
    private let allScreens: [ScreenGeom]
    private let models: ModelStore
    /// Called once when calibration closes (`saved` = new calibration stored).
    var onFinish: ((_ saved: Bool) -> Void)?

    private var windows: [String: CalibrationWindow] = [:]
    private var views: [String: CalibrationView] = [:]
    private var timer: Timer?

    private enum Phase {
        case intro
        case lead(start: Double)
        case moving(start: Double, from: CGPoint)
        case settling(start: Double)
        case collecting(start: Double)
        case training
        case summary
        case closed
    }

    private var phase: Phase = .intro
    private var screenIndex = 0
    private var points: [CalibPoint] = []
    private var pointIndex = 0
    private var dot = CGPoint.zero
    private var frames: [FaceFeatures] = []
    private var samples: [CalibSample] = []
    private var group = 0
    private var lastFaceAt = -100.0
    private var lastTick = 0.0
    private var saved = false

    static let moveTime = 0.5
    static let settleTime = 0.45
    static let collectTime = 0.9
    static let leadTime = 1.4

    init(targets: [ScreenGeom], allScreens: [ScreenGeom], models: ModelStore) {
        self.targets = targets
        self.allScreens = allScreens
        self.models = models
    }

    private var current: ScreenGeom { targets[min(screenIndex, targets.count - 1)] }
    private var currentView: CalibrationView? { views[current.id] }

    // MARK: Lifecycle

    func begin() {
        for s in allScreens {
            let w = CalibrationWindow(cgFrame: s.frame)
            let v = CalibrationView(frame: NSRect(origin: .zero, size: s.frame.size))
            v.controller = self
            w.contentView = v
            w.orderFrontRegardless()
            windows[s.id] = w
            views[s.id] = v
        }
        NSApp.activate(ignoringOtherApps: true)
        focusWindow(of: current)
        NSCursor.setHiddenUntilMouseMoves(true)
        phase = .intro
        lastTick = uptime()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        render()
    }

    private func focusWindow(of s: ScreenGeom) {
        guard let w = windows[s.id] else { return }
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(views[s.id])
    }

    private func close() {
        guard !isClosed else { return }
        phase = .closed
        timer?.invalidate()
        timer = nil
        for (_, w) in windows { w.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        onFinish?(saved)
    }

    private var isClosed: Bool {
        if case .closed = phase { return true }
        return false
    }

    // MARK: Input from the app

    /// Raw features for every analysed frame (main thread).
    func receive(_ f: FaceFeatures?, time: Double) {
        guard let f else { return }
        lastFaceAt = time
        if case .collecting = phase, f.eyeOpen >= 0.15 {
            frames.append(f)
        }
    }

    /// Live gaze status (used for the "look around to check" dot after calibrating).
    func updateLive(_ s: LiveStatus) {
        guard case .summary = phase else { return }
        for (id, v) in views {
            let p = s.facingID == id ? s.gazePoint : nil
            let frame = allScreens.first { $0.id == id }?.frame ?? .zero
            v.liveDot = p.map { CGPoint(x: $0.x - frame.minX, y: $0.y - frame.minY) }
            v.liveSigma = s.sigma
            v.needsDisplay = true
        }
    }

    func key(_ event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            if case .summary = phase { close() } else { saved = false; close() }
        case 49: // Space
            if case .intro = phase { startScreen(0) }
        case 36, 76: // Return / Enter
            if case .summary = phase { close() } else if case .intro = phase { startScreen(0) }
        case 15: // R
            if case .summary = phase { restart() }
        default:
            break
        }
    }

    func clicked() {
        if case .intro = phase { startScreen(0) }
    }

    private func restart() {
        samples.removeAll()
        group = 0
        screenIndex = 0
        phase = .intro
        for v in views.values { v.liveDot = nil }
        focusWindow(of: current)
        render()
    }

    // MARK: Sequence

    private func startScreen(_ index: Int) {
        screenIndex = index
        let s = current
        let neighbours = allScreens.filter { $0.id != s.id }.map(\.frame)
        points = CalibrationLayout.points(for: s.frame, neighbours: neighbours)
        pointIndex = 0
        dot = CGPoint(x: s.frame.width / 2, y: s.frame.height / 2)
        phase = .lead(start: uptime())
        focusWindow(of: s)
        render()
    }

    private func target(_ p: CalibPoint) -> CGPoint {
        CGPoint(x: p.u * current.frame.width, y: p.v * current.frame.height)
    }

    private func beginPoint(_ i: Int, from: CGPoint) {
        pointIndex = i
        phase = .moving(start: uptime(), from: from)
    }

    private func finishPoint() {
        let p = points[pointIndex]
        group += 1
        samples += makeSamples(frames, screen: current, point: p, group: group)
        frames.removeAll()
        if pointIndex + 1 < points.count {
            beginPoint(pointIndex + 1, from: dot)
        } else if screenIndex + 1 < targets.count {
            startScreen(screenIndex + 1)
        } else {
            finishAll()
        }
    }

    private func finishAll() {
        phase = .training
        render()
        var names: [String: String] = [:]
        for s in targets { names[s.id] = s.name }
        let collected = samples
        models.replaceCalibration(screens: targets.map(\.id), names: names, samples: collected) { [weak self] report in
            guard let self, !self.isClosed else { return }
            self.saved = true
            self.showSummary(report)
        }
    }

    private func showSummary(_ report: TrainingReport?) {
        var lines: [String] = []
        for s in targets {
            if let r = report?.screen(s.id) {
                let cmX = r.sigmaU * Double(s.sizeMM.width) / 10
                let cmY = r.sigmaV * Double(s.sizeMM.height) / 10
                var line = "\(s.name): about ±\(String(format: "%.1f", cmX)) cm across, ±\(String(format: "%.1f", cmY)) cm up/down"
                if let hit = r.hitRate { line += " · screen detection \(Int((hit * 100).rounded()))%" }
                lines.append(line)
            } else {
                lines.append("\(s.name): not enough face data — try again with your face well lit and in view")
            }
        }
        phase = .summary
        for (id, v) in views {
            v.mode = .summary
            v.title = id == targets[0].id ? "Calibration saved" : nil
            v.body = id == targets[0].id ? lines.joined(separator: "\n") : nil
            v.footer = "Look around — the dot shows where Turnkey thinks you're looking.\nReturn: done   ·   R: redo"
            v.dot = nil
            v.needsDisplay = true
        }
        focusWindow(of: targets[0])
    }

    private func makeSamples(_ frames: [FaceFeatures], screen: ScreenGeom, point: CalibPoint, group: Int) -> [CalibSample] {
        guard frames.count >= 4, let med = FaceFeatures.median(frames) else { return [] }
        // Drop outlier frames (a look away, a mis-detected landmark).
        let keys: [KeyPath<FaceFeatures, Double>] = [\.yaw, \.pitch, \.noseX, \.noseY, \.gazeX]
        let floors = [0.02, 0.02, 0.02, 0.02, 0.03]
        let spreads = keys.enumerated().map { i, k in max(1.4826 * Stats.mad(frames.map { $0[keyPath: k] }), floors[i]) }
        let kept = frames.filter { f in
            for (i, k) in keys.enumerated() where abs(f[keyPath: k] - med[keyPath: k]) > 3 * spreads[i] {
                return false
            }
            return true
        }
        let now = Date().timeIntervalSince1970
        return kept.map {
            CalibSample(f: $0, screen: screen.id, u: point.u, v: point.v, group: group, edge: point.edge,
                        source: .calibration, time: now)
        }
    }

    // MARK: Animation

    private func tick() {
        let now = uptime()
        let dt = now - lastTick
        lastTick = now
        let faceOK = now - lastFaceAt < 0.4

        switch phase {
        case .lead(let start):
            if now - start >= Self.leadTime { beginPoint(0, from: dot) }
        case .moving(let start, let from):
            let t = min((now - start) / Self.moveTime, 1)
            let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            let to = target(points[pointIndex])
            dot = CGPoint(x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e)
            if t >= 1 { phase = .settling(start: now) }
        case .settling(let start):
            if now - start >= Self.settleTime {
                frames.removeAll()
                phase = .collecting(start: now)
            }
        case .collecting(let start):
            if !faceOK {
                // Pause the clock until your face is back in view.
                phase = .collecting(start: start + dt)
            } else if now - start >= Self.collectTime {
                finishPoint()
            }
        default:
            break
        }
        render(faceOK: faceOK, now: now)
    }

    private func render(faceOK: Bool = true, now: Double = uptime()) {
        guard !isClosed else { return }
        let active = current.id
        for (id, v) in views {
            switch phase {
            case .summary:
                continue
            case .training:
                v.mode = id == targets[0].id ? .active : .dimmed
                v.title = id == targets[0].id ? "Calculating…" : nil
                v.body = nil
                v.footer = nil
                v.dot = nil
            case .intro:
                let isActive = id == active
                v.mode = isActive ? .active : .dimmed
                v.dot = nil
                if isActive {
                    v.title = targets.count > 1 ? "Calibrate your screens" : "Calibrate \(current.name)"
                    v.body = """
                    Sit the way you normally do. A dot will move around \(targets.count > 1 ? "each screen" : "the screen").
                    Follow it with your eyes and let your head turn naturally — the way it does when you work.
                    About 30 seconds per screen\(targets.count > 1 ? " (\(targets.count) screens)" : "").
                    """
                    v.footer = faceOK ? "Press Space to start   ·   Esc to cancel" : "Looking for your face…   ·   Esc to cancel"
                    v.faceOK = faceOK
                } else {
                    v.title = nil
                    v.body = targets.contains(where: { $0.id == id }) ? "This screen comes next." : nil
                    v.footer = nil
                }
            default:
                let isActive = id == active
                v.mode = isActive ? .active : .dimmed
                if isActive {
                    v.title = nil
                    v.body = nil
                    v.dot = dot
                    v.faceOK = faceOK
                    switch phase {
                    case .lead(let start):
                        v.dotStyle = .lead(min((now - start) / Self.leadTime, 1))
                        v.footer = "Screen \(screenIndex + 1) of \(targets.count): \(current.name) — follow the dot"
                    case .moving:
                        v.dotStyle = .moving
                        v.footer = progressText(faceOK)
                    case .settling(let start):
                        v.dotStyle = .settling(min((now - start) / Self.settleTime, 1))
                        v.footer = progressText(faceOK)
                    case .collecting(let start):
                        v.dotStyle = .collecting(min(max((now - start) / Self.collectTime, 0), 1))
                        v.footer = progressText(faceOK)
                    default:
                        break
                    }
                } else {
                    v.dot = nil
                    v.title = nil
                    v.footer = nil
                    v.body = "Calibrating \(current.name)…"
                }
            }
            v.needsDisplay = true
        }
    }

    private func progressText(_ faceOK: Bool) -> String {
        if !faceOK { return "Can't see your face — look towards the dot" }
        return "Spot \(pointIndex + 1) of \(points.count)  ·  Screen \(screenIndex + 1) of \(targets.count)   ·   Esc to cancel"
    }
}

final class CalibrationWindow: NSWindow {
    init(cgFrame: CGRect) {
        let rect = ScreenRegistry.cocoaRect(cgFrame)
        super.init(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(rect, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class CalibrationView: NSView {
    enum Mode { case active, dimmed, summary }
    enum DotStyle {
        case lead(Double)
        case moving
        case settling(Double)
        case collecting(Double)
    }

    weak var controller: CalibrationController?
    var mode: Mode = .dimmed
    var title: String?
    var body: String?
    var footer: String?
    var dot: CGPoint?
    var dotStyle: DotStyle = .moving
    var faceOK = true
    var liveDot: CGPoint?
    var liveSigma: CGSize = .zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func keyDown(with event: NSEvent) { controller?.key(event) }
    override func mouseDown(with event: NSEvent) { controller?.clicked() }

    private let accent = NSColor.systemTeal

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = mode == .dimmed ? 0.86 : 0.93
        NSColor(calibratedWhite: 0.05, alpha: alpha).setFill()
        bounds.fill()

        if let title {
            draw(title, font: .systemFont(ofSize: 30, weight: .semibold), color: .white,
                 rect: CGRect(x: 40, y: bounds.midY - 150, width: bounds.width - 80, height: 44))
        }
        if let body {
            let font = NSFont.systemFont(ofSize: mode == .dimmed ? 18 : 17, weight: .regular)
            draw(body, font: font, color: NSColor(white: 0.85, alpha: 1),
                 rect: CGRect(x: max(40, bounds.midX - 380), y: bounds.midY - 90, width: min(760, bounds.width - 80), height: 200))
        }
        if let footer {
            let color = faceOK ? NSColor(white: 0.7, alpha: 1) : NSColor.systemOrange
            draw(footer, font: .systemFont(ofSize: 14, weight: .medium), color: color,
                 rect: CGRect(x: 40, y: bounds.maxY - 110, width: bounds.width - 80, height: 50))
        }
        if let dot { drawDot(at: dot) }
        if let liveDot { drawLive(at: liveDot) }
    }

    private func draw(_ s: String, font: NSFont, color: NSColor, rect: CGRect) {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.lineSpacing = 5
        (s as NSString).draw(with: rect, options: [.usesLineFragmentOrigin],
                             attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
    }

    private func circle(_ c: CGPoint, _ r: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    private func drawDot(at p: CGPoint) {
        switch dotStyle {
        case .lead(let t):
            let pulse = 1 + 0.25 * sin(t * .pi * 4)
            NSColor.white.withAlphaComponent(0.25).setFill()
            circle(p, 22 * pulse).fill()
            NSColor.white.setFill()
            circle(p, 9).fill()
        case .moving:
            NSColor.white.withAlphaComponent(0.2).setFill()
            circle(p, 16).fill()
            NSColor.white.setFill()
            circle(p, 9).fill()
        case .settling(let t):
            accent.withAlphaComponent(0.8).setStroke()
            let ring = circle(p, 9 + 30 * (1 - t))
            ring.lineWidth = 2
            ring.stroke()
            NSColor.white.setFill()
            circle(p, 9).fill()
        case .collecting(let t):
            accent.setFill()
            circle(p, 11).fill()
            NSColor.white.setFill()
            circle(p, 4).fill()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: p, radius: 19, startAngle: -90, endAngle: -90 + 360 * t, clockwise: false)
            accent.setStroke()
            arc.lineWidth = 3
            arc.stroke()
        }
        if !faceOK {
            NSColor.systemOrange.setStroke()
            let warn = circle(p, 26)
            warn.lineWidth = 2
            warn.stroke()
        }
    }

    private func drawLive(at p: CGPoint) {
        if liveSigma.width > 0 {
            let ring = NSBezierPath(ovalIn: CGRect(x: p.x - liveSigma.width, y: p.y - liveSigma.height,
                                                   width: liveSigma.width * 2, height: liveSigma.height * 2))
            accent.withAlphaComponent(0.12).setFill()
            ring.fill()
        }
        accent.withAlphaComponent(0.9).setFill()
        circle(p, 12).fill()
        NSColor.white.setStroke()
        let c = circle(p, 12)
        c.lineWidth = 2
        c.stroke()
    }
}
