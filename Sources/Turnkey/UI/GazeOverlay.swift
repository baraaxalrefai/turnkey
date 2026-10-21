import AppKit

/// Click-through, transparent window per screen that shows the gaze dot and outlines the screen you face.
final class GazeOverlayController {
    private var items: [String: (window: NSWindow, view: GazeOverlayView)] = [:]
    private var visible = false

    func setVisible(_ on: Bool, screens: [ScreenGeom]) {
        if on == visible, !on || Set(items.keys) == Set(screens.map(\.id)) { return }
        visible = on
        rebuild(screens: screens)
    }

    func rebuild(screens: [ScreenGeom]) {
        for (_, item) in items { item.window.orderOut(nil) }
        items.removeAll()
        guard visible else { return }
        for s in screens {
            let window = NSWindow(contentRect: ScreenRegistry.cocoaRect(s.frame), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.sharingType = .none
            let view = GazeOverlayView(frame: NSRect(origin: .zero, size: s.frame.size))
            view.screenFrame = s.frame
            window.contentView = view
            window.setFrame(ScreenRegistry.cocoaRect(s.frame), display: false)
            window.orderFrontRegardless()
            items[s.id] = (window, view)
        }
    }

    func update(_ status: LiveStatus) {
        guard visible else { return }
        for (id, item) in items {
            let v = item.view
            let facing = status.facingID == id
            let dot = facing ? status.gazePoint : nil
            if v.facing != facing || v.dot != dot || v.sigma != status.sigma {
                v.facing = facing
                v.dot = dot
                v.sigma = status.sigma
                v.needsDisplay = true
            }
        }
    }
}

final class GazeOverlayView: NSView {
    var screenFrame: CGRect = .zero
    var facing = false
    var dot: CGPoint?
    var sigma: CGSize = .zero

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard facing else { return }
        let accent = NSColor.systemTeal
        // Outline the screen you're facing.
        accent.withAlphaComponent(0.55).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
        border.lineWidth = 4
        border.stroke()

        guard let dot else { return }
        let p = CGPoint(x: dot.x - screenFrame.minX, y: dot.y - screenFrame.minY)
        // Uncertainty ellipse (≈ how precise window/pane targeting is right now).
        if sigma.width > 0, sigma.height > 0 {
            let ring = NSBezierPath(ovalIn: CGRect(x: p.x - sigma.width, y: p.y - sigma.height,
                                                   width: sigma.width * 2, height: sigma.height * 2))
            accent.withAlphaComponent(0.10).setFill()
            ring.fill()
            accent.withAlphaComponent(0.35).setStroke()
            ring.lineWidth = 1.5
            ring.stroke()
        }
        let r: CGFloat = 11
        let circle = NSBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        accent.withAlphaComponent(0.85).setFill()
        circle.fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        circle.lineWidth = 2
        circle.stroke()
    }
}
