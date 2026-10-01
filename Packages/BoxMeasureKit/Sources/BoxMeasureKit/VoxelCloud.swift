import simd

/// Fuses depth points from many frames (SPEC §9 B3): per-voxel hit count + running centroid.
/// Voxels hit only once (flying pixels, transient noise) are dropped by `centroids(minHits:)`.
public struct VoxelCloud: Sendable {
    public let voxelSize: Float
    public let center: SIMD3<Float>
    public let radius: Float
    public let maxVoxels: Int
    private var voxels: [Int: (hits: Int32, sum: SIMD3<Float>)] = [:]

    public init(voxelSize: Float = 0.005, center: SIMD3<Float>, radius: Float = 2.0, maxVoxels: Int = 500_000) {
        self.voxelSize = voxelSize; self.center = center; self.radius = radius; self.maxVoxels = maxVoxels
    }

    public var count: Int { voxels.count }

    /// Points farther than `radius` horizontally from `center` are ignored. Once `maxVoxels` voxels
    /// exist, points only reinforce existing voxels.
    public mutating func insert(_ points: [SIMD3<Float>]) {
        let inv = 1 / voxelSize, r2 = radius * radius
        for q in points {
            let dx = q.x - center.x, dz = q.z - center.z
            guard dx * dx + dz * dz <= r2, q.x.isFinite, q.y.isFinite, q.z.isFinite else { continue }
            let k = voxelKey(Int((q.x * inv).rounded(.down)), Int((q.y * inv).rounded(.down)), Int((q.z * inv).rounded(.down)))
            if let i = voxels.index(forKey: k) {
                voxels.values[i].hits += 1
                voxels.values[i].sum += q
            } else if voxels.count < maxVoxels {
                voxels[k] = (1, q)
            }
        }
    }

    /// Centroid of every voxel hit at least `minHits` times.
    public func centroids(minHits: Int = 2) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(voxels.count)
        for v in voxels.values where Int(v.hits) >= minHits { out.append(v.sum / Float(v.hits)) }
        return out
    }

    public mutating func removeAll() { voxels.removeAll(keepingCapacity: true) }
}

/// 21 bits per axis (two's complement, masked): collision-free for indices in [-2^20, 2^20).
@inline(__always) func voxelKey(_ ix: Int, _ iy: Int, _ iz: Int) -> Int {
    let m = 0x1F_FFFF
    return ((ix & m) << 42) | ((iy & m) << 21) | (iz & m)
}
