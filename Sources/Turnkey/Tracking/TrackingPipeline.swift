import Foundation
import TurnkeyCore

struct TrackedFrame {
    var time: Double
    var faceFound: Bool
    /// Smoothed features (nil when no face).
    var features: FaceFeatures?
    /// Model output (nil when no face or not calibrated yet).
    var estimate: GazeEstimate?
}

/// Smooths per-frame features, runs the gaze model and keeps ~3 s of history for click learning.
/// Only numbers are kept — never images.
final class TrackingPipeline {
    private let models: ModelStore
    private let lock = NSLock()
    private var smoother = FeatureSmoother()
    private var history: [(t: Double, f: FaceFeatures)] = []
    private var lastFaceTime = -100.0
    private var lastSmoothed: FaceFeatures?

    /// Every frame, on the camera queue (consumed by the focus engine).
    var onFrame: ((TrackedFrame) -> Void)?
    /// Raw (unsmoothed) features, on the camera queue (consumed by calibration).
    var onRaw: ((FaceFeatures?, Double) -> Void)?
    /// Landmark dots for the preview, on the camera queue.
    var onPreview: (([CGPoint]) -> Void)?

    init(models: ModelStore) {
        self.models = models
    }

    func process(_ r: FaceTracker.Result, time: Double) {
        onRaw?(r.features, time)
        if !r.landmarks.isEmpty || r.features == nil { onPreview?(r.landmarks) }

        guard var f = r.features else {
            lock.locked {
                if time - lastFaceTime > 0.6 {
                    smoother.reset()
                    lastSmoothed = nil
                }
            }
            onFrame?(TrackedFrame(time: time, faceFound: false, features: nil, estimate: nil))
            return
        }

        let smoothed: FaceFeatures = lock.locked {
            // During a blink the pupils are meaningless: hold the previous eye position.
            if f.eyeOpen < 0.15, let prev = lastSmoothed {
                f.gazeX = prev.gazeX
                f.gazeY = prev.gazeY
                f.eyeOpen = prev.eyeOpen
            }
            let s = smoother.smooth(f, t: time)
            lastSmoothed = s
            lastFaceTime = time
            history.append((time, s))
            if let first = history.first, time - first.t > 3 {
                history.removeAll { time - $0.t > 3 }
            }
            return s
        }
        let estimate = models.model?.estimate(smoothed)
        onFrame?(TrackedFrame(time: time, faceFound: true, features: smoothed, estimate: estimate))
    }

    /// Average smoothed features over a time window (used for "you look where you click").
    func averageFeatures(from t0: Double, to t1: Double) -> FaceFeatures? {
        let items = lock.locked { history.filter { $0.t >= t0 && $0.t <= t1 }.map(\.f) }
        guard items.count >= 2 else { return nil }
        return FaceFeatures.mean(items)
    }

    func reset() {
        lock.locked {
            smoother.reset()
            history.removeAll()
            lastSmoothed = nil
        }
    }
}
