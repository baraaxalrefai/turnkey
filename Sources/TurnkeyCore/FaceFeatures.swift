import Foundation

/// Numbers measured from one camera frame. This is the only thing that survives a frame:
/// the image itself is never copied, kept or written anywhere.
public struct FaceFeatures: Codable, Equatable, Sendable {
    /// Head yaw / pitch reported by Apple's Vision framework (radians).
    public var yaw: Double
    public var pitch: Double
    /// Head roll measured from the eye line (radians).
    public var roll: Double
    /// Nose position relative to the midpoint between the eyes, in inter-ocular units (roll removed).
    public var noseX: Double
    public var noseY: Double
    /// Left/right asymmetry of the jaw contour around the eye midpoint (−1…1).
    public var contour: Double
    /// Pupil offset in eye widths: horizontally from the centre of the eye, vertically from the line
    /// between the eye corners.
    public var gazeX: Double
    public var gazeY: Double
    /// Eye-midpoint position in the image (−0.5…0.5, x to the right, y up).
    public var posX: Double
    public var posY: Double
    /// Inter-ocular distance as a fraction of image width (bigger = closer to the camera).
    public var scale: Double
    /// Eye opening (height / width). Small values mean a blink.
    public var eyeOpen: Double

    public init(yaw: Double = 0, pitch: Double = 0, roll: Double = 0,
                noseX: Double = 0, noseY: Double = 0, contour: Double = 0,
                gazeX: Double = 0, gazeY: Double = 0,
                posX: Double = 0, posY: Double = 0, scale: Double = 0.1, eyeOpen: Double = 0.35) {
        self.yaw = yaw; self.pitch = pitch; self.roll = roll
        self.noseX = noseX; self.noseY = noseY; self.contour = contour
        self.gazeX = gazeX; self.gazeY = gazeY
        self.posX = posX; self.posY = posY
        self.scale = scale; self.eyeOpen = eyeOpen
    }

    public static let dimension = 12

    public var vector: [Double] {
        [yaw, pitch, roll, noseX, noseY, contour, gazeX, gazeY, posX, posY, scale, eyeOpen]
    }

    public init(vector v: [Double]) {
        precondition(v.count == FaceFeatures.dimension, "FaceFeatures vector must have \(FaceFeatures.dimension) values")
        self.init(yaw: v[0], pitch: v[1], roll: v[2], noseX: v[3], noseY: v[4], contour: v[5],
                  gazeX: v[6], gazeY: v[7], posX: v[8], posY: v[9], scale: v[10], eyeOpen: v[11])
    }

    public static func mean(_ items: [FaceFeatures]) -> FaceFeatures? {
        guard !items.isEmpty else { return nil }
        var acc = [Double](repeating: 0, count: dimension)
        for f in items {
            for (i, x) in f.vector.enumerated() { acc[i] += x }
        }
        return FaceFeatures(vector: acc.map { $0 / Double(items.count) })
    }

    public static func median(_ items: [FaceFeatures]) -> FaceFeatures? {
        guard !items.isEmpty else { return nil }
        let vs = items.map(\.vector)
        return FaceFeatures(vector: (0..<dimension).map { i in Stats.median(vs.map { $0[i] }) })
    }
}

public enum Stats {
    public static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : 0.5 * (s[n / 2 - 1] + s[n / 2])
    }

    public static func mean(_ xs: [Double]) -> Double {
        xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count)
    }

    public static func rms(_ xs: [Double]) -> Double {
        xs.isEmpty ? 0 : (xs.reduce(0) { $0 + $1 * $1 } / Double(xs.count)).squareRoot()
    }

    /// Median absolute deviation (unscaled).
    public static func mad(_ xs: [Double]) -> Double {
        let m = median(xs)
        return median(xs.map { abs($0 - m) })
    }
}
