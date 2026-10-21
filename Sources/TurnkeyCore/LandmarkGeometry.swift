import Foundation
import CoreGraphics

/// Turns face landmark points into `FaceFeatures`.
/// Points are in image pixel coordinates with the origin at the bottom-left (Vision's convention).
public enum LandmarkGeometry {
    public static func features(
        eyeA: [CGPoint],
        eyeB: [CGPoint],
        pupils: [CGPoint],
        nose: [CGPoint],
        contour: [CGPoint],
        imageSize: CGSize,
        visionYaw: Double,
        visionPitch: Double
    ) -> FaceFeatures? {
        guard eyeA.count >= 3, eyeB.count >= 3, !nose.isEmpty,
              imageSize.width > 0, imageSize.height > 0 else { return nil }

        // Order the eyes left → right in the image so roll is always in (−π/2, π/2).
        var ptsA = eyeA, ptsB = eyeB
        var cA = centroid(ptsA), cB = centroid(ptsB)
        if cA.x > cB.x {
            swap(&ptsA, &ptsB)
            swap(&cA, &cB)
        }
        let midX = Double(cA.x + cB.x) / 2
        let midY = Double(cA.y + cB.y) / 2
        let dx = Double(cB.x - cA.x), dy = Double(cB.y - cA.y)
        let iod = (dx * dx + dy * dy).squareRoot()
        guard iod > 4 else { return nil }

        // Remove head roll so that tilting your head sideways doesn't look like turning it.
        let roll = atan2(dy, dx)
        let c = cos(-roll), s = sin(-roll)
        func local(_ p: CGPoint) -> (x: Double, y: Double) {
            let x = Double(p.x) - midX, y = Double(p.y) - midY
            return (x * c - y * s, x * s + y * c)
        }

        let noseL = nose.map(local)
        let noseX = noseL.reduce(0) { $0 + $1.x } / Double(noseL.count) / iod
        let noseY = noseL.reduce(0) { $0 + $1.y } / Double(noseL.count) / iod

        var contourAsym = 0.0
        if contour.count >= 3 {
            let xs = contour.map { local($0).x }
            if let lo = xs.min(), let hi = xs.max(), hi - lo > 1 {
                contourAsym = ((0 - lo) - (hi - 0)) / (hi - lo)
            }
        }

        // Pupil offset inside each eye, weighted by eye width (the eye facing the camera is more reliable).
        let pupilsL = pupils.map(local)
        var sumX = 0.0, sumY = 0.0, sumW = 0.0
        var openSum = 0.0, openW = 0.0
        for eye in [ptsA, ptsB] {
            let pts = eye.map(local)
            guard let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(),
                  let minY = pts.map(\.y).min(), let maxY = pts.map(\.y).max() else { continue }
            let w = maxX - minX
            guard w > 1 else { continue }
            let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
            // Eye corners: the outermost contour points. Unlike the lids, they don't move when you
            // look up or down, so they are the reference for vertical pupil position.
            let inner = pts.min { $0.x < $1.x }!, outer = pts.max { $0.x < $1.x }!
            let cornerY = (inner.y + outer.y) / 2
            openSum += maxY - minY
            openW += w
            func dist(_ p: (x: Double, y: Double)) -> Double { hypot(p.x - cx, p.y - cy) }
            guard let p = pupilsL.min(by: { dist($0) < dist($1) }), dist(p) < w else { continue }
            sumX += p.x - cx
            sumY += p.y - cornerY
            sumW += w
        }
        let gazeX = sumW > 0 ? sumX / sumW : 0
        let gazeY = sumW > 0 ? sumY / sumW : 0
        let eyeOpen = openW > 0 ? openSum / openW : 0.35

        return FaceFeatures(
            yaw: visionYaw,
            pitch: visionPitch,
            roll: roll,
            noseX: noseX,
            noseY: noseY,
            contour: contourAsym,
            gazeX: gazeX,
            gazeY: gazeY,
            posX: midX / Double(imageSize.width) - 0.5,
            posY: midY / Double(imageSize.height) - 0.5,
            scale: iod / Double(imageSize.width),
            eyeOpen: eyeOpen
        )
    }

    static func centroid(_ pts: [CGPoint]) -> CGPoint {
        guard !pts.isEmpty else { return .zero }
        var x: CGFloat = 0, y: CGFloat = 0
        for p in pts { x += p.x; y += p.y }
        return CGPoint(x: x / CGFloat(pts.count), y: y / CGFloat(pts.count))
    }
}
