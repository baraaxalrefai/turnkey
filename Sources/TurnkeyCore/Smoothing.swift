import Foundation

/// The 1€ filter (Casiez et al.): smooth when still, responsive when moving.
public struct OneEuroFilter: Sendable {
    public var minCutoff: Double
    public var beta: Double
    public var dCutoff: Double
    private var xPrev: Double?
    private var dxPrev = 0.0
    private var tPrev = 0.0

    public init(minCutoff: Double = 1.0, beta: Double = 0.5, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    private static func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    public mutating func filter(_ x: Double, t: Double) -> Double {
        guard let prev = xPrev else {
            xPrev = x
            tPrev = t
            dxPrev = 0
            return x
        }
        let dt = max(t - tPrev, 1e-3)
        let dx = (x - prev) / dt
        let aD = Self.alpha(dCutoff, dt)
        let edx = aD * dx + (1 - aD) * dxPrev
        let cutoff = minCutoff + beta * abs(edx)
        let a = Self.alpha(cutoff, dt)
        let xHat = a * x + (1 - a) * prev
        xPrev = xHat
        dxPrev = edx
        tPrev = t
        return xHat
    }

    public mutating func reset() {
        xPrev = nil
        dxPrev = 0
    }
}

/// Typical spread of each feature, used to make filter responsiveness comparable across features.
public enum FeatureScales {
    public static let typical: [Double] = [
        0.35, // yaw
        0.25, // pitch
        0.20, // roll
        0.25, // noseX
        0.20, // noseY
        0.30, // contour
        0.12, // gazeX
        0.12, // gazeY
        0.20, // posX
        0.20, // posY
        0.02, // scale
        0.10, // eyeOpen
    ]
}

/// A bank of 1€ filters, one per feature.
public struct FeatureSmoother: Sendable {
    private var filters: [OneEuroFilter]

    public init(minCutoff: Double = 0.9, responsiveness: Double = 2.0) {
        filters = FeatureScales.typical.enumerated().map { i, scale in
            // Distance (scale) changes slowly and is noisy: smooth it much harder.
            let mc = i == 10 ? 0.25 : minCutoff
            return OneEuroFilter(minCutoff: mc, beta: responsiveness / scale, dCutoff: 1.0)
        }
    }

    public mutating func smooth(_ f: FaceFeatures, t: Double) -> FaceFeatures {
        let v = f.vector
        var out = [Double](repeating: 0, count: v.count)
        for i in 0..<v.count {
            out[i] = filters[i].filter(v[i], t: t)
        }
        return FaceFeatures(vector: out)
    }

    public mutating func reset() {
        for i in filters.indices { filters[i].reset() }
    }
}

/// Tracks how long a value has stayed the same.
public struct Dwell<Key: Equatable> {
    public private(set) var key: Key?
    public private(set) var since: Double = 0

    public init() {}

    /// Feeds the current value; returns how long it has been held (0 when it just changed or is nil).
    @discardableResult
    public mutating func update(_ k: Key?, now: Double) -> Double {
        if k != key {
            key = k
            since = now
        }
        return k == nil ? 0 : now - since
    }

    public mutating func reset() {
        key = nil
    }
}
