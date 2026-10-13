import Foundation

/// Review-step selection logic (pure, UI-free). Works on retained per-face scores, so changing the
/// threshold never re-runs inference.
///
/// A photo matches when its best face score is ≥ `threshold` (rule: *any tagged person*). The user can
/// exclude matches and force-include near misses; both choices survive threshold changes.
struct Matcher: Sendable, Equatable {
    var threshold: Float
    var excluded: Set<URL> = []
    var forceIncluded: Set<URL> = []

    /// Photos this far below the threshold are offered as near misses. On the test library a 0.04 band held 6 of
    /// the 7 real matches that 0.08 did, in 60 photos instead of 210 — a list a person will actually look through.
    static let nearMissMargin: Float = 0.04

    /// Default threshold when searching with `referenceCount` accepted reference faces.
    ///
    /// A model's threshold is calibrated for a single face-to-face comparison, but a photo is matched on the best
    /// of (faces × references) comparisons, so the chance that an unrelated face clears a fixed threshold grows
    /// with the number of references (measured: 1 % → 3.8 % false matches per photo going from 3 to 15
    /// references). Raising the default by 0.019 per e-fold beyond 3 references holds it near 1 %; fitted and
    /// cross-validated on the test libraries built by scripts/eval/build_scenario.py.
    static func defaultThreshold(model: Float, referenceCount: Int) -> Float {
        min(1, max(-1, model + 0.019 * log(Float(max(referenceCount, 3)) / 3)))
    }

    /// Keep the usual 0.05…0.95 slider limits, expanding to include custom defaults anywhere
    /// in the cosine domain. Clamp before constructing a range so its bounds remain ordered.
    static func thresholdRange(default d: Float) -> ClosedRange<Float> {
        let center = min(1, max(-1, d))
        let lower = max(center < 0.05 ? -1 : 0.05, center - 0.15)
        let upper = min(center > 0.95 ? 1 : 0.95, center + 0.25)
        return lower...upper
    }

    func isMatch(_ r: PhotoResult) -> Bool { r.error == nil && !r.faces.isEmpty && r.bestScore >= threshold }

    func isNearMiss(_ r: PhotoResult) -> Bool {
        r.error == nil && !r.faces.isEmpty && r.bestScore < threshold && r.bestScore >= threshold - Self.nearMissMargin
    }

    func isIncluded(_ r: PhotoResult) -> Bool {
        if forceIncluded.contains(r.id) { return true }
        return isMatch(r) && !excluded.contains(r.id)
    }

    mutating func setIncluded(_ include: Bool, for r: PhotoResult) {
        if isMatch(r) {
            forceIncluded.remove(r.id)
            if include { excluded.remove(r.id) } else { excluded.insert(r.id) }
        } else {
            if include { forceIncluded.insert(r.id) } else { forceIncluded.remove(r.id) }
        }
    }

    /// Splits results (order preserved) in a single pass.
    func partition(_ results: [PhotoResult]) -> (matches: [PhotoResult], nearMisses: [PhotoResult], selected: Int) {
        var matches: [PhotoResult] = [], nearMisses: [PhotoResult] = []
        var selected = 0
        for r in results {
            if isMatch(r) { matches.append(r) } else if isNearMiss(r) { nearMisses.append(r) }
            if isIncluded(r) { selected += 1 }
        }
        return (matches, nearMisses, selected)
    }

    /// Manually included photos stay visible even outside the near-miss band or with it collapsed.
    func reviewGroups(_ results: [PhotoResult]) -> (matches: [PhotoResult], manual: [PhotoResult], nearMisses: [PhotoResult]) {
        let p = partition(results)
        return (p.matches,
                results.filter { !isMatch($0) && forceIncluded.contains($0.id) },
                p.nearMisses.filter { !forceIncluded.contains($0.id) })
    }

    func selected(_ results: [PhotoResult]) -> [PhotoResult] { results.filter(isIncluded) }
}
