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

/// The accepted reference faces as an R×D matrix of unit vectors. Cosine similarity == dot product.
struct ReferenceSet: Sendable {
    let embeddings: [[Float]]
    let dimension: Int
    /// Row-major R×D copy of `embeddings`, built once so each face is scored with one matrix-vector product.
    private let matrix: [Float]

    init(embeddings: [[Float]]) {
        let unit = embeddings.map(Vector.normalized)
        let d = unit.first?.count ?? 0
        let rows = unit.filter { $0.count == d }
        dimension = d
        self.embeddings = rows
        matrix = rows.flatMap { $0 }
    }

    var isEmpty: Bool { embeddings.isEmpty }
    var count: Int { embeddings.count }

    /// Cosine similarity of `embedding` (unit length) to every reference.
    func scores(for embedding: [Float]) -> [Float] {
        guard !isEmpty, embedding.count == dimension else { return [] }
        var out = [Float](repeating: 0, count: count)
        vDSP_mmul(matrix, 1, embedding, 1, &out, 1, vDSP_Length(count), 1, vDSP_Length(dimension))
        return out
    }

    /// Highest cosine similarity of `embedding` to any reference, and which reference (−1, −1 if none).
    func bestMatch(for embedding: [Float]) -> (score: Float, index: Int) {
        let s = scores(for: embedding)
        guard !s.isEmpty else { return (-1, -1) }
        let (index, value) = vDSP.indexOfMaximum(s)
        return (value, Int(index))
    }
}
