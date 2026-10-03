import Foundation
import simd

// Camera-only measuring (no LiDAR, SPEC §14): object silhouettes (foreground masks) + ARKit poses + support plane ->
// visual hull -> box. Research: docs/research/hull_rgb.py (3 device scans of a 40x30x30 box, <= 1.6 cm).

/// One view: a binary object mask (landscape, same orientation as ARCamera.capturedImage) and its camera.
public struct Silhouette: Sendable {
    public let camera: DepthCamera   // sized to the mask
    private let bits: [UInt64]

    /// `mask`: row-major, width x height, nonzero = object.
    public init(mask: [UInt8], width: Int, height: Int, intrinsics: simd_float3x3, imageResolution: SIMD2<Float>, transform: simd_float4x4) {
        precondition(mask.count == width * height)
        camera = DepthCamera(width: width, height: height, intrinsics: intrinsics, imageResolution: imageResolution, transform: transform)
        var b = [UInt64](repeating: 0, count: (mask.count + 63) / 64)
        for (i, m) in mask.enumerated() where m != 0 { b[i >> 6] |= 1 << UInt64(i & 63) }
        bits = b
    }

    @inline(__always) func contains(_ u: Int, _ v: Int) -> Bool {
        let i = v * camera.width + u
        return bits[i >> 6] >> UInt64(i & 63) & 1 != 0
    }
}

public enum SilhouetteHull {
    /// Fine-stage voxel budget: the voxel grows above 5 mm for big objects (and unclosed early hulls).
    public static let maxFineVoxels = 3_000_000
    public static let coarseVoxel: Float = 0.025
    public static let fineVoxel: Float = 0.005

    /// Box around the object whose footprint contains `center` (support plane at `floorY`): coarse carve over
    /// center +- `radius` x [floorY, floorY + maxHeight], then a fine carve over the coarse hull's bounds.
    /// Footprint = hull columns occupied in the lowest 3 cm, min-area rectangle (0.5 % trimmed per side). Height = hull
    /// top extrapolated to the footprint edge (the hull "roof" rises inward when the top is only seen obliquely).
    /// Returns the estimate and the hull's surface voxels (debug review). nil when nothing survives.
    /// Needs views from all sides (>= 180° of walk-around); fewer leave the hull open toward the cameras.
    public static func measure(_ views: [Silhouette], floorY: Float, center: SIMD2<Float>,
                               radius: Float = 1.25, maxHeight: Float = 2.0) -> (estimate: BoxEstimate, surface: [SIMD3<Float>])? {
        guard !views.isEmpty else { return nil }
        let coarse = Grid(lo: SIMD3(center.x - radius, floorY, center.y - radius),
                          hi: SIMD3(center.x + radius, floorY + maxHeight, center.y + radius), voxel: coarseVoxel)
        let ck = coarse.carve(views)
        guard !ck.isEmpty else { return nil }
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for i in ck { let p = coarse.center(Int(i)); lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let m = coarseVoxel / 2 + 0.03
        lo = SIMD3(lo.x - m, floorY, lo.z - m); hi = hi + m
        let vol = (hi.x - lo.x) * (hi.y - lo.y) * (hi.z - lo.z)
        let fine = Grid(lo: lo, hi: hi, voxel: max(fineVoxel, cbrt(vol / Float(maxFineVoxels))))
        let fk = fine.carve(views)
        guard !fk.isEmpty else { return nil }
        return fine.box(fk, floorY: floorY)
    }

    struct Grid {
        let lo: SIMD3<Float>, voxel: Float
        let nx: Int, ny: Int, nz: Int
        init(lo: SIMD3<Float>, hi: SIMD3<Float>, voxel: Float) {
            self.lo = lo; self.voxel = voxel
            nx = max(1, Int(((hi.x - lo.x) / voxel).rounded(.up)))
            ny = max(1, Int(((hi.y - lo.y) / voxel).rounded(.up)))
            nz = max(1, Int(((hi.z - lo.z) / voxel).rounded(.up)))
        }
        // index = (ix * ny + iy) * nz + iz
        @inline(__always) func center(_ i: Int) -> SIMD3<Float> {
            let iz = i % nz, iy = i / nz % ny, ix = i / (nz * ny)
            return lo + (SIMD3(Float(ix), Float(iy), Float(iz)) + 0.5) * voxel
        }

        /// Surviving voxel indices: a voxel is carved when it projects inside some view's image onto a non-object pixel,
        /// and dropped unless it was inside the image in at least half of the views (never-seen space, e.g. above
        /// the phone, is not object).
        func carve(_ views: [Silhouette]) -> [Int32] {
            var alive = [Int32](0..<Int32(nx * ny * nz)), seen = [UInt16](repeating: 0, count: alive.count)
            for s in views {
                let c = s.camera, t = c.transform
                let r = simd_float3x3(SIMD3(t.columns.0.x, t.columns.0.y, t.columns.0.z), SIMD3(t.columns.1.x, t.columns.1.y, t.columns.1.z),
                                      SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z)).transpose
                let o = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
                var n = 0
                for k in alive.indices {
                    let i = alive[k]
                    let p = r * (center(Int(i)) - o)   // camera space: looking down -z
                    let d = -p.z
                    var keep = true, inside = false
                    if d > 0.05 {
                        let u = Int((p.x * c.fx / d + c.cx).rounded()), v = Int((-p.y * c.fy / d + c.cy).rounded())
                        if u >= 0, u < c.width, v >= 0, v < c.height { inside = true; keep = s.contains(u, v) }
                    }
                    if keep { alive[n] = i; seen[n] = seen[k] + (inside ? 1 : 0); n += 1 }
                }
                alive.removeLast(alive.count - n); seen.removeLast(seen.count - n)
                if alive.isEmpty { break }
            }
            let minSeen = (views.count + 1) / 2
            return alive.indices.filter { Int(seen[$0]) >= minSeen }.map { alive[$0] }
        }

        func box(_ alive: [Int32], floorY: Float) -> (estimate: BoxEstimate, surface: [SIMD3<Float>]) {
            var occ = [Bool](repeating: false, count: nx * ny * nz)
            for i in alive { occ[Int(i)] = true }
            // Columns: footprint (lowest 3 cm) and hull top height above floorY.
            let footLayers = max(1, Int((0.03 / voxel).rounded(.up)))
            var foot = [Bool](repeating: false, count: nx * nz), top = [Float](repeating: 0, count: nx * nz)
            for ix in 0..<nx { for iz in 0..<nz {
                var hTop = -1
                for iy in 0..<ny where occ[(ix * ny + iy) * nz + iz] {
                    hTop = iy
                    if iy < footLayers { foot[ix * nz + iz] = true }
                }
                top[ix * nz + iz] = Float(hTop + 1) * voxel + (lo.y - floorY)
            } }
            let cells = (0..<(nx * nz)).filter { foot[$0] }
            let xz = cells.map { SIMD2(lo.x + (Float($0 / nz) + 0.5) * voxel, lo.z + (Float($0 % nz) + 0.5) * voxel) }

            // Min-area rectangle, 0.5 % trimmed per side (stray columns).
            var best: (area: Float, a: Float, lo: SIMD2<Float>, hi: SIMD2<Float>)?
            for step in 0..<180 {
                let a = Float(step) * 0.5 * .pi / 180, ca = cos(a), sa = sin(a)
                let q0 = xz.map { $0.x * ca + $0.y * sa }.sorted(), q1 = xz.map { -$0.x * sa + $0.y * ca }.sorted()
                let k = Int(Float(xz.count) * 0.005)
                let l = SIMD2(q0[k], q1[k]), h = SIMD2(q0[xz.count - 1 - k], q1[xz.count - 1 - k])
                let e = h - l + voxel
                if best == nil || e.x * e.y < best!.area { best = (e.x * e.y, a, l, h) }
            }
            let b = best!, ca = cos(b.a), sa = sin(b.a), e = b.hi - b.lo + voxel, mid = (b.lo + b.hi) / 2
            let cx = mid.x * ca - mid.y * sa, cz = mid.x * sa + mid.y * ca
            // Length axis in (x, z): rotated axis 0 = (cos a, sin a), axis 1 = (-sin a, cos a). BoxEstimate yaw: length
            // axis = (cos yaw, -sin yaw).
            let (len, wid, dir) = e.x >= e.y ? (e.x, e.y, SIMD2(ca, sa)) : (e.y, e.x, SIMD2(-sa, ca))
            let yaw = atan2(-dir.y, dir.x)

            // Height: median hull top per erosion ring of the footprint, line fit over rings 1...10, value at the edge.
            var ring = foot, rings: [(d: Float, h: Float)] = []
            for k in 0..<12 {
                var next = ring
                for ix in 0..<nx { for iz in 0..<nz where ring[ix * nz + iz] {
                    if ix == 0 || iz == 0 || ix == nx - 1 || iz == nz - 1 || !ring[(ix - 1) * nz + iz] || !ring[(ix + 1) * nz + iz]
                        || !ring[ix * nz + iz - 1] || !ring[ix * nz + iz + 1] { next[ix * nz + iz] = false }
                } }
                let hs = (0..<(nx * nz)).filter { ring[$0] && !next[$0] }.map { top[$0] }.sorted()
                if k >= 1, !hs.isEmpty { rings.append((Float(k) * voxel, hs[hs.count / 2])) }
                ring = next
            }
            var height = rings.map(\.h).max() ?? Float(ny) * voxel
            if rings.count >= 2 {
                let n = Float(rings.count), sd = rings.reduce(0) { $0 + $1.d }, sh = rings.reduce(0) { $0 + $1.h }
                let sdd = rings.reduce(0) { $0 + $1.d * $1.d }, sdh = rings.reduce(0) { $0 + $1.d * $1.h }
                let den = n * sdd - sd * sd
                if den > 0 { height = (sh - (n * sdh - sd * sh) / den * sd) / n }
            }

            var surface: [SIMD3<Float>] = []
            for i in alive {
                let i = Int(i), iz = i % nz, iy = i / nz % ny, ix = i / (nz * ny)
                let inner = ix > 0 && ix < nx - 1 && iy > 0 && iy < ny - 1 && iz > 0 && iz < nz - 1
                    && occ[i - ny * nz] && occ[i + ny * nz] && occ[i - nz] && occ[i + nz] && occ[i - 1] && occ[i + 1]
                if !inner { surface.append(center(i)) }
            }
            var est = BoxEstimate(length: len, width: wid, height: height, center: SIMD3(cx, floorY, cz), yaw: yaw,
                                  planeY: floorY, pointCount: alive.count)
            est.shape = .box
            return (est, surface)
        }
    }
}
