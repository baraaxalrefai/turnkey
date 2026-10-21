import AppKit
import ApplicationServices

struct WindowInfo: Equatable {
    let id: CGWindowID
    let pid: pid_t
    /// Global display coordinates (y down).
    let frame: CGRect
    let appName: String
    /// One of Turnkey's own windows (Settings, Setup). Never a focus target.
    var isOwn = false
}

struct FocusedWindow: Equatable {
    let pid: pid_t
    let windowID: CGWindowID
    let frame: CGRect
    let bundleID: String?
    let appName: String
}

/// Window list, focused window, focusing, pointer moves and the (rare) synthetic click.
final class WindowService {
    struct AppMeta {
        let regular: Bool
        let bundleID: String?
        let name: String
    }

    /// Marks our own synthetic mouse events so we never mistake them for you.
    static let syntheticMarker: Int64 = 0x5452_4E4B

    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let lock = NSLock()
    private var cached: [WindowInfo] = []
    private var cachedAt = -1.0
    private var appCache: [pid_t: AppMeta] = [:]

    /// Called right before we move the pointer or click, so the input monitor can ignore it.
    var onSyntheticInput: (() -> Void)?

    func appMeta(_ pid: pid_t) -> AppMeta {
        if let m = lock.locked({ appCache[pid] }) { return m }
        let app = NSRunningApplication(processIdentifier: pid)
        let m = AppMeta(regular: app?.activationPolicy == .regular,
                        bundleID: app?.bundleIdentifier,
                        name: app?.localizedName ?? "pid \(pid)")
        lock.locked {
            if appCache.count > 300 { appCache.removeAll() }
            appCache[pid] = m
        }
        return m
    }

    func forgetApp(_ pid: pid_t) {
        lock.locked { _ = appCache.removeValue(forKey: pid) }
    }

    /// Normal app windows on screen, front to back (our own windows included, flagged `isOwn`).
    func windows(maxAge: Double) -> [WindowInfo] {
        let t = uptime()
        if let c = lock.locked({ t - cachedAt <= maxAge ? cached : nil }) { return c }
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var out: [WindowInfo] = []
        for d in raw {
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  let number = d[kCGWindowNumber as String] as? Int,
                  let pidInt = d[kCGWindowOwnerPID as String] as? Int,
                  let bounds = d[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            let pid = pid_t(pidInt)
            let alpha = d[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0.05, rect.width >= 80, rect.height >= 60 else { continue }
            if pid == ownPID {
                out.append(WindowInfo(id: CGWindowID(number), pid: pid, frame: rect, appName: "Turnkey", isOwn: true))
                continue
            }
            let meta = appMeta(pid)
            guard meta.regular else { continue }
            out.append(WindowInfo(id: CGWindowID(number), pid: pid, frame: rect, appName: meta.name))
        }
        lock.locked {
            cached = out
            cachedAt = t
        }
        return out
    }

    func invalidate() {
        lock.locked { cachedAt = -1 }
    }

    /// The window that currently receives your keystrokes.
    func focusedWindow() -> FocusedWindow? {
        let sys = AXUIElementCreateSystemWide()
        guard let app = AX.element(sys, kAXFocusedApplicationAttribute),
              let pid = { () -> pid_t? in var p: pid_t = 0; return AXUIElementGetPid(app, &p) == .success ? p : nil }(),
              let win = AX.element(app, kAXFocusedWindowAttribute) else { return nil }
        let meta = appMeta(pid)
        let wid = PrivateAPI.windowID(of: win) ?? 0
        var frame = AX.frame(win) ?? .null
        if frame.isNull, wid != 0, let w = windows(maxAge: 0.5).first(where: { $0.id == wid }) {
            frame = w.frame
        }
        return FocusedWindow(pid: pid, windowID: wid, frame: frame, bundleID: meta.bundleID, appName: meta.name)
    }

    func axWindow(pid: pid_t, windowID: CGWindowID, frame: CGRect?) -> AXUIElement? {
        let app = AX.app(pid)
        let list = AX.elements(app, kAXWindowsAttribute)
        if let w = list.first(where: { PrivateAPI.windowID(of: $0) == windowID }) { return w }
        if let frame {
            return list.first { el in
                guard let f = AX.frame(el) else { return false }
                return abs(f.minX - frame.minX) < 2 && abs(f.minY - frame.minY) < 2 &&
                    abs(f.width - frame.width) < 2 && abs(f.height - frame.height) < 2
            }
        }
        return nil
    }

    /// Makes `w` the key window without clicking it, so whichever split pane had focus inside it keeps it.
    @discardableResult
    func focus(_ w: WindowInfo) -> Bool {
        let app = AX.app(w.pid)
        let axWin = axWindow(pid: w.pid, windowID: w.id, frame: w.frame)
        var done = PrivateAPI.focus(pid: w.pid, windowID: w.id)
        if let axWin {
            AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
            if !done {
                AX.setBool(axWin, kAXMainAttribute, true)
                done = AX.setBool(app, kAXFrontmostAttribute, true) == .success
            }
        }
        if !done {
            done = NSRunningApplication(processIdentifier: w.pid)?.activate(options: []) ?? false
        }
        invalidate()
        return done
    }

    // MARK: Pointer

    func pointerLocation() -> CGPoint? {
        CGEvent(source: nil)?.location
    }

    func warpPointer(to p: CGPoint) {
        onSyntheticInput?()
        CGWarpMouseCursorPosition(p)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Click once at `p` (used only for split panes that refuse Accessibility focus), then put the
    /// pointer back where it was.
    func click(at p: CGPoint) {
        let original = pointerLocation()
        let source = CGEventSource(stateID: .privateState)
        func event(_ type: CGEventType) -> CGEvent? {
            let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
            e?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            e?.setIntegerValueField(.mouseEventClickState, value: 1)
            return e
        }
        onSyntheticInput?()
        event(.leftMouseDown)?.post(tap: .cghidEventTap)
        usleep(15_000)
        event(.leftMouseUp)?.post(tap: .cghidEventTap)
        if let original {
            usleep(30_000)
            onSyntheticInput?()
            CGWarpMouseCursorPosition(original)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }
}
