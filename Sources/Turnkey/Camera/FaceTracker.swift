import CoreVideo
import Foundation
import TurnkeyCore
import Vision

/// On-device face analysis with Apple's Vision framework: head pose + landmarks → `FaceFeatures`.
final class FaceTracker {
    struct Result {
        var features: FaceFeatures?
        /// Landmark dots (0…1, y up) for the settings preview. Only filled while the preview is open.
        var landmarks: [CGPoint] = []
        var faces = 0
    }

    private let rectRequest = VNDetectFaceRectanglesRequest()
    private let landmarkRequest = VNDetectFaceLandmarksRequest()
    private let lock = NSLock()
    private var _wantsLandmarks = false

    var wantsLandmarks: Bool {
        get { lock.locked { _wantsLandmarks } }
        set { lock.locked { _wantsLandmarks = newValue } }
    }

    init() {
        // Revision 3 reports continuous yaw/pitch/roll and the 76-point landmark set with pupils.
        if VNDetectFaceRectanglesRequest.supportedRevisions.contains(VNDetectFaceRectanglesRequestRevision3) {
            rectRequest.revision = VNDetectFaceRectanglesRequestRevision3
        }
        if VNDetectFaceLandmarksRequest.supportedRevisions.contains(VNDetectFaceLandmarksRequestRevision3) {
            landmarkRequest.revision = VNDetectFaceLandmarksRequestRevision3
        }
    }

    func analyze(_ pixelBuffer: CVPixelBuffer) -> Result {
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([rectRequest])
        } catch {
            return Result()
        }
        guard let faces = rectRequest.results, !faces.isEmpty else { return Result() }
        // The person at the desk is the biggest face in view.
        let face = faces.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }!
        landmarkRequest.inputFaceObservations = [face]
        do {
            try handler.perform([landmarkRequest])
        } catch {
            return Result(faces: faces.count)
        }
        guard let obs = landmarkRequest.results?.first, let lm = obs.landmarks,
              let leftEye = lm.leftEye, let rightEye = lm.rightEye else {
            return Result(faces: faces.count)
        }
        let nose = (lm.nose ?? lm.noseCrest)?.pointsInImage(imageSize: size) ?? []
        let pupils = [lm.leftPupil, lm.rightPupil].compactMap { $0?.pointsInImage(imageSize: size).first }
        let contour = lm.faceContour?.pointsInImage(imageSize: size) ?? []
        let yaw = (face.yaw ?? obs.yaw)?.doubleValue ?? 0
        let pitch = (face.pitch ?? obs.pitch)?.doubleValue ?? 0
        let features = LandmarkGeometry.features(
            eyeA: leftEye.pointsInImage(imageSize: size),
            eyeB: rightEye.pointsInImage(imageSize: size),
            pupils: pupils,
            nose: nose,
            contour: contour,
            imageSize: size,
            visionYaw: yaw,
            visionPitch: pitch
        )
        var result = Result(features: features, faces: faces.count)
        if wantsLandmarks, let all = lm.allPoints {
            result.landmarks = all.pointsInImage(imageSize: size).map {
                CGPoint(x: $0.x / size.width, y: $0.y / size.height)
            }
        }
        return result
    }
}
