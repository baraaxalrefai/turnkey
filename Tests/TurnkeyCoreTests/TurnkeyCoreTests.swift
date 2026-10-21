import XCTest
import CoreGraphics
@testable import TurnkeyCore

/// Deterministic RNG so tests are repeatable.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func gaussian(_ sigma: Double) -> Double {
        let u1 = max(Double.random(in: 0..<1, using: &self), 1e-12)
        let u2 = Double.random(in: 0..<1, using: &self)
        return sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// A simulated person in front of a MacBook (camera on top of it) with a 27" monitor to the right,
/// angled towards them. Distances in millimetres.
struct SimulatedDesk {
    struct Vec { var x, y, z: Double }

    let laptopID = "laptop"
    let dellID = "dell"
    // Logical arrangement (points, y down) like the real one: MacBook left, Dell right, top-aligned.
    let laptopRect = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let dellRect = CGRect(x: 1728, y: 0, width: 1920, height: 1080)
    var head = Vec(x: 0, y: -40, z: 620)
    var rng = SplitMix64(state: 42)

    func physical(screen: String, u: Double, v: Double) -> Vec {
        if screen == laptopID {
            return Vec(x: -172 + 344 * u, y: -8 - 222 * v, z: 0)
        }
        let phi = 25.0 * .pi / 180
        return Vec(x: 230 + 602 * u * cos(phi), y: 159 - 339 * v, z: -80 + 602 * u * sin(phi))
    }

    mutating func features(lookingAt t: Vec) -> FaceFeatures {
        let d = Vec(x: t.x - head.x, y: t.y - head.y, z: t.z - head.z)
        let gazeYaw = atan2(d.x, -d.z)
        let gazePitch = atan2(d.y, (d.x * d.x + d.z * d.z).squareRoot())
        let headYaw = 0.75 * gazeYaw + rng.gaussian(0.015)
        let headPitch = 0.55 * gazePitch + rng.gaussian(0.015)
        let eyeYaw = gazeYaw - headYaw
        let eyePitch = gazePitch - headPitch
        let vYaw = headYaw + atan2(head.x, head.z)
        let vPitch = headPitch + atan2(head.y, head.z)
        return FaceFeatures(
            yaw: vYaw + rng.gaussian(0.03),
            pitch: vPitch + rng.gaussian(0.03),
            roll: rng.gaussian(0.02),
            noseX: 0.9 * sin(vYaw) + rng.gaussian(0.015),
            noseY: -0.55 + 0.75 * sin(vPitch) + rng.gaussian(0.015),
            contour: 0.8 * sin(vYaw) + rng.gaussian(0.02),
            gazeX: 0.30 * sin(eyeYaw) + rng.gaussian(0.03),
            gazeY: 0.20 * sin(eyePitch) + rng.gaussian(0.03),
            posX: 0.85 * head.x / head.z + rng.gaussian(0.002),
            posY: 0.85 * (16.0 / 9.0) * head.y / head.z + rng.gaussian(0.002),
            scale: 0.85 * 63 / head.z + rng.gaussian(0.0005),
            // The upper lid follows vertical gaze.
            eyeOpen: 0.33 + 0.22 * sin(eyePitch) + rng.gaussian(0.015)
        )
    }

    mutating func calibration() -> [CalibSample] {
        var out: [CalibSample] = []
        var group = 0
        for (id, rect, other) in [(laptopID, laptopRect, dellRect), (dellID, dellRect, laptopRect)] {
            for p in CalibrationLayout.points(for: rect, neighbours: [other]) {
                group += 1
                for _ in 0..<12 {
                    let f = features(lookingAt: physical(screen: id, u: p.u, v: p.v))
                    out.append(CalibSample(f: f, screen: id, u: p.u, v: p.v, group: group, edge: p.edge,
                                           source: .calibration, time: 0))
                }
            }
        }
        return out
    }
}

final class TurnkeyCoreTests: XCTestCase {
    func testCholeskyAndRidgeRecoverKnownLine() throws {
        // y = 2 + 3x, tiny ridge.
        let X = (0..<20).map { [1.0, Double($0) / 10] }
        let y = X.map { 2 + 3 * $0[1] }
        let beta = try XCTUnwrap(LinearModels.ridge(X: X, targets: [y], weights: Array(repeating: 1, count: 20),
                                                    penalties: [0, 1], lambda: 1e-9))
        XCTAssertEqual(beta[0][0], 2, accuracy: 1e-5)
        XCTAssertEqual(beta[0][1], 3, accuracy: 1e-5)
    }

    func testSoftmaxSeparatesTwoClusters() {
        var rng = SplitMix64(state: 7)
        var X: [[Double]] = [], labels: [Int] = []
        for i in 0..<200 {
            let c = i % 2
            X.append([1, (c == 0 ? -1.0 : 1.0) + rng.gaussian(0.3), rng.gaussian(1)])
            labels.append(c)
        }
        let W = LinearModels.softmaxFit(X: X, labels: labels, classes: 2, weights: Array(repeating: 1, count: 200),
                                        penalties: [0.001, 1, 1], lambda: 0.01)
        var correct = 0
        for (x, y) in zip(X, labels) {
            let z = W.map { LinearModels.dot($0, x) }
            if (z[1] > z[0] ? 1 : 0) == y { correct += 1 }
        }
        XCTAssertGreaterThan(Double(correct) / 200, 0.97)
    }

    func testCalibrationLayoutAddsSharedEdgeSpots() {
        let desk = SimulatedDesk()
        let laptop = CalibrationLayout.points(for: desk.laptopRect, neighbours: [desk.dellRect])
        let dell = CalibrationLayout.points(for: desk.dellRect, neighbours: [desk.laptopRect])
        XCTAssertEqual(laptop.filter(\.edge).count, 3)
        XCTAssertTrue(laptop.filter(\.edge).allSatisfy { $0.u > 0.95 })
        XCTAssertTrue(dell.filter(\.edge).allSatisfy { $0.u < 0.05 })
        XCTAssertEqual(laptop.last, CalibPoint(u: 0.5, v: 0.5, edge: false), "centre spot is recorded last")
    }

    private func trainedDesk() throws -> (SimulatedDesk, GazeModel, TrainingReport) {
        var desk = SimulatedDesk()
        let samples = desk.calibration()
        let (model, report) = try XCTUnwrap(GazeTrainer.train(samples))
        return (desk, model, report)
    }

    func testScreenClassificationAndPosition() throws {
        var (desk, model, report) = try trainedDesk()
        XCTAssertNotNil(model.classifier)
        XCTAssertGreaterThan(report.edgeHitRate ?? 0, 0.8)

        var correct = 0, total = 0
        var errU: [Double] = [], errV: [Double] = []
        for screen in [desk.laptopID, desk.dellID] {
            for _ in 0..<150 {
                var u = Double.random(in: 0.05...0.95, using: &desk.rng)
                let v = Double.random(in: 0.05...0.95, using: &desk.rng)
                // Skip a 6% band next to the shared edge: that is where hysteresis decides.
                if screen == desk.laptopID { u = min(u, 0.94) } else { u = max(u, 0.06) }
                let est = model.estimate(desk.features(lookingAt: desk.physical(screen: screen, u: u, v: v)))
                total += 1
                if est.best() == screen { correct += 1 }
                if let p = est.uv[screen] {
                    errU.append(abs(p.u - u))
                    errV.append(abs(p.v - v))
                }
            }
        }
        let accuracy = Double(correct) / Double(total)
        print("screen accuracy \(accuracy), median |du| \(Stats.median(errU)), median |dv| \(Stats.median(errV))")
        print("report: \(report)")
        XCTAssertGreaterThan(accuracy, 0.95)
        XCTAssertLessThan(Stats.median(errU), 0.10)
        XCTAssertLessThan(Stats.median(errV), 0.12)
    }

    func testSittingFartherBackStillPicksTheRightScreen() throws {
        var (desk, model, _) = try trainedDesk()
        desk.head = .init(x: 0, y: -40, z: 740) // ~12 cm farther than during calibration
        var correct = 0, total = 0
        for screen in [desk.laptopID, desk.dellID] {
            for _ in 0..<150 {
                var u = Double.random(in: 0.05...0.95, using: &desk.rng)
                let v = Double.random(in: 0.05...0.95, using: &desk.rng)
                if screen == desk.laptopID { u = min(u, 0.88) } else { u = max(u, 0.12) }
                let est = model.estimate(desk.features(lookingAt: desk.physical(screen: screen, u: u, v: v)))
                total += 1
                if est.best() == screen { correct += 1 }
            }
        }
        let accuracy = Double(correct) / Double(total)
        print("farther-back accuracy \(accuracy)")
        XCTAssertGreaterThan(accuracy, 0.93)
    }

    func testLookingDownAtTheDeskIsFarFromEveryScreen() throws {
        var (desk, model, _) = try trainedDesk()
        // A phone lying on the desk in front of the laptop.
        let est = model.estimate(desk.features(lookingAt: .init(x: 0, y: -420, z: 260)))
        let best = try XCTUnwrap(est.best())
        let uv = try XCTUnwrap(est.uv[best])
        print("desk look → \(best) uv \(uv)")
        XCTAssertGreaterThan(uv.v, 1.25)
    }

    func testOneEuroFilterSettlesOnConstantInput() {
        var f = OneEuroFilter(minCutoff: 1, beta: 0.5)
        var y = 0.0
        for i in 0..<60 { y = f.filter(1.0, t: Double(i) / 15) }
        XCTAssertEqual(y, 1.0, accuracy: 1e-6)
    }

    func testDwellTracksHoldTime() {
        var d = Dwell<String>()
        XCTAssertEqual(d.update("a", now: 0), 0)
        XCTAssertEqual(d.update("a", now: 0.4), 0.4, accuracy: 1e-9)
        XCTAssertEqual(d.update("b", now: 0.5), 0)
        XCTAssertEqual(d.update("b", now: 0.8), 0.3, accuracy: 1e-9)
    }
}

final class OutlierTests: XCTestCase {
    /// A calibration spot recorded while you were still looking at the other screen must not poison the model.
    func testSpotRecordedWhileLookingElsewhereIsDropped() throws {
        var desk = SimulatedDesk()
        var samples = desk.calibration()
        // Replace the laptop's centre spot with frames taken while looking at the middle of the Dell.
        let centre = samples.first { $0.screen == desk.laptopID && $0.u == 0.5 && $0.v == 0.5 }!.group
        let bad = desk.physical(screen: desk.dellID, u: 0.3, v: 0.5)
        for i in samples.indices where samples[i].group == centre {
            samples[i].f = desk.features(lookingAt: bad)
        }
        let (model, report) = try XCTUnwrap(GazeTrainer.train(samples))
        XCTAssertEqual(report.droppedSpots[desk.laptopID], 1)
        // Looking at the laptop's centre must clearly read as the laptop again.
        let est = model.estimate(desk.features(lookingAt: desk.physical(screen: desk.laptopID, u: 0.5, v: 0.5)))
        let margin = est.logits[desk.laptopID]! - est.logits[desk.dellID]!
        print("centre margin after dropping the bad spot: \(margin)")
        XCTAssertGreaterThan(margin, 3)
    }

    func testCleanCalibrationDropsNothing() throws {
        var desk = SimulatedDesk()
        let (_, report) = try XCTUnwrap(GazeTrainer.train(desk.calibration()))
        XCTAssertTrue(report.droppedSpots.isEmpty, "dropped \(report.droppedSpots)")
    }
}
