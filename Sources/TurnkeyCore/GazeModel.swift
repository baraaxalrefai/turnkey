import Foundation

public struct UV: Codable, Equatable, Sendable {
    public var u: Double
    public var v: Double
    public init(u: Double, v: Double) {
        self.u = u
        self.v = v
    }
}

/// One training example: what the face looked like while looking at (u, v) on a screen.
/// u/v are 0…1 from the screen's top-left corner.
public struct CalibSample: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case calibration, click }

    public var f: FaceFeatures
    public var screen: String
    public var u: Double
    public var v: Double
    /// Calibration point id (frames of the same dot share a group); click chunks for learned samples.
    public var group: Int
    /// True for the extra spots along an edge shared with another screen.
    public var edge: Bool
    public var source: Source
    /// Seconds since 1970.
    public var time: Double

    public init(f: FaceFeatures, screen: String, u: Double, v: Double, group: Int, edge: Bool, source: Source, time: Double) {
        self.f = f
        self.screen = screen
        self.u = u
        self.v = v
        self.group = group
        self.edge = edge
        self.source = source
        self.time = time
    }
}

/// Centres features on where you usually sit/look, and remembers your usual distance.
public struct FeatureNormalizer: Codable, Equatable, Sendable {
    public var mean: [Double]
    public var scale0: Double

    public init(mean: [Double], scale0: Double) {
        self.mean = mean
        self.scale0 = scale0
    }

    public static func fit(_ items: [FaceFeatures]) -> FeatureNormalizer {
        let m = FaceFeatures.mean(items)?.vector ?? [Double](repeating: 0, count: FaceFeatures.dimension)
        let s0 = Stats.median(items.map(\.scale))
        return FeatureNormalizer(mean: m, scale0: s0 > 0 ? s0 : 0.1)
    }
}

/// The model input. Angle-like features are multiplied by your relative distance (z), because the same
/// head turn covers more screen when you sit farther back — that is the automatic distance compensation.
public enum Design {
    public static let size = 12
    /// Relative ridge penalties: light on head pose, heavier on eyes and head position (which
    /// barely vary during calibration and must not be over-trusted).
    public static let penalties: [Double] = [0.001, 1, 1, 1, 1, 1, 2, 2, 8, 8, 8, 2]

    public static func relativeDistance(_ f: FaceFeatures, _ n: FeatureNormalizer) -> Double {
        min(max(n.scale0 / max(f.scale, 1e-4), 0.6), 1.7)
    }

    public static func vector(_ f: FaceFeatures, _ n: FeatureNormalizer) -> [Double] {
        let z = relativeDistance(f, n)
        let m = n.mean
        return [
            1,
            z * (f.yaw - m[0]) / 0.35,
            z * (f.pitch - m[1]) / 0.25,
            z * (f.noseX - m[3]) / 0.25,
            z * (f.noseY - m[4]) / 0.20,
            z * (f.contour - m[5]) / 0.30,
            z * (f.gazeX - m[6]) / 0.12,
            z * (f.gazeY - m[7]) / 0.12,
            z * (f.posX - m[8]) / 0.20,
            z * (f.posY - m[9]) / 0.20,
            (z - 1) / 0.25,
            // Upper lid follows vertical gaze: a strong up/down cue when the head barely moves.
            (f.eyeOpen - m[11]) / 0.08,
        ]
    }
}

/// Maps features → position on one screen.
public struct ScreenRegressor: Codable, Equatable, Sendable {
    public var screen: String
    public var wu: [Double]
    public var wv: [Double]
    /// Expected error, as a fraction of the screen's width / height.
    public var sigmaU: Double
    public var sigmaV: Double
    public var sampleCount: Int
    public var clickCount: Int

    public func predict(_ x: [Double]) -> UV {
        UV(u: LinearModels.dot(wu, x), v: LinearModels.dot(wv, x))
    }
}

/// Decides which screen you face. Logits are scaled so that ~2.5 units ≈ the edge calibration spots,
/// which makes the "edge stickiness" (hysteresis) setting mean roughly the same thing on any setup.
public struct ScreenClassifier: Codable, Equatable, Sendable {
    public var screens: [String]
    public var weights: [[Double]]
    public var temperature: Double

    public func logits(_ x: [Double]) -> [Double] {
        weights.map { LinearModels.dot($0, x) * temperature }
    }
}

public struct GazeEstimate: Equatable, Sendable {
    public var logits: [String: Double]
    public var uv: [String: UV]

    public init(logits: [String: Double], uv: [String: UV]) {
        self.logits = logits
        self.uv = uv
    }

    public func best(bias: [String: Double] = [:], allowed: Set<String>? = nil) -> String? {
        logits
            .filter { allowed?.contains($0.key) ?? true }
            .max { ($0.value + (bias[$0.key] ?? 0)) < ($1.value + (bias[$1.key] ?? 0)) }?
            .key
    }
}

public struct GazeModel: Codable, Equatable, Sendable {
    public var normalizer: FeatureNormalizer
    public var regressors: [String: ScreenRegressor]
    public var classifier: ScreenClassifier?

    public var screens: [String] { regressors.keys.sorted() }

    public func estimate(_ f: FaceFeatures) -> GazeEstimate {
        let x = Design.vector(f, normalizer)
        var uv: [String: UV] = [:]
        for (id, r) in regressors { uv[id] = r.predict(x) }
        var logits: [String: Double] = [:]
        if let c = classifier {
            for (k, z) in c.logits(x).enumerated() where regressors[c.screens[k]] != nil {
                logits[c.screens[k]] = z
            }
        } else {
            for id in regressors.keys { logits[id] = 0 }
        }
        return GazeEstimate(logits: logits, uv: uv)
    }
}

public struct ScreenReport: Codable, Equatable, Sendable {
    public var screen: String
    public var samples: Int
    public var clickSamples: Int
    public var sigmaU: Double
    public var sigmaV: Double
    /// Share of this screen's calibration frames the screen classifier gets right.
    public var hitRate: Double?
}

public struct TrainingReport: Codable, Equatable, Sendable {
    public var screens: [ScreenReport]
    public var edgeHitRate: Double?
    public var temperature: Double?
    /// Calibration spots ignored because you clearly weren't looking at the dot (per screen id).
    public var droppedSpots: [String: Int] = [:]

    public func screen(_ id: String) -> ScreenReport? { screens.first { $0.screen == id } }
}

public enum GazeTrainer {
    public struct Options: Sendable {
        public var ridgeLambda = 1e-3
        public var softmaxLambda = 0.01
        /// A learned click counts this much more than a single calibration frame…
        public var clickWeight = 2.0
        /// …halving for every this-many newer clicks, so the model follows how you sit today.
        public var clickHalfLife = 150.0
        /// Target logit margin at the edge calibration spots.
        public var edgeMargin = 2.5
        public var minSamplesPerScreen = 12
        public init() {}
    }

    public static func train(_ allSamples: [CalibSample], options: Options = Options()) -> (GazeModel, TrainingReport)? {
        let (outliers, dropped) = outlierGroups(allSamples, options: options)
        let samples = outliers.isEmpty ? allSamples : allSamples.filter { !outliers.contains($0.group) }
        let calib = samples.filter { $0.source == .calibration }
        guard calib.count >= options.minSamplesPerScreen else { return nil }
        let norm = FeatureNormalizer.fit(calib.map(\.f))
        let X = samples.map { Design.vector($0.f, norm) }
        let w = weights(for: samples, options)

        var regressors: [String: ScreenRegressor] = [:]
        var reports: [String: ScreenReport] = [:]
        for id in Set(samples.map(\.screen)).sorted() {
            let idx = samples.indices.filter { samples[$0].screen == id }
            guard idx.count >= options.minSamplesPerScreen,
                  idx.contains(where: { samples[$0].source == .calibration }) else { continue }
            let xs = idx.map { X[$0] }
            let us = idx.map { samples[$0].u }
            let vs = idx.map { samples[$0].v }
            let ws = idx.map { w[$0] }
            guard let beta = LinearModels.ridge(X: xs, targets: [us, vs], weights: ws,
                                                penalties: Design.penalties, lambda: options.ridgeLambda) else { continue }
            let (su, sv) = crossValidatedSigma(X: xs, u: us, v: vs, w: ws,
                                               groups: idx.map { samples[$0].group }, lambda: options.ridgeLambda)
            let clicks = idx.filter { samples[$0].source == .click }.count
            regressors[id] = ScreenRegressor(screen: id, wu: beta[0], wv: beta[1], sigmaU: su, sigmaV: sv,
                                             sampleCount: idx.count, clickCount: clicks)
            reports[id] = ScreenReport(screen: id, samples: idx.count, clickSamples: clicks,
                                       sigmaU: su, sigmaV: sv, hitRate: nil)
        }
        guard !regressors.isEmpty else { return nil }

        let ids = regressors.keys.sorted()
        var classifier: ScreenClassifier?
        var edgeHitRate: Double?
        if ids.count >= 2 {
            let idx = samples.indices.filter { regressors[samples[$0].screen] != nil }
            let labels = idx.map { ids.firstIndex(of: samples[$0].screen)! }
            let K = ids.count
            // Balance classes so a screen with more samples doesn't pull the boundary its way.
            var totals = [Double](repeating: 0, count: K)
            for (j, i) in idx.enumerated() { totals[labels[j]] += w[i] }
            let total = totals.reduce(0, +)
            let cw = idx.enumerated().map { j, i in w[i] * total / (Double(K) * max(totals[labels[j]], 1e-9)) }
            let xc = idx.map { X[$0] }
            let W = LinearModels.softmaxFit(X: xc, labels: labels, classes: K, weights: cw,
                                            penalties: Design.penalties, lambda: options.softmaxLambda)

            var edgeMargins: [Double] = [], allMargins: [Double] = []
            var hits = [Int](repeating: 0, count: K), counts = [Int](repeating: 0, count: K)
            var edgeHits = 0, edgeCount = 0
            for (j, i) in idx.enumerated() where samples[i].source == .calibration {
                let z = W.map { LinearModels.dot($0, xc[j]) }
                let y = labels[j]
                let other = z.enumerated().filter { $0.offset != y }.map(\.element).max() ?? 0
                let m = z[y] - other
                allMargins.append(m)
                counts[y] += 1
                if m > 0 { hits[y] += 1 }
                if samples[i].edge {
                    edgeMargins.append(m)
                    edgeCount += 1
                    if m > 0 { edgeHits += 1 }
                }
            }
            var T = 1.0
            if edgeMargins.count >= 6 {
                T = options.edgeMargin / max(Stats.median(edgeMargins), 0.1)
            } else if !allMargins.isEmpty {
                T = 12 * options.edgeMargin / max(Stats.median(allMargins), 0.1)
            }
            T = min(max(T, 0.02), 25)
            classifier = ScreenClassifier(screens: ids, weights: W, temperature: T)
            for (k, id) in ids.enumerated() where counts[k] > 0 {
                reports[id]?.hitRate = Double(hits[k]) / Double(counts[k])
            }
            if edgeCount > 0 { edgeHitRate = Double(edgeHits) / Double(edgeCount) }
        }

        let model = GazeModel(normalizer: norm, regressors: regressors, classifier: classifier)
        let report = TrainingReport(screens: ids.compactMap { reports[$0] }, edgeHitRate: edgeHitRate,
                                    temperature: classifier?.temperature, droppedSpots: dropped)
        return (model, report)
    }

    /// Calibration spots that disagree with all their neighbours (you looked away, or were still turning
    /// towards the screen). Each spot is predicted by a model fitted without it; a spot whose error is far
    /// beyond the others' is dropped. At most a fifth of a screen's spots can be dropped.
    static func outlierGroups(_ samples: [CalibSample], options: Options) -> (Set<Int>, [String: Int]) {
        let calib = samples.filter { $0.source == .calibration }
        guard calib.count >= options.minSamplesPerScreen else { return ([], [:]) }
        let norm = FeatureNormalizer.fit(calib.map(\.f))
        var drop = Set<Int>()
        var counts: [String: Int] = [:]
        for id in Set(calib.map(\.screen)).sorted() {
            let idx = calib.indices.filter { calib[$0].screen == id }
            let groups = Array(Set(idx.map { calib[$0].group })).sorted()
            guard groups.count >= 8 else { continue }
            let X = idx.map { Design.vector(calib[$0].f, norm) }
            var residuals: [(group: Int, du: Double, dv: Double)] = []
            for g in groups {
                let train = idx.indices.filter { calib[idx[$0]].group != g }
                let test = idx.indices.filter { calib[idx[$0]].group == g }
                guard let beta = LinearModels.ridge(X: train.map { X[$0] },
                                                    targets: [train.map { calib[idx[$0]].u }, train.map { calib[idx[$0]].v }],
                                                    weights: Array(repeating: 1, count: train.count),
                                                    penalties: Design.penalties, lambda: options.ridgeLambda) else { continue }
                let pu = Stats.median(test.map { LinearModels.dot(beta[0], X[$0]) })
                let pv = Stats.median(test.map { LinearModels.dot(beta[1], X[$0]) })
                let t = calib[idx[test[0]]]
                residuals.append((g, abs(pu - t.u), abs(pv - t.v)))
            }
            guard residuals.count >= 8 else { continue }
            let typicalU = Stats.median(residuals.map(\.du)), typicalV = Stats.median(residuals.map(\.dv))
            let limitU = max(0.25, 4 * typicalU), limitV = max(0.40, 4 * typicalV)
            let bad = residuals
                .filter { $0.du > limitU || $0.dv > limitV }
                .sorted { max($0.du / limitU, $0.dv / limitV) > max($1.du / limitU, $1.dv / limitV) }
                .prefix(groups.count / 5)
            for r in bad { drop.insert(r.group) }
            if !bad.isEmpty { counts[id] = bad.count }
        }
        return (drop, counts)
    }

    static func weights(for samples: [CalibSample], _ o: Options) -> [Double] {
        var w = [Double](repeating: 1, count: samples.count)
        let clickIdx = samples.indices
            .filter { samples[$0].source == .click }
            .sorted { samples[$0].time > samples[$1].time }
        for (rank, i) in clickIdx.enumerated() {
            w[i] = o.clickWeight * pow(0.5, Double(rank) / o.clickHalfLife)
        }
        return w
    }

    /// Leave-one-point-out error (how wrong it is at a spot it hasn't seen) plus residual jitter.
    static func crossValidatedSigma(X: [[Double]], u: [Double], v: [Double], w: [Double],
                                    groups: [Int], lambda: Double) -> (Double, Double) {
        let unique = Array(Set(groups)).sorted()
        guard unique.count >= 5 else { return (0.12, 0.12) }
        var eu: [Double] = [], ev: [Double] = [], nu: [Double] = [], nv: [Double] = []
        for g in unique {
            let train = X.indices.filter { groups[$0] != g }
            let test = X.indices.filter { groups[$0] == g }
            guard !test.isEmpty,
                  let beta = LinearModels.ridge(X: train.map { X[$0] },
                                                targets: [train.map { u[$0] }, train.map { v[$0] }],
                                                weights: train.map { w[$0] },
                                                penalties: Design.penalties, lambda: lambda) else { continue }
            let pu = test.map { LinearModels.dot(beta[0], X[$0]) }
            let pv = test.map { LinearModels.dot(beta[1], X[$0]) }
            let mu = Stats.median(pu), mv = Stats.median(pv)
            eu.append(mu - Stats.median(test.map { u[$0] }))
            ev.append(mv - Stats.median(test.map { v[$0] }))
            nu.append(contentsOf: pu.map { $0 - mu })
            nv.append(contentsOf: pv.map { $0 - mv })
        }
        guard !eu.isEmpty else { return (0.12, 0.12) }
        let su = (pow(Stats.rms(eu), 2) + pow(0.5 * Stats.rms(nu), 2)).squareRoot()
        let sv = (pow(Stats.rms(ev), 2) + pow(0.5 * Stats.rms(nv), 2)).squareRoot()
        return (max(su, 0.02), max(sv, 0.02))
    }
}
