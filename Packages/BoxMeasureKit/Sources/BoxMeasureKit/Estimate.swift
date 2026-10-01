import simd

func medianOf(_ v: [Float]) -> Float {
    let s = v.sorted()
    let n = s.count
    if n == 0 { return 0 }
    return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
}

@inline(__always) func cellKey(_ ix: Int, _ iz: Int) -> Int { (ix << 32) | (iz & 0xffff_ffff) }

/// Nearest supporting surface below the seed (SPEC §4): scan the y histogram downward from
/// seed.y - planeGap, first bin with enough points wins. Radius grows in 0.5 m steps.
func findPlaneY(points: [SIMD3<Float>], seed: SIMD3<Float>, p: Params) -> Float? {
    let topY = seed.y - p.planeGap
    let topBin = Int((topY / p.binSize).rounded(.down))
    var r = p.searchRadius
    while true {
        let r2 = r * r
        var inRadius = 0
        var below: [Float] = []
        var minY = Float.infinity
        for q in points {
            let dx = q.x - seed.x, dz = q.z - seed.z
            guard dx * dx + dz * dz <= r2 else { continue }
            inRadius += 1
            if q.y <= topY { below.append(q.y); minY = min(minY, q.y) }
        }
        if !below.isEmpty {
            let lowBin = Int((minY / p.binSize).rounded(.down))
            let n = topBin - lowBin + 1
            var count = [Int](repeating: 0, count: n)   // index 0 = topBin, descending y
            var sum = [Float](repeating: 0, count: n)
            for y in below {
                let i = topBin - Int((y / p.binSize).rounded(.down))
                guard i >= 0 && i < n else { continue }
                count[i] += 1; sum[i] += y
            }
            let threshold = max(p.minPlanePoints, Int((p.minPlaneFraction * Float(inRadius)).rounded(.up)))
            if var i = count.firstIndex(where: { $0 >= threshold }) {
                // Noise straddles bins: slide to the local peak, then average peak +/- 1 bin.
                while i + 1 < n && count[i + 1] > count[i] { i += 1 }
                var c = 0, s: Float = 0
                for j in max(0, i - 1)...min(n - 1, i + 1) { c += count[j]; s += sum[j] }
                return s / Float(c)
            }
        }
        if r >= p.maxSearchRadius { return nil }
        r = min(r + 0.5, p.maxSearchRadius)
    }
}

func estimateImpl(points: [SIMD3<Float>], seed: SIMD3<Float>, p: Params) -> BoxEstimate? {
    guard p.gridCell > 0, p.binSize > 0, let planeY = findPlaneY(points: points, seed: seed, p: p) else { return nil }

    // Box candidates: above the plane, not far above the seed. Bucket into an XZ grid.
    let lo = planeY + p.abovePlane, hi = seed.y + p.topSlab * 2.5
    let inv = 1 / p.gridCell
    var idx: [Int] = []
    var keys: [Int] = []
    var cellCount: [Int: Int] = [:]
    for (i, q) in points.enumerated() where q.y > lo && q.y <= hi {
        let k = cellKey(Int((q.x * inv).rounded(.down)), Int((q.z * inv).rounded(.down)))
        idx.append(i); keys.append(k)
        cellCount[k, default: 0] += 1
    }
    let occupied = { (k: Int) in (cellCount[k] ?? 0) >= p.minCellPoints }

    // Seed cell, or the nearest occupied one.
    let sx = Int((seed.x * inv).rounded(.down)), sz = Int((seed.z * inv).rounded(.down))
    var start: Int?
    search: for d in 0...max(0, p.seedCellSearch) {
        var best: (Int, Int)?   // (dist2, key)
        for dx in -d...d { for dz in -d...d where max(abs(dx), abs(dz)) == d {
            let k = cellKey(sx + dx, sz + dz)
            if occupied(k), best == nil || dx * dx + dz * dz < best!.0 { best = (dx * dx + dz * dz, k) }
        } }
        if let b = best { start = b.1; break search }
    }
    guard let start else { return nil }

    // 8-connected flood fill.
    var comp: Set<Int> = [start]
    var stack = [start]
    while let k = stack.popLast() {
        let ix = k >> 32, iz = Int(Int32(truncatingIfNeeded: k))
        for dx in -1...1 { for dz in -1...1 where dx != 0 || dz != 0 {
            let n = cellKey(ix + dx, iz + dz)
            if occupied(n), comp.insert(n).inserted { stack.append(n) }
        } }
    }

    var compYs: [Float] = []
    var slabPts: [(key: Int, xz: SIMD2<Float>)] = []
    var slabCount: [Int: Int] = [:]
    var allXZ: [SIMD2<Float>] = []
    for (j, k) in keys.enumerated() where comp.contains(k) {
        let q = points[idx[j]]
        compYs.append(q.y)
        allXZ.append(SIMD2(q.x, q.z))
        if abs(q.y - seed.y) <= p.topSlab {
            slabPts.append((k, SIMD2(q.x, q.z)))
            slabCount[k, default: 0] += 1
        }
    }
    guard compYs.count >= p.minBoxPoints else { return nil }

    // Footprint from top-slab points. Cell filters use slab-only counts: >= minCellPoints and
    // >= slabNeighbours occupied neighbours, so sparse/isolated bleed cells drop out.
    // footprintRect then trims stragglers that survive next to the real edge.
    let keep = slabCount.filter { k, c in
        guard c >= p.minCellPoints else { return false }
        let ix = k >> 32, iz = Int(Int32(truncatingIfNeeded: k))
        var n = 0
        for dx in -1...1 { for dz in -1...1 where (dx != 0 || dz != 0) && slabCount[cellKey(ix + dx, iz + dz)] != nil { n += 1 } }
        return n >= p.slabNeighbours
    }
    let slabXZ = slabPts.filter { keep[$0.key] != nil }.map(\.xz)
    let rect = footprintRect(slabXZ.count >= p.minTopSlabPoints ? slabXZ : allXZ, p)

    compYs.sort()
    let pi = min(compYs.count - 1, max(0, Int((p.heightPercentile * Float(compYs.count - 1)).rounded())))
    let height = compYs[pi] - planeY
    let (l, w) = (rect.size.x, rect.size.y)
    guard l > 0, w > 0, height > 0, l <= p.maxBoxSize, w <= p.maxBoxSize, height <= p.maxBoxSize else { return nil }

    // rect angle is atan2(dz, dx) in (x, z); right-handed yaw about +y is its negation.
    var yaw = -rect.angle
    if yaw <= -.pi / 2 { yaw += .pi }
    return BoxEstimate(length: l, width: w, height: height,
                       center: SIMD3(rect.center.x, planeY, rect.center.y),
                       yaw: yaw, planeY: planeY, pointCount: compYs.count)
}

@inline(__always) func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
    (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
}

func convexHull(_ pts: [SIMD2<Float>]) -> [SIMD2<Float>] {
    let s = pts.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
    if s.count < 3 { return s }
    var h: [SIMD2<Float>] = []
    for q in s {
        while h.count >= 2 && cross(h[h.count - 2], h[h.count - 1], q) <= 0 { h.removeLast() }
        h.append(q)
    }
    let lower = h.count + 1
    for q in s.reversed().dropFirst() {
        while h.count >= lower && cross(h[h.count - 2], h[h.count - 1], q) <= 0 { h.removeLast() }
        h.append(q)
    }
    h.removeLast()
    return h  // CCW; 1-2 points when input is all duplicates / collinear
}

func normAngle(_ a: Float) -> Float {
    var a = a
    while a > .pi / 2 + 1e-6 { a -= .pi }
    while a <= -.pi / 2 { a += .pi }
    return a
}

func minAreaRectImpl(_ pts: [SIMD2<Float>]) -> (center: SIMD2<Float>, size: SIMD2<Float>, angle: Float) {
    let h = convexHull(pts)
    switch h.count {
    case 0: return (.zero, .zero, 0)
    case 1: return (h[0], .zero, 0)
    case 2:
        let d = h[1] - h[0]
        let len = simd_length(d)
        return ((h[0] + h[1]) / 2, SIMD2(len, 0), len > 0 ? normAngle(atan2(d.y, d.x)) : 0)
    default: break
    }
    // ponytail: O(h^2) per-edge projection instead of true rotating calipers; hulls here are tens of points.
    var best: (area: Float, c: SIMD2<Float>, du: Float, dv: Float, u: SIMD2<Float>)?
    for i in h.indices {
        let e = h[(i + 1) % h.count] - h[i]
        let len = simd_length(e)
        guard len > 0 else { continue }
        let u = e / len, v = SIMD2(-u.y, u.x)
        var minU = Float.infinity, maxU = -Float.infinity, minV = Float.infinity, maxV = -Float.infinity
        for q in h {
            let a = simd_dot(q, u), b = simd_dot(q, v)
            minU = min(minU, a); maxU = max(maxU, a); minV = min(minV, b); maxV = max(maxV, b)
        }
        let area = (maxU - minU) * (maxV - minV)
        if best == nil || area < best!.area {
            best = (area, u * (minU + maxU) / 2 + v * (minV + maxV) / 2, maxU - minU, maxV - minV, u)
        }
    }
    guard let b = best else { return (h[0], .zero, 0) }
    if b.du >= b.dv { return (b.c, SIMD2(b.du, b.dv), normAngle(atan2(b.u.y, b.u.x))) }
    return (b.c, SIMD2(b.dv, b.du), normAngle(atan2(b.u.x, -b.u.y)))  // v = (-u.y, u.x)
}


/// k-th smallest and k-th largest of `vals` (k clamped to the data); O(n) for small k.
func trimmedRange(_ vals: [Float], _ k: Int) -> (lo: Float, hi: Float) {
    let k = max(1, min(k, vals.count / 4))
    var lows: [Float] = [], highs: [Float] = []   // ascending / descending, length <= k
    for v in vals {
        if lows.count < k || v < lows[k - 1] {
            lows.insert(v, at: lows.firstIndex { $0 > v } ?? lows.count)
            if lows.count > k { lows.removeLast() }
        }
        if highs.count < k || v > highs[k - 1] {
            highs.insert(v, at: highs.firstIndex { $0 < v } ?? highs.count)
            if highs.count > k { highs.removeLast() }
        }
    }
    return (lows.last!, highs.last!)
}

/// minAreaRect is decided by single extreme points, so a few stray (bleed) points tilt and inflate
/// it. Refit twice: at the current angle take trimmed extents, drop points beyond them by more
/// than p.trimMargin, re-run minAreaRect on the inliers (untrimmed, so no inward bias).
func footprintRect(_ pts: [SIMD2<Float>], _ p: Params) -> (center: SIMD2<Float>, size: SIMD2<Float>, angle: Float) {
    var r = minAreaRect(pts)
    guard pts.count >= 8 * p.trimPoints else { return r }
    for _ in 0..<2 {
        guard r.size.y > 0 else { return r }
        let u = SIMD2<Float>(cos(r.angle), sin(r.angle)), v = SIMD2<Float>(-u.y, u.x)
        let pu = pts.map { simd_dot($0, u) }, pv = pts.map { simd_dot($0, v) }
        let ru = trimmedRange(pu, p.trimPoints), rv = trimmedRange(pv, p.trimPoints)
        let inliers = pts.indices.filter {
            pu[$0] >= ru.lo - p.trimMargin && pu[$0] <= ru.hi + p.trimMargin &&
            pv[$0] >= rv.lo - p.trimMargin && pv[$0] <= rv.hi + p.trimMargin
        }.map { pts[$0] }
        r = minAreaRect(inliers)
    }
    return r
}
