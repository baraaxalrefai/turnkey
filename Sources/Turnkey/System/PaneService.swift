import AppKit
import ApplicationServices

struct PaneTarget {
    /// The text area to focus (a terminal surface or an editor's input).
    let element: AXUIElement
    /// Region of the window that belongs to that pane (global coordinates).
    let frame: CGRect
    let key: String
}

enum PaneProbe {
    /// Not a split-pane situation (or we couldn't tell).
    case none
    /// You're looking at the pane that already has focus.
    case same
    /// You're looking at another pane of the focused window.
    case target(PaneTarget)
}

/// Split-pane focus inside terminals and code editors, through Accessibility.
/// Browsers, chat apps and documents are never handled here — they switch as whole windows.
final class PaneService {
    static let terminals: Set<String> = [
        "com.googlecode.iterm2", "com.apple.Terminal", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "dev.warp.Warp", "net.kovidgoyal.kitty", "com.github.wez.wezterm",
        "co.zeit.hyper", "org.alacritty", "io.alacritty",
    ]
    /// Electron editors: their accessibility tree must be switched on (AXManualAccessibility).
    static let electronEditors: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf", "com.vscodium", "com.visualstudio.code.oss",
    ]
    /// Apps whose own "select split pane left/right/above/below" shortcuts (⌥⌘ + arrow) we can use
    /// instead of clicking, so nothing reaches the program running in the pane.
    static let arrowKeyPaneApps: Set<String> = ["com.googlecode.iterm2"]

    static let nativeEditors: Set<String> = [
        "com.apple.dt.Xcode", "dev.zed.Zed", "dev.zed.Zed-Preview", "com.sublimetext.4", "com.sublimetext.3",
        "com.google.android.studio",
    ]

    private let windows: WindowService
    private var electronEnabled: Set<pid_t> = []
    private var axFailures: [String: Int] = [:]
    private var arrowKeysFailed: Set<String> = []

    /// Probe results are reused while focus stays put, so a steady gaze costs almost nothing.
    private struct CacheEntry {
        let rect: CGRect
        let result: PaneProbe
        let time: Double
    }
    private var cache: [CacheEntry] = []
    private var cacheFocused: AXUIElement?
    private var cachePid: pid_t = 0

    init(windows: WindowService) {
        self.windows = windows
    }

    static func isSupported(_ bundleID: String?, electron: Bool) -> Bool {
        guard let id = bundleID else { return false }
        if terminals.contains(id) || nativeEditors.contains(id) || id.hasPrefix("com.jetbrains.") { return true }
        return electron && electronEditors.contains(id)
    }

    static func isElectron(_ bundleID: String?) -> Bool {
        bundleID.map { electronEditors.contains($0) } ?? false
    }

    /// Electron apps only build their accessibility tree when an assistive app asks for it.
    func prepare(pid: pid_t, bundleID: String?) {
        guard Self.isElectron(bundleID), !electronEnabled.contains(pid) else { return }
        let err = AX.setBool(AX.app(pid), "AXManualAccessibility", true)
        electronEnabled.insert(pid)
        Diagnostics.shared.add("Enabled accessibility tree for \(windows.appMeta(pid).name) (\(err == .success ? "ok" : "error \(err.rawValue)"))")
    }

    /// Which pane is under `p`, compared with the pane that has keyboard focus.
    func probe(at p: CGPoint, pid: pid_t, bundleID: String?) -> PaneProbe {
        prepare(pid: pid, bundleID: bundleID)
        let app = AX.app(pid)
        guard let focused = AX.element(app, kAXFocusedUIElementAttribute) else { return .none }
        let now = uptime()
        if cachePid != pid || cacheFocused.map({ !AX.same($0, focused) }) ?? true {
            cache.removeAll()
            cacheFocused = focused
            cachePid = pid
        }
        cache.removeAll { now - $0.time > 1.5 }
        if let hit = cache.first(where: { $0.rect.contains(p) }) { return hit.result }

        let result = computeProbe(at: p, app: app, focused: focused)
        let rect: CGRect
        if case .target(let t) = result {
            rect = t.frame
        } else {
            rect = CGRect(x: p.x - 30, y: p.y - 30, width: 60, height: 60)
        }
        cache.append(CacheEntry(rect: rect, result: result, time: now))
        return result
    }

    func invalidateCache() {
        cache.removeAll()
        cacheFocused = nil
    }

    private func computeProbe(at p: CGPoint, app: AXUIElement, focused: AXUIElement) -> PaneProbe {
        var hitRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &hitRef) == .success,
              let hit = hitRef else { return .none }

        let chainH = AX.ancestors(hit)
        let chainF = AX.ancestors(focused)
        guard let winH = chainH.last, AX.role(winH) == kAXWindowRole,
              let winF = chainF.last, AX.same(winH, winF) else { return .none }

        // Lowest common ancestor of what you look at and what has focus.
        var lcaH = -1
        outer: for (i, a) in chainH.enumerated() {
            for b in chainF where AX.same(a, b) {
                lcaH = i
                break outer
            }
        }
        guard lcaH >= 0 else { return .none }
        // One contains the other → it's the focused pane (or its container).
        if lcaH == 0 || chainF.contains(where: { AX.same($0, chainH[0]) }) { return .same }
        if chainH.contains(where: { AX.same($0, focused) }) { return .same }

        // 1) A text area directly under the gaze (terminal surfaces, native editors).
        for el in chainH[0..<lcaH] where AX.role(el) == kAXTextAreaRole {
            guard let frame = AX.frame(el), frame.width > 60, frame.height > 40 else { continue }
            return .target(PaneTarget(element: el, frame: frame, key: Self.key(frame)))
        }
        // 2) Otherwise the nearest text area inside the smallest container of the gaze point that
        //    doesn't contain the focused element (e.g. VS Code's editor groups).
        var budget = 600
        var searched: AXUIElement?
        for level in 0..<lcaH {
            let container = chainH[level]
            if let ta = AX.findDescendant(container, role: kAXTextAreaRole, skipping: searched, budget: &budget) {
                guard let frame = AX.frame(container), frame.width > 60, frame.height > 40 else { return .none }
                return .target(PaneTarget(element: ta, frame: frame, key: Self.key(frame)))
            }
            searched = container
            if budget <= 0 { break }
        }
        return .none
    }

    /// Centre of whatever has keyboard focus in the app (the current pane).
    func focusedPoint(pid: pid_t) -> CGPoint? {
        guard let f = AX.element(AX.app(pid), kAXFocusedUIElementAttribute), let r = AX.frame(f) else { return nil }
        return r.center
    }

    /// Focus a pane via Accessibility; for terminals/editors that refuse, click the middle of the pane
    /// (only inside that same app's window, and only if allowed).
    func focus(_ t: PaneTarget, pid: pid_t, windowID: CGWindowID, bundleID: String?, allowClick: Bool) -> String? {
        let app = AX.app(pid)
        let appKey = bundleID ?? "pid \(pid)"
        // 1) Accessibility (skipped once an app has refused it three times in a row).
        if axFailures[appKey, default: 0] < 3 {
            let err = AX.setBool(t.element, kAXFocusedAttribute, true)
            if err == .success {
                for _ in 0..<6 {
                    usleep(30_000)
                    if let f = AX.element(app, kAXFocusedUIElementAttribute), isInside(f, t) {
                        axFailures[appKey] = 0
                        return "accessibility"
                    }
                }
            }
            axFailures[appKey, default: 0] += 1
            if axFailures[appKey] == 3 {
                Diagnostics.shared.add("\(windows.appMeta(pid).name) doesn't take pane focus via Accessibility (\(err == .success ? "accepted but focus didn't move" : "error \(err.rawValue)")); using its fallback")
            }
        }
        // 2) The app's own pane-navigation shortcuts, sent only to that app.
        if let id = bundleID, Self.arrowKeyPaneApps.contains(id), !arrowKeysFailed.contains(id) {
            if navigateWithArrowKeys(to: t, pid: pid, app: app) { return "pane shortcut" }
            arrowKeysFailed.insert(id)
            Diagnostics.shared.add("\(windows.appMeta(pid).name): ⌥⌘-arrow pane shortcuts didn't move focus; using clicks")
        }
        // 3) Last resort: click the middle of the pane.
        guard allowClick else { return nil }
        let center = t.frame.center
        guard let top = windows.windows(maxAge: 0).first(where: { $0.frame.contains(center) }),
              top.pid == pid, windowID == 0 || top.id == windowID else { return nil }
        windows.click(at: center)
        return "click"
    }

    /// Steps towards the target pane with ⌥⌘ + arrow, checking after each step that focus moved.
    private func navigateWithArrowKeys(to t: PaneTarget, pid: pid_t, app: AXUIElement) -> Bool {
        for _ in 0..<4 {
            guard let cur = AX.element(app, kAXFocusedUIElementAttribute), let cf = AX.frame(cur) else { return false }
            if t.frame.contains(cf.center) { return true }
            let dx = t.frame.midX - cf.midX, dy = t.frame.midY - cf.midY
            let key: CGKeyCode = abs(dx) >= abs(dy) ? (dx > 0 ? 124 : 123) : (dy > 0 ? 125 : 126)
            postKey(key, to: pid)
            var moved = false
            for _ in 0..<8 {
                usleep(25_000)
                if let now = AX.element(app, kAXFocusedUIElementAttribute), let nf = AX.frame(now),
                   abs(nf.midX - cf.midX) > 1 || abs(nf.midY - cf.midY) > 1 {
                    moved = true
                    break
                }
            }
            if !moved { return false }
        }
        guard let cur = AX.element(app, kAXFocusedUIElementAttribute), let cf = AX.frame(cur) else { return false }
        return t.frame.contains(cf.center)
    }

    private func postKey(_ code: CGKeyCode, to pid: pid_t) {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            e.flags = [.maskCommand, .maskAlternate, .maskSecondaryFn, .maskNumericPad]
            e.setIntegerValueField(.eventSourceUserData, value: WindowService.syntheticMarker)
            e.postToPid(pid)
        }
    }

    private func isInside(_ el: AXUIElement, _ t: PaneTarget) -> Bool {
        if AX.same(el, t.element) { return true }
        if AX.ancestors(el, limit: 24).contains(where: { AX.same($0, t.element) }) { return true }
        if let f = AX.frame(el), f.width > 0, t.frame.contains(f.center) { return true }
        return false
    }

    static func key(_ r: CGRect) -> String {
        "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))"
    }
}
