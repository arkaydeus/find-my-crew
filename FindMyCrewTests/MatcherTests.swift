import Foundation
import Testing

struct ReferenceSetTests {
    @Test func bestMatchIsTheMaximumCosineOverAllReferences() {
        let refs = ReferenceSet(embeddings: [[1, 0, 0], [0, 2, 0], [0, 0, -3]])   // normalised on init
        let face = Vector.normalized([0.2, 1, 0.1])
        let (score, index) = refs.bestMatch(for: face)
        #expect(index == 1)
        #expect(abs(score - face[1]) < 1e-6)
        #expect(refs.scores(for: face).count == 3)
        #expect(abs(refs.scores(for: face)[2] + face[2]) < 1e-6)
    }

    @Test func emptyOrMismatchedReferencesNeverMatch() {
        #expect(ReferenceSet(embeddings: []).bestMatch(for: [1, 0]) == (-1, -1))
        #expect(ReferenceSet(embeddings: [[1, 0, 0]]).bestMatch(for: [1, 0]) == (-1, -1))
    }

    @Test func mixedDimensionsPreserveOriginalReferenceIndex() {
        let refs = ReferenceSet(embeddings: [[1, 0], [0, 0, 1], [0, 1]])
        #expect(refs.count == 2)
        #expect(refs.bestMatch(for: [0, 1]) == (1, 2))
        #expect(refs.bestMatch(for: [1, 0]) == (1, 0))
        #expect(ReferenceSet(embeddings: [[]]).isEmpty)
    }

    @Test func vectorHelpers() {
        let v = Vector.normalized([3, 4])
        #expect(abs(v[0] - 0.6) < 1e-6 && abs(v[1] - 0.8) < 1e-6)
        #expect(Vector.normalized([0, 0]) == [0, 0])
        #expect(Vector.dot([1, 2, 3], [4, 5, 6]) == 32)
        #expect(Vector.add([1, 2], [3, 4]) == [4, 6])
    }
}

struct MatcherTests {
    let results = [
        makeResult("a.jpg", scores: [0.1, 0.62]),
        makeResult("b.jpg", scores: [0.45]),
        makeResult("c.jpg", scores: [0.37]),
        makeResult("d.jpg", scores: [0.33]),   // near miss at 0.36
        makeResult("e.jpg", scores: [0.25]),   // too far below
        makeResult("f.jpg", scores: []),       // no faces
        makeResult("g.jpg", scores: [], error: "Could not decode g.jpg"),
    ]

    @Test func photoScoreIsTheBestFace() {
        #expect(results[0].bestScore == 0.62)
        #expect(results[0].bestFace?.referenceIndex == 1)
        #expect(results[5].bestScore == -1)
        #expect(results[5].bestFace == nil)
    }

    @Test func partitionsMatchesAndNearMisses() {
        let m = Matcher(threshold: 0.36)
        let p = m.partition(results)
        #expect(p.matches.map(\.item.relativePath) == ["a.jpg", "b.jpg", "c.jpg"])
        #expect(p.nearMisses.map(\.item.relativePath) == ["d.jpg"])
        #expect(p.selected == 3)
        #expect(m.selected(results).count == 3)
    }

    @Test func thresholdChangesRefilterWithoutLosingExclusions() {
        var m = Matcher(threshold: 0.36)
        m.setIncluded(false, for: results[1])           // exclude b
        #expect(m.selected(results).map(\.item.relativePath) == ["a.jpg", "c.jpg"])

        m.threshold = 0.5                               // stricter: only a
        #expect(m.selected(results).map(\.item.relativePath) == ["a.jpg"])
        m.threshold = 0.3                               // looser: a, c, d — b still excluded
        #expect(m.selected(results).map(\.item.relativePath) == ["a.jpg", "c.jpg", "d.jpg"])

        m.setIncluded(true, for: results[1])
        #expect(m.isIncluded(results[1]))
    }

    @Test func rescuedNearMissIsSelectedForExport() {
        var m = Matcher(threshold: 0.36)
        #expect(!m.isIncluded(results[3]))
        m.setIncluded(true, for: results[3])
        #expect(m.isIncluded(results[3]))
        #expect(m.selected(results).map(\.item.relativePath).contains("d.jpg"))
        // Still rescued when the slider moves.
        m.threshold = 0.45
        #expect(m.isIncluded(results[3]))
        // Once it becomes a regular match, unticking it really removes it.
        m.threshold = 0.3
        m.setIncluded(false, for: results[3])
        #expect(!m.isIncluded(results[3]))
    }

    @Test func defaultThresholdRisesWithTheNumberOfReferences() {
        #expect(Matcher.defaultThreshold(model: 0.363, referenceCount: 1) == 0.363)
        #expect(Matcher.defaultThreshold(model: 0.363, referenceCount: 3) == 0.363)
        let nine = Matcher.defaultThreshold(model: 0.363, referenceCount: 9)
        let fifteen = Matcher.defaultThreshold(model: 0.363, referenceCount: 15)
        let fifty = Matcher.defaultThreshold(model: 0.363, referenceCount: 50)
        #expect(abs(nine - 0.384) < 0.001 && abs(fifteen - 0.394) < 0.001)
        #expect(fifteen < fifty && fifty < 0.45)   // grows slowly
    }

    @Test func thresholdRangeIsClampedAroundTheDefault() {
        let range = Matcher.thresholdRange(default: 0.36)
        #expect(abs(range.lowerBound - 0.21) < 1e-6 && abs(range.upperBound - 0.61) < 1e-6)
        #expect(Matcher.thresholdRange(default: 0.1).lowerBound == 0.05)
        #expect(Matcher.thresholdRange(default: 0.8).upperBound == 0.95)
    }

    @Test func scoreLimitDefaultsAlwaysFitAnOrderedSliderRange() {
        for model: Float in [-1, -0.5, -0.21, 0, 0.98, 1] {
            for count in [0, 1, 9, 1_000_000, Int.max] {
                let threshold = Matcher.defaultThreshold(model: model, referenceCount: count)
                let range = Matcher.thresholdRange(default: threshold)
                #expect((-1...1).contains(threshold))
                #expect(range.lowerBound <= range.upperBound)
                #expect(range.lowerBound >= -1 && range.upperBound <= 1)
                #expect(range.contains(threshold))
            }
        }
        let high = Matcher.defaultThreshold(model: 0.98, referenceCount: 9)
        #expect(high == 1)
        #expect(Matcher(threshold: high).isMatch(makeResult("perfect", scores: [1])))
        #expect(!Matcher(threshold: -1).isMatch(makeResult("blank", scores: [])))
        #expect(!Matcher(threshold: -1).isMatch(makeResult("broken", scores: [], error: "decode")))
    }

    @Test func manuallyIncludedPhotosStayVisibleAndCanBeUnticked() {
        var matcher = Matcher(threshold: 0.36)
        let rescued = results[3]
        matcher.setIncluded(true, for: rescued)
        matcher.threshold = 0.8
        let groups = matcher.reviewGroups(results)
        #expect(groups.manual.map(\.id) == [rescued.id])
        #expect(!groups.nearMisses.contains { $0.id == rescued.id })
        #expect(matcher.isIncluded(rescued))
        matcher.setIncluded(false, for: rescued)
        #expect(matcher.reviewGroups(results).manual.isEmpty)
        #expect(!matcher.isIncluded(rescued))
        matcher.threshold = 0.36
        matcher.setIncluded(true, for: rescued)
        #expect(!matcher.reviewGroups(results).nearMisses.contains { $0.id == rescued.id })
        matcher.threshold = 0.3
        #expect(matcher.reviewGroups(results).manual.isEmpty)
        #expect(matcher.reviewGroups(results).matches.contains { $0.id == rescued.id })
    }

    /// FR-5.2: re-filtering 10k+ results must take < 100 ms.
    @Test func refilteringTenThousandResultsIsFast() {
        var rng = SystemRandomNumberGenerator()
        let many = (0..<20_000).map { i in
            makeResult("\(i).jpg", scores: (0..<Int.random(in: 0...4, using: &rng)).map { _ in Float.random(in: -0.2...0.9, using: &rng) })
        }
        var m = Matcher(threshold: 0.36)
        for r in many.prefix(500) { m.setIncluded(false, for: r) }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for t in stride(from: Float(0.25), through: 0.55, by: 0.05) {
                m.threshold = t
                _ = m.partition(many)
            }
        }
        // 7 full re-filters; each one must be well under 100 ms.
        #expect(elapsed / 7 < .milliseconds(100), "partition took \(elapsed / 7)")
    }
}
