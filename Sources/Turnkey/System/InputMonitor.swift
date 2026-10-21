import AppKit
import CoreGraphics

/// Knows when you last typed or used the mouse/trackpad. It only records timestamps — never which keys.
final class InputMonitor {
    private let lock = NSLock()
    private var lastKey = -100.0
    private var lastMouse = -100.0
    private var lastSynthetic = -100.0
    private var monitors: [Any] = []

    /// Left clicks you make (global coordinates, y down), on the main thread.
    var onClick: ((CGPoint, Double) -> Void)?

    /// (Re)installs the global monitors. Key events only arrive once Accessibility is granted,
    /// so this is called again when that happens.
    func start() {
        stop()
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            guard let self, !self.isSynthetic(e) else { return }
            self.noteKey()
        }) {
            monitors.append(m)
        }
        let mouseMask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .rightMouseDown, .otherMouseDown, .scrollWheel,
            .magnify, .swipe, .rotate, .smartMagnify,
        ]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mouseMask, handler: { [weak self] e in
            guard let self, !self.isSynthetic(e) else { return }
            self.noteMouse()
        }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] e in
            guard let self, !self.isSynthetic(e) else { return }
            self.noteMouse()
            if let p = e.cgEvent?.location { self.onClick?(p, uptime()) }
        }) {
            monitors.append(m)
        }
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
    }

    private func isSynthetic(_ e: NSEvent) -> Bool {
        e.cgEvent?.getIntegerValueField(.eventSourceUserData) == WindowService.syntheticMarker
    }

    private func noteKey() { lock.locked { lastKey = uptime() } }
    private func noteMouse() { lock.locked { lastMouse = uptime() } }

    func noteSynthetic() { lock.locked { lastSynthetic = uptime() } }

    func typingIdle(now: Double) -> Double {
        let monitored = now - lock.locked { lastKey }
        let hid = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
        return min(monitored, hid)
    }

    func mouseIdle(now: Double) -> Double {
        let (mouse, synthetic) = lock.locked { (lastMouse, lastSynthetic) }
        let monitored = now - mouse
        // Right after our own pointer move/click, trust only the monitor (it filters synthetic events).
        if now - synthetic < 0.6 { return monitored }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                    .leftMouseDragged, .rightMouseDragged, .scrollWheel]
        let hid = types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
        return min(monitored, hid)
    }

    /// Holding ⌘/⌥/⌃/⇧ means you're in the middle of a shortcut (e.g. ⌘-Tab): never switch then.
    func modifiersHeld() -> Bool {
        let f = CGEventSource.flagsState(.hidSystemState)
        return f.contains(.maskCommand) || f.contains(.maskAlternate) || f.contains(.maskControl) || f.contains(.maskShift)
    }
}
