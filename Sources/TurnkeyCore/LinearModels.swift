import Foundation

/// Small, dependency-free linear models (the matrices here are at most a few dozen wide).
public enum LinearModels {
    @inline(__always)
    public static func dot(_ a: [Double], _ b: [Double]) -> Double {
        var s = 0.0
        let n = min(a.count, b.count)
        for i in 0..<n { s += a[i] * b[i] }
        return s
    }

    /// Solves A·x = b for a symmetric positive-definite A (n×n, row-major), for each right-hand side.
    public static func choleskySolve(_ A: [Double], n: Int, rhs: [[Double]]) -> [[Double]]? {
        var L = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0...i {
                var sum = A[i * n + j]
                for k in 0..<j { sum -= L[i * n + k] * L[j * n + k] }
                if i == j {
                    guard sum > 1e-14 else { return nil }
                    L[i * n + i] = sum.squareRoot()
                } else {
                    L[i * n + j] = sum / L[j * n + j]
                }
            }
        }
        return rhs.map { b in
            var y = [Double](repeating: 0, count: n)
            for i in 0..<n {
                var s = b[i]
                for k in 0..<i { s -= L[i * n + k] * y[k] }
                y[i] = s / L[i * n + i]
            }
            var x = [Double](repeating: 0, count: n)
            for i in stride(from: n - 1, through: 0, by: -1) {
                var s = y[i]
                if i + 1 < n {
                    for k in (i + 1)..<n { s -= L[k * n + i] * x[k] }
                }
                x[i] = s / L[i * n + i]
            }
            return x
        }
    }

    /// Weighted ridge regression. Returns one coefficient vector per target.
    /// `penalties` scales the ridge penalty per column (column 0 is normally the intercept).
    public static func ridge(X: [[Double]], targets: [[Double]], weights: [Double],
                             penalties: [Double], lambda: Double) -> [[Double]]? {
        guard let p = X.first?.count, p > 0 else { return nil }
        var A = [Double](repeating: 0, count: p * p)
        var B = [[Double]](repeating: [Double](repeating: 0, count: p), count: targets.count)
        var wsum = 0.0
        for i in 0..<X.count {
            let xi = X[i], wi = weights[i]
            guard wi > 0 else { continue }
            wsum += wi
            for a in 0..<p {
                let wa = wi * xi[a]
                if wa == 0 { continue }
                for b in a..<p { A[a * p + b] += wa * xi[b] }
                for o in 0..<targets.count { B[o][a] += wa * targets[o][i] }
            }
        }
        guard wsum > 0 else { return nil }
        for a in 0..<p {
            for b in 0..<a { A[a * p + b] = A[b * p + a] }
        }
        for a in 0..<p {
            A[a * p + a] += lambda * wsum * penalties[a] + 1e-9 * wsum
        }
        return choleskySolve(A, n: p, rhs: B)
    }

    public static func softmax(_ z: [Double]) -> [Double] {
        let m = z.max() ?? 0
        let e = z.map { exp($0 - m) }
        let s = e.reduce(0, +)
        return e.map { $0 / s }
    }

    /// Multinomial logistic regression fitted with Newton's method (L2-regularised).
    /// Returns K weight vectors of length p.
    public static func softmaxFit(X: [[Double]], labels: [Int], classes K: Int, weights: [Double],
                                  penalties: [Double], lambda: Double, iterations: Int = 40) -> [[Double]] {
        guard let p = X.first?.count, K >= 2 else {
            return [[Double]](repeating: [Double](repeating: 0, count: X.first?.count ?? 0), count: K)
        }
        let n = X.count
        let D = K * p
        let wsum = max(weights.reduce(0, +), 1e-12)
        var theta = [Double](repeating: 0, count: D)

        func objective(_ th: [Double]) -> Double {
            var loss = 0.0
            var z = [Double](repeating: 0, count: K)
            for i in 0..<n {
                let xi = X[i]
                for k in 0..<K {
                    var s = 0.0
                    let off = k * p
                    for j in 0..<p { s += th[off + j] * xi[j] }
                    z[k] = s
                }
                let m = z.max() ?? 0
                var se = 0.0
                for k in 0..<K { se += exp(z[k] - m) }
                loss += weights[i] * (m + log(se) - z[labels[i]])
            }
            loss /= wsum
            var reg = 0.0
            for k in 0..<K {
                for j in 0..<p { reg += penalties[j] * th[k * p + j] * th[k * p + j] }
            }
            return loss + 0.5 * lambda * reg
        }

        var current = objective(theta)
        for _ in 0..<iterations {
            var g = [Double](repeating: 0, count: D)
            var H = [Double](repeating: 0, count: D * D)
            var z = [Double](repeating: 0, count: K)
            for i in 0..<n {
                let xi = X[i]
                let wi = weights[i] / wsum
                guard wi > 0 else { continue }
                for k in 0..<K {
                    var s = 0.0
                    let off = k * p
                    for j in 0..<p { s += theta[off + j] * xi[j] }
                    z[k] = s
                }
                let P = softmax(z)
                for k in 0..<K {
                    let r = P[k] - (labels[i] == k ? 1 : 0)
                    for j in 0..<p { g[k * p + j] += wi * r * xi[j] }
                    for l in 0..<K {
                        let c = wi * P[k] * ((k == l ? 1 : 0) - P[l])
                        if c == 0 { continue }
                        for j in 0..<p {
                            let cj = c * xi[j]
                            if cj == 0 { continue }
                            let row = (k * p + j) * D + l * p
                            for m in 0..<p { H[row + m] += cj * xi[m] }
                        }
                    }
                }
            }
            for k in 0..<K {
                for j in 0..<p {
                    let idx = k * p + j
                    g[idx] += lambda * penalties[j] * theta[idx]
                    H[idx * D + idx] += lambda * penalties[j] + 1e-10
                }
            }
            let gmax = g.map(abs).max() ?? 0
            if gmax < 1e-8 { break }
            guard let step = choleskySolve(H, n: D, rhs: [g])?.first else { break }
            let gd = zip(g, step).reduce(0) { $0 + $1.0 * $1.1 }
            var t = 1.0
            var accepted = false
            for _ in 0..<30 {
                var cand = theta
                for d in 0..<D { cand[d] -= t * step[d] }
                let f = objective(cand)
                if f <= current - 1e-4 * t * gd {
                    theta = cand
                    current = f
                    accepted = true
                    break
                }
                t *= 0.5
            }
            if !accepted { break }
        }
        return (0..<K).map { k in Array(theta[(k * p)..<((k + 1) * p)]) }
    }
}
