import Accelerate

enum Vector {
    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "dimension mismatch")
        return vDSP.dot(a, b)
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let norm = vDSP.sumOfSquares(v).squareRoot()
        guard norm > 0 else { return v }
        return vDSP.divide(v, norm)
    }

    static func add(_ a: [Float], _ b: [Float]) -> [Float] {
        vDSP.add(a, b)
    }
}

/// The accepted reference faces, as unit vectors. Cosine similarity == dot product.
struct ReferenceSet: Sendable {
    let embeddings: [[Float]]

    init(embeddings: [[Float]]) {
        self.embeddings = embeddings.map(Vector.normalized)
    }

    var isEmpty: Bool { embeddings.isEmpty }

    /// Highest cosine similarity of `embedding` to any reference, and which reference.
    func bestMatch(for embedding: [Float]) -> (score: Float, index: Int) {
        var best: Float = -1
        var bestIndex = -1
        for (i, ref) in embeddings.enumerated() where ref.count == embedding.count {
            let s = Vector.dot(ref, embedding)
            if s > best { best = s; bestIndex = i }
        }
        return (best, bestIndex)
    }
}
