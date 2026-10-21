import Foundation
import CoreGraphics

public struct CalibPoint: Equatable, Sendable {
    public var u: Double
    public var v: Double
    public var edge: Bool

    public init(u: Double, v: Double, edge: Bool) {
        self.u = u
        self.v = v
        self.edge = edge
    }
}

/// Where the calibration dot goes on each screen.
public enum CalibrationLayout {
    /// A 3×3 grid plus an inner ring.
    public static let base: [CalibPoint] = [
        (0.50, 0.50),
        (0.08, 0.08), (0.50, 0.08), (0.92, 0.08),
        (0.92, 0.50), (0.92, 0.92), (0.50, 0.92),
        (0.08, 0.92), (0.08, 0.50),
        (0.29, 0.29), (0.71, 0.29), (0.71, 0.71), (0.29, 0.71),
    ].map { CalibPoint(u: $0.0, v: $0.1, edge: false) }

    /// Points for `screen`, plus extra spots along every edge it shares with a neighbour.
    /// Rects are in global display coordinates with y pointing down.
    public static func points(for screen: CGRect, neighbours: [CGRect], inset: Double = 0.025) -> [CalibPoint] {
        var pts = base
        for o in neighbours {
            let vLo = max(screen.minY, o.minY), vHi = min(screen.maxY, o.maxY)
            let hLo = max(screen.minX, o.minX), hHi = min(screen.maxX, o.maxX)
            if vHi - vLo > 80 {
                let vs = fractions(vLo, vHi).map { Double(($0 - screen.minY) / screen.height) }
                if abs(screen.maxX - o.minX) < 4 {
                    pts += vs.map { CalibPoint(u: 1 - inset, v: clamp($0), edge: true) }
                }
                if abs(screen.minX - o.maxX) < 4 {
                    pts += vs.map { CalibPoint(u: inset, v: clamp($0), edge: true) }
                }
            }
            if hHi - hLo > 80 {
                let us = fractions(hLo, hHi).map { Double(($0 - screen.minX) / screen.width) }
                if abs(screen.maxY - o.minY) < 4 {
                    pts += us.map { CalibPoint(u: clamp($0), v: 1 - inset, edge: true) }
                }
                if abs(screen.minY - o.maxY) < 4 {
                    pts += us.map { CalibPoint(u: clamp($0), v: inset, edge: true) }
                }
            }
        }
        // The dot starts in the centre, but that spot is recorded last: at the very start you may still be
        // turned towards the previous screen, following the dot with your eyes only.
        var path = ordered(pts)
        if path.count > 1 { path.append(path.removeFirst()) }
        return path
    }

    static func fractions(_ lo: CGFloat, _ hi: CGFloat) -> [CGFloat] {
        [0.18, 0.5, 0.82].map { lo + (hi - lo) * $0 }
    }

    static func clamp(_ x: Double) -> Double { min(max(x, 0.05), 0.95) }

    /// Greedy nearest-neighbour path starting at the centre, so the dot never jumps across the screen.
    public static func ordered(_ pts: [CalibPoint]) -> [CalibPoint] {
        guard !pts.isEmpty else { return [] }
        var remaining = pts
        let start = remaining.firstIndex { abs($0.u - 0.5) < 1e-9 && abs($0.v - 0.5) < 1e-9 } ?? 0
        var out = [remaining.remove(at: start)]
        while !remaining.isEmpty {
            let last = out[out.count - 1]
            func d(_ p: CalibPoint) -> Double { hypot(p.u - last.u, p.v - last.v) }
            var best = 0
            for i in remaining.indices where d(remaining[i]) < d(remaining[best]) { best = i }
            out.append(remaining.remove(at: best))
        }
        return out
    }
}
