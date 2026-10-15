import Foundation

nonisolated enum MeetAISpeakerMath {
    static func normalize(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0, norm.isFinite else { return vector }
        return vector.map { $0 / norm }
    }

    /// Dot product, or -1 when dimensions differ.
    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -1 }
        var sum: Float = 0
        for index in a.indices { sum += a[index] * b[index] }
        return sum
    }

    static func centroid(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for vector in vectors where vector.count == first.count {
            let normalized = self.normalize(vector)
            for index in sum.indices { sum[index] += normalized[index] }
        }
        return self.normalize(sum)
    }

    /// Weighted running centroid (existing weight = `count`), renormalised.
    static func updatedCentroid(_ centroid: [Float], count: Int, adding sample: [Float]) -> [Float] {
        guard centroid.count == sample.count else { return self.normalize(sample) }
        let weight = Float(count)
        let normalizedSample = self.normalize(sample)
        return self.normalize(centroid.indices.map { centroid[$0] * weight + normalizedSample[$0] })
    }
}
