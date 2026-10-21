import AVFoundation
import CoreMedia
import Foundation

/// Runs the camera at 720p and at most 15 frames a second. Each frame is handed to the face tracker
/// synchronously and released as soon as the callback returns: frames are never copied, queued, saved
/// or sent anywhere.
final class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "turnkey.camera.session")
    private let videoQueue = DispatchQueue(label: "turnkey.camera.frames", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    private var outputAdded = false
    private let tracker = FaceTracker()

    /// Called on the frame queue with the result of each analysed frame.
    var onResult: ((FaceTracker.Result, Double) -> Void)?
    /// Called on the main queue when the camera starts/stops or fails.
    var onStatus: ((_ running: Bool, _ deviceName: String?, _ error: String?) -> Void)?

    private let lock = NSLock()
    private var lastProcessed = 0.0
    private var lastFace = 0.0
    private var _framesAnalysed = 0
    var framesAnalysed: Int { lock.locked { _framesAnalysed } }

    var wantsLandmarks: Bool {
        get { tracker.wantsLandmarks }
        set { tracker.wantsLandmarks = newValue }
    }

    static let maxFPS = 15.0
    /// When nobody has been in front of the camera for a while, analyse fewer frames.
    static let idleFPS = 4.0
    private var _fps = 10.0
    /// Frames analysed per second (≤ 15): 10 is plenty for screens; windows/panes use 15.
    var fps: Double {
        get { lock.locked { _fps } }
        set {
            let v = min(max(newValue, 5), Self.maxFPS)
            let changed = lock.locked { () -> Bool in
                defer { _fps = v }
                return _fps != v
            }
            if changed {
                sessionQueue.async { [self] in
                    if session.isRunning, let device = input?.device { limitFrameRate(device) }
                }
            }
        }
    }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
            let err = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "Camera error"
            Diagnostics.shared.add("Camera runtime error: \(err)")
            self?.onStatus?(false, nil, err)
        }
        NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let dev = note.object as? AVCaptureDevice else { return }
            self.sessionQueue.async {
                if self.input?.device.uniqueID == dev.uniqueID {
                    Diagnostics.shared.add("Camera disconnected: \(dev.localizedName)")
                    self.session.beginConfiguration()
                    if let input = self.input { self.session.removeInput(input) }
                    self.input = nil
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { self.onStatus?(false, nil, "Camera disconnected") }
                }
            }
        }
    }

    static func cameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    /// The camera you picked, else a plugged-in external one, else the built-in one.
    static func pick(preferred: String?) -> AVCaptureDevice? {
        let all = cameras()
        if let id = preferred, let d = all.first(where: { $0.uniqueID == id }) { return d }
        return all.first(where: { $0.deviceType == .external })
            ?? all.first(where: { $0.deviceType == .builtInWideAngleCamera })
            ?? all.first
    }

    func start(deviceID: String?) {
        sessionQueue.async { [self] in
            guard let device = Self.pick(preferred: deviceID) else {
                DispatchQueue.main.async { self.onStatus?(false, nil, "No camera found") }
                return
            }
            if input?.device.uniqueID != device.uniqueID {
                configure(device)
            }
            if !session.isRunning {
                session.startRunning()
                Diagnostics.shared.add("Camera on: \(device.localizedName)")
            }
            limitFrameRate(device)
            let running = session.isRunning
            DispatchQueue.main.async { self.onStatus?(running, device.localizedName, running ? nil : "Camera didn't start") }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            guard session.isRunning else { return }
            session.stopRunning()
            Diagnostics.shared.add("Camera off")
            DispatchQueue.main.async { self.onStatus?(false, nil, nil) }
        }
    }

    private func configure(_ device: AVCaptureDevice) {
        // Center Stage keeps re-framing the picture to follow you, which would make head position and
        // distance meaningless. Take control of it for this app and keep it off.
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = false
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if let input { session.removeInput(input) }
        input = nil
        do {
            let newInput = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                input = newInput
            }
        } catch {
            Diagnostics.shared.add("Camera input failed: \(error.localizedDescription)")
        }
        if !outputAdded {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(output) {
                session.addOutput(output)
                outputAdded = true
            }
        }
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        }
    }

    /// Ask the camera itself for ≤ 15 fps (frames are also dropped in software below, as a guarantee).
    private func limitFrameRate(_ device: AVCaptureDevice) {
        let fps = self.fps
        let ok = device.activeFormat.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }
        guard ok else { return }
        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.unlockForConfiguration()
        } catch {
            Diagnostics.shared.add("Couldn't set camera frame rate: \(error.localizedDescription)")
        }
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = uptime()
        let (idle, fps) = lock.locked { (now - lastFace > 5, _fps) }
        let interval = 1.0 / (idle ? Self.idleFPS : fps) - 0.004
        guard lock.locked({ now - lastProcessed >= interval }) else { return }
        lock.locked { lastProcessed = now }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Analysed in place; nothing keeps a reference to the pixel buffer after this call.
        let result = tracker.analyze(pixelBuffer)
        lock.locked {
            _framesAnalysed += 1
            if result.features != nil { lastFace = now }
        }
        onResult?(result, now)
    }
}
