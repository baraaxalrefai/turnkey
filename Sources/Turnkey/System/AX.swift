import AppKit
import ApplicationServices

/// Thin helpers over the Accessibility C API.
enum AX {
    static func configureTimeout() {
        // Applies to every AX call this process makes: a hung app must never stall us for long.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3)
    }

    static func value(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func elements(_ el: AXUIElement, _ attr: String) -> [AXUIElement] {
        guard let v = value(el, attr), CFGetTypeID(v) == CFArrayGetTypeID() else { return [] }
        return (v as? [AXUIElement]) ?? []
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        value(el, attr) as? String
    }

    static func role(_ el: AXUIElement) -> String? { string(el, kAXRoleAttribute) }
    static func parent(_ el: AXUIElement) -> AXUIElement? { element(el, kAXParentAttribute) }
    static func children(_ el: AXUIElement) -> [AXUIElement] { elements(el, kAXChildrenAttribute) }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = value(el, kAXPositionAttribute), let s = value(el, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    @discardableResult
    static func setBool(_ el: AXUIElement, _ attr: String, _ on: Bool) -> AXError {
        AXUIElementSetAttributeValue(el, attr as CFString, (on ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
    }

    static func app(_ pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    /// [element, parent, grandparent, …] up to (and including) the window.
    static func ancestors(_ el: AXUIElement, limit: Int = 64) -> [AXUIElement] {
        var out = [el]
        var cur = el
        if role(el) == kAXWindowRole { return out }
        while out.count < limit, let p = parent(cur) {
            let r = role(p)
            if r == kAXApplicationRole { break }
            out.append(p)
            if r == kAXWindowRole { break }
            cur = p
        }
        return out
    }

    static func same(_ a: AXUIElement, _ b: AXUIElement) -> Bool { CFEqual(a, b) }

    /// Breadth-first search below `root` for the first element with `role`.
    static func findDescendant(_ root: AXUIElement, role wanted: String, skipping skip: AXUIElement?,
                               budget: inout Int, maxDepth: Int = 14) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var i = 0
        while i < queue.count, budget > 0 {
            let (el, depth) = queue[i]
            i += 1
            budget -= 1
            if depth > 0, role(el) == wanted { return el }
            guard depth < maxDepth else { continue }
            // Very wide nodes are lists of lines/rows; their first children are enough.
            for c in children(el).prefix(48) {
                if let skip, same(c, skip) { continue }
                queue.append((c, depth + 1))
            }
        }
        return nil
    }

    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }
}
