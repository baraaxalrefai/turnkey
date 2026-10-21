import Foundation
import TurnkeyCore

/// Owns calibration data, learned clicks and the trained gaze model.
/// Persisted only to ~/Library/Application Support/Turnkey/calibration.json (numbers, no images).
final class ModelStore {
    struct ScreenMeta: Codable, Equatable {
        var name: String
        var calibratedAt: Double
    }

    /// Bumped whenever the meaning of a stored feature changes; older calibrations are then discarded.
    static let featureVersion = 2

    private struct StoreFile: Codable {
        var version = ModelStore.featureVersion
        var calibration: [CalibSample]
        var clicks: [CalibSample]
        var screens: [String: ScreenMeta]
        var clickCounter: Int?
    }

    private let lock = NSLock()
    private var calibration: [CalibSample] = []
    private var clicks: [CalibSample] = []
    private var meta: [String: ScreenMeta] = [:]
    private var _model: GazeModel?
    private var _report: TrainingReport?
    private var outcomes: [String: [Bool]] = [:]
    private var lastDriftAlert: [String: Double] = [:]
    private var clicksSinceTrain = 0
    private var clickCounter = 0
    private var lastTrainAt = 0.0
    private var trainingScheduled = false
    private let trainQueue = DispatchQueue(label: "turnkey.train", qos: .utility)
    private let ioQueue = DispatchQueue(label: "turnkey.store.io", qos: .utility)
    private var saveScheduled = false

    static let maxClicks = 400

    /// Called on the main queue whenever the model changes.
    var onModelChanged: ((GazeModel?, TrainingReport?) -> Void)?
    /// Called on the main queue with a screen id when focus keeps missing on it.
    var onDrift: ((String) -> Void)?

    var model: GazeModel? { lock.locked { _model } }
    var report: TrainingReport? { lock.locked { _report } }
    var screenMeta: [String: ScreenMeta] { lock.locked { meta } }

    var calibratedScreenIDs: Set<String> {
        lock.locked { Set(calibration.map(\.screen)) }
    }

    func clickSampleCount(for screen: String) -> Int {
        lock.locked { clicks.filter { $0.screen == screen }.count }
    }

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Turnkey", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("calibration.json") }

    // MARK: Load / save

    func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let file = try? JSONDecoder().decode(StoreFile.self, from: data) else { return }
        guard file.version >= Self.featureVersion else {
            Diagnostics.shared.add("Calibration was made by an older version — please recalibrate")
            try? FileManager.default.removeItem(at: Self.fileURL)
            return
        }
        lock.locked {
            calibration = file.calibration
            clicks = file.clicks
            meta = file.screens
            clickCounter = file.clickCounter ?? file.clicks.count
        }
        Diagnostics.shared.add("Loaded calibration: \(file.calibration.count) samples, \(file.clicks.count) learned clicks")
        retrain(reason: "startup")
    }

    private func scheduleSave() {
        let shouldSchedule = lock.locked { () -> Bool in
            if saveScheduled { return false }
            saveScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        ioQueue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.saveNow() }
    }

    private func saveNow() {
        let file: StoreFile = lock.locked {
            saveScheduled = false
            return StoreFile(calibration: calibration, clicks: clicks, screens: meta, clickCounter: clickCounter)
        }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(file)
            try data.write(to: Self.fileURL, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
        } catch {
            Diagnostics.shared.add("Saving calibration failed: \(error.localizedDescription)")
        }
    }

    // MARK: Calibration

    /// Replaces calibration for the given screens (others are kept) and retrains.
    func replaceCalibration(screens ids: [String], names: [String: String], samples: [CalibSample],
                            completion: @escaping (TrainingReport?) -> Void) {
        let idSet = Set(ids)
        lock.locked {
            calibration.removeAll { idSet.contains($0.screen) }
            // Group ids must stay unique across screens.
            let offset = (calibration.map(\.group).max() ?? 0) + 1
            calibration += samples.map { s in
                var s = s
                s.group += offset
                return s
            }
            // Old learned clicks on a recalibrated screen describe the old setup.
            clicks.removeAll { idSet.contains($0.screen) }
            for id in ids {
                meta[id] = ScreenMeta(name: names[id] ?? id, calibratedAt: Date().timeIntervalSince1970)
                outcomes[id] = []
            }
        }
        scheduleSave()
        retrain(reason: "calibration") { report in completion(report) }
    }

    func resetLearned() {
        lock.locked {
            clicks.removeAll()
            outcomes.removeAll()
        }
        scheduleSave()
        retrain(reason: "learned clicks reset")
    }

    func deleteAll() {
        lock.locked {
            calibration.removeAll()
            clicks.removeAll()
            meta.removeAll()
            outcomes.removeAll()
            _model = nil
            _report = nil
        }
        try? FileManager.default.removeItem(at: Self.fileURL)
        Diagnostics.shared.add("Deleted all calibration data")
        DispatchQueue.main.async { self.onModelChanged?(nil, nil) }
    }

    func forgetScreen(_ id: String) {
        lock.locked {
            calibration.removeAll { $0.screen == id }
            clicks.removeAll { $0.screen == id }
            meta[id] = nil
        }
        scheduleSave()
        retrain(reason: "screen removed")
    }

    // MARK: Training

    private func retrain(reason: String, completion: ((TrainingReport?) -> Void)? = nil) {
        let samples = lock.locked { calibration + clicks }
        trainQueue.async { [weak self] in
            guard let self else { return }
            let start = uptime()
            let result = GazeTrainer.train(samples)
            self.lock.locked {
                self._model = result?.0
                self._report = result?.1
                self.lastTrainAt = uptime()
                self.clicksSinceTrain = 0
                self.trainingScheduled = false
            }
            let ms = Int((uptime() - start) * 1000)
            if let report = result?.1 {
                let summary = report.screens.map { s in
                    "\(self.screenMeta[s.screen]?.name ?? s.screen): ±\(Int(s.sigmaU * 100))%×±\(Int(s.sigmaV * 100))%"
                }.joined(separator: ", ")
                Diagnostics.shared.add("Model trained (\(reason), \(samples.count) samples, \(ms) ms) — \(summary)")
            }
            DispatchQueue.main.async {
                self.onModelChanged?(result?.0, result?.1)
                completion?(result?.1)
            }
        }
    }

    // MARK: Learning from clicks + drift detection

    /// You look where you click. Clicks on the screen you're facing refine the model; clicks that the
    /// model would have put on another screen count as misses, and too many misses suggest recalibrating.
    func recordClick(features: FaceFeatures, screen: String, u: Double, v: Double, learn: Bool) {
        guard let model = self.model, model.regressors[screen] != nil else { return }
        let estimate = model.estimate(features)
        guard let predicted = estimate.best(), let puv = estimate.uv[predicted] else { return }
        // Clearly looking somewhere else entirely (e.g. down at the trackpad): no information.
        if puv.u < -0.6 || puv.u > 1.6 || puv.v < -0.6 || puv.v > 1.6 { return }

        var hit = predicted == screen
        if model.regressors.count == 1, let p = estimate.uv[screen] {
            hit = hypot(p.u - u, p.v - v) < 0.35
        }

        var shouldTrain = false
        var drift = false
        lock.locked {
            var list = outcomes[screen] ?? []
            list.append(hit)
            if list.count > 20 { list.removeFirst(list.count - 20) }
            outcomes[screen] = list
            let misses = list.filter { !$0 }.count
            let now = uptime()
            if list.count >= 12, Double(misses) / Double(list.count) >= 0.45,
               now - (lastDriftAlert[screen] ?? -1e9) > 3 * 3600 {
                lastDriftAlert[screen] = now
                outcomes[screen] = []
                drift = true
            }
            if hit && learn {
                clickCounter += 1
                clicks.append(CalibSample(f: features, screen: screen, u: u, v: v,
                                          group: 1_000_000 + clickCounter / 8, edge: false,
                                          source: .click, time: Date().timeIntervalSince1970))
                if clicks.count > Self.maxClicks { clicks.removeFirst(clicks.count - Self.maxClicks) }
                clicksSinceTrain += 1
                if !trainingScheduled, clicksSinceTrain >= 15 || (clicksSinceTrain > 0 && now - lastTrainAt > 120) {
                    trainingScheduled = true
                    shouldTrain = true
                }
            }
        }
        if drift {
            Diagnostics.shared.add("Focus keeps missing on \(screenMeta[screen]?.name ?? screen) — suggesting recalibration")
            DispatchQueue.main.async { self.onDrift?(screen) }
        }
        if hit && learn { scheduleSave() }
        if shouldTrain { retrain(reason: "learned from clicks") }
    }
}
