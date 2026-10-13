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
        model + 0.019 * log(Float(max(referenceCount, 3)) / 3)
    }

    /// Slider range around a model's calibrated default threshold.
    static func thresholdRange(default d: Float) -> ClosedRange<Float> {
        max(0.05, d - 0.15)...min(0.95, d + 0.25)
    }

    func isMatch(_ r: PhotoResult) -> Bool { r.bestScore >= threshold }

    func isNearMiss(_ r: PhotoResult) -> Bool {
        r.bestScore < threshold && r.bestScore >= threshold - Self.nearMissMargin
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

    func selected(_ results: [PhotoResult]) -> [PhotoResult] { results.filter(isIncluded) }
}
