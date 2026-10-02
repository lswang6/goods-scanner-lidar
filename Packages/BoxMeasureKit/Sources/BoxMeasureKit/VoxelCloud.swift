import simd

/// Fuses depth points from many frames (SPEC §9 B3): per-voxel hit count + running centroid.
/// Voxels hit only once (flying pixels, transient noise) are dropped by `centroids(minHits:)`.
public struct VoxelCloud: Sendable {
    public let voxelSize: Float
    public var center: SIMD3<Float>   // crop for NEW inserts only; moving it never drops stored voxels
    public var radius: Float
    public let maxVoxels: Int
    /// Voxels at y <= floorY (support plane + noise band, and glossy-floor reflections below it) may take
    /// at most half of `maxVoxels`. A noisy floor alone otherwise fills the cap within seconds and every
    /// object surface seen later (the far side of a walk-around) is silently dropped.
    public let floorY: Float
    private var floorVoxels = 0
    /// `good`: hits seen head-on (cos incidence >= headOnCos); `n`: last grazing hit's surface normal (facing the
    /// camera, x127); `st`: running mean (cos incidence, camera range m) over hits, range 0 = unknown. Only valid
    /// when every insert into the cloud carries incidence + camera (as the app and refuse do).
    /// 4 + 4 + 4 + 4 + 16 = 32 bytes, the stride of the original (hits, sum) tuple.
    private var voxels: [Int: (hits: Int32, good: Int32, n: SIMD4<Int8>, st: SIMD2<Float16>, sum: SIMD3<Float>)] = [:]

    /// Head-on = surface normal within 40° of the view ray. Device logs 2026-10-02 (logs6/logs7): cardboard seen at
    /// >= 60° reads 0.3-2.4 cm toward the camera (p90 3 cm); within 40° it is unbiased to ~1 cm.
    public static let headOnCos: Float = cos(40 * .pi / 180)
    /// A grazing-only voxel is dropped when a head-on voxel (1 cm cells) lies 1, 2 or 3 cm behind it along its normal.
    public static let suppressCell: Float = 0.01
    public static let suppressDepths: [Float] = [0.01, 0.02, 0.03]

    public init(voxelSize: Float = 0.005, center: SIMD3<Float>, radius: Float = 2.0, maxVoxels: Int = 1_500_000, floorY: Float = -.infinity) {
        self.voxelSize = voxelSize; self.center = center; self.radius = radius; self.maxVoxels = maxVoxels; self.floorY = floorY
    }

    public var count: Int { voxels.count }

    /// Points farther than `radius` horizontally from `center` are ignored. Once `maxVoxels` voxels
    /// exist (or maxVoxels/2 at y <= floorY for floor points), points only reinforce existing voxels.
    /// `incidence`: per point, xyz = world surface normal facing the camera, w = cos incidence (see `surfaceNormals`);
    /// nil = every point counts as head-on, no incidence stats (old behaviour). `camera`: position (range stats).
    public mutating func insert(_ points: [SIMD3<Float>], incidence: [SIMD4<Float>]? = nil, camera: SIMD3<Float>? = nil) {
        precondition(incidence == nil || incidence!.count == points.count)
        let inv = 1 / voxelSize, r2 = radius * radius
        for (i, q) in points.enumerated() {
            let dx = q.x - center.x, dz = q.z - center.z
            guard dx * dx + dz * dz <= r2, q.x.isFinite, q.y.isFinite, q.z.isFinite else { continue }
            let k = voxelKey(Int((q.x * inv).rounded(.down)), Int((q.y * inv).rounded(.down)), Int((q.z * inv).rounded(.down)))
            let inc = incidence?[i]
            let g: Int32 = inc.map { $0.w >= Self.headOnCos ? 1 : 0 } ?? 1
            let n = inc.map { SIMD4<Int8>(clamping: SIMD4<Int32>(($0 * 127).rounded(.toNearestOrEven))) } ?? .zero
            let st = inc.flatMap { i in camera.map { SIMD2(i.w, simd_length(q - $0)) } }
            if let j = voxels.index(forKey: k) {
                voxels.values[j].hits += 1
                voxels.values[j].good += g
                if g == 0 { voxels.values[j].n = n }
                voxels.values[j].sum += q
                if let st {   // running mean
                    let m = SIMD2<Float>(voxels.values[j].st)
                    voxels.values[j].st = SIMD2<Float16>(m + (st - m) / Float(voxels.values[j].hits))
                }
            } else if voxels.count < maxVoxels || evictSingles(), q.y > floorY || floorVoxels < maxVoxels / 2 {
                voxels[k] = (1, g, g == 0 ? n : .zero, st.map { SIMD2<Float16>($0) } ?? .zero, q)
                if q.y <= floorY { floorVoxels += 1 }
            }
        }
    }

    /// Full: drop voxels hit only once (flying pixels, floor-noise speckle; device log 2026-10-02 110433 had
    /// 57 % of the cap in them). Only if that frees >= 10 % of the cap; otherwise stop trying (O(n) each).
    private var canEvict = true
    private mutating func evictSingles() -> Bool {
        guard canEvict else { return false }
        let kept = voxels.filter { $0.value.hits > 1 }
        guard kept.count <= maxVoxels * 9 / 10 else { canEvict = false; return false }
        voxels = kept
        floorVoxels = voxels.values.filter { $0.sum.y / Float($0.hits) <= floorY }.count
        return true
    }

    /// Centroid of every voxel hit at least `minHits` times.
    public func centroids(minHits: Int = 2) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(voxels.count)
        for v in voxels.values where Int(v.hits) >= minHits { out.append(v.sum / Float(v.hits)) }
        return out
    }

    /// Incidence-aware cloud: centroids (>= minHits) tagged head-on (>= 1 head-on hit). A grazing-only voxel with a
    /// head-on voxel 1-3 cm behind it along its own surface normal is dropped: it is the toward-camera shell of a
    /// surface that was also seen head-on. Surfaces only ever seen grazing are kept (no better data); grazing voxels
    /// at a corner (normal pointing away from the head-on neighbour) are kept, so faces stay connected.
    /// ponytail: a genuine grazing-only layer < 3 cm in front of a head-on surface (thin lip) is dropped too.
    /// `incidence`: per point mean (cos incidence, camera range m), range 0 = unknown.
    public func headOnFiltered(minHits: Int = 2) -> (points: [SIMD3<Float>], headOn: [Bool], incidence: [SIMD2<Float>]) {
        let inv = 1 / Self.suppressCell
        func cell(_ p: SIMD3<Float>) -> SIMD3<Int> { SIMD3(Int((p.x * inv).rounded(.down)), Int((p.y * inv).rounded(.down)), Int((p.z * inv).rounded(.down))) }
        var goodCells = Set<SIMD3<Int>>()
        for v in voxels.values where Int(v.hits) >= minHits && v.good > 0 { goodCells.insert(cell(v.sum / Float(v.hits))) }
        var pts: [SIMD3<Float>] = [], tag: [Bool] = [], st: [SIMD2<Float>] = []
        pts.reserveCapacity(voxels.count); tag.reserveCapacity(voxels.count); st.reserveCapacity(voxels.count)
        for v in voxels.values where Int(v.hits) >= minHits {
            let p = v.sum / Float(v.hits)
            if v.good == 0, !goodCells.isEmpty, v.n != .zero {
                let n = SIMD3<Float>(Float(v.n.x), Float(v.n.y), Float(v.n.z)) / 127
                if Self.suppressDepths.contains(where: { goodCells.contains(cell(p - n * $0)) }) { continue }
            }
            pts.append(p); tag.append(v.good > 0); st.append(SIMD2<Float>(v.st))
        }
        return (pts, tag, st)
    }

    public mutating func removeAll() { voxels.removeAll(keepingCapacity: true); floorVoxels = 0; canEvict = true }
}

/// 21 bits per axis (two's complement, masked): collision-free for indices in [-2^20, 2^20).
@inline(__always) func voxelKey(_ ix: Int, _ iy: Int, _ iz: Int) -> Int {
    let m = 0x1F_FFFF
    return ((ix & m) << 42) | ((iy & m) << 21) | (iz & m)
}
