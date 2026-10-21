import AppKit

struct ScreenGeom: Equatable, Identifiable {
    /// Stable display UUID (survives reboots and re-plugging).
    let id: String
    let displayID: CGDirectDisplayID
    let name: String
    /// Global display coordinates: origin at the top-left of the main display, y pointing down.
    let frame: CGRect
    let isBuiltin: Bool
    /// Physical size in millimetres (from the display's EDID).
    let sizeMM: CGSize
}

/// Thread-safe snapshot of the connected displays.
final class ScreenRegistry {
    private let lock = NSLock()
    private var current: [ScreenGeom] = []

    var screens: [ScreenGeom] { lock.locked { current } }

    /// Call on the main thread (uses NSScreen for display names).
    func refresh() {
        var names: [CGDirectDisplayID: String] = [:]
        for s in NSScreen.screens {
            if let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[n.uint32Value] = s.localizedName
            }
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return }
        var list: [ScreenGeom] = []
        for d in ids.prefix(Int(count)) {
            if CGDisplayMirrorsDisplay(d) != kCGNullDirectDisplay { continue }
            var id = "display-\(d)"
            if let uuid = CGDisplayCreateUUIDFromDisplayID(d)?.takeRetainedValue(),
               let s = CFUUIDCreateString(kCFAllocatorDefault, uuid) {
                id = s as String
            }
            let builtin = CGDisplayIsBuiltin(d) != 0
            list.append(ScreenGeom(
                id: id,
                displayID: d,
                name: names[d] ?? (builtin ? "Built-in Display" : "Display \(d)"),
                frame: CGDisplayBounds(d),
                isBuiltin: builtin,
                sizeMM: CGDisplayScreenSize(d)
            ))
        }
        list.sort { $0.frame.minX == $1.frame.minX ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX }
        lock.locked { current = list }
    }

    func screen(containing p: CGPoint) -> ScreenGeom? {
        Self.screen(containing: p, in: screens)
    }

    static func screen(containing p: CGPoint, in list: [ScreenGeom]) -> ScreenGeom? {
        list.first { $0.frame.contains(p) }
    }

    /// The screen a window mostly sits on.
    static func screen(for rect: CGRect, in list: [ScreenGeom]) -> ScreenGeom? {
        var best: ScreenGeom?
        var bestArea: CGFloat = 0
        for s in list {
            let i = s.frame.intersection(rect)
            guard !i.isNull else { continue }
            let area = i.width * i.height
            if area > bestArea {
                bestArea = area
                best = s
            }
        }
        return best
    }

    /// Converts global display coordinates (y down) to AppKit window coordinates (y up).
    static func cocoaRect(_ r: CGRect) -> NSRect {
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        return NSRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }
}
