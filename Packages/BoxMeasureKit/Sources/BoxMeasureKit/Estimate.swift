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
/// Returns the plane height and the search radius it was found at.
/// Side seeds (seedOnSide): vertical faces spread over all y-bins (perimeter x binSize x density per
/// bin), far below the 5%-of-radius threshold, so they are not picked as a plane.
func findPlaneY(points: [SIMD3<Float>], seed: SIMD3<Float>, p: Params) -> (y: Float, r: Float)? {
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
                return (s / Float(c), r)
            }
        }
        if r >= p.maxSearchRadius { return nil }
        r = min(r + 0.5, p.maxSearchRadius)
    }
}

/// The one estimate pipeline. `collect` = also gather object/plane point indices (debug only;
/// `estimate` passes false so it pays nothing extra). `d.failure` = first failing stage.
func estimateImpl(points: [SIMD3<Float>], seed: SIMD3<Float>, p: Params, collect: Bool) -> (BoxEstimate?, EstimateDebug) {
    var d = EstimateDebug()
    func fail(_ f: EstimateFailure) -> (BoxEstimate?, EstimateDebug) { d.failure = f; return (nil, d) }
    guard p.gridCell > 0, p.binSize > 0, let plane = findPlaneY(points: points, seed: seed, p: p) else { return fail(.noPlane) }
    let planeY = plane.y
    d.planeY = planeY
    if collect {
        let r2 = plane.r * plane.r
        d.planeIndices = points.indices.filter {
            let q = points[$0], dx = q.x - seed.x, dz = q.z - seed.z
            return dx * dx + dz * dz <= r2 && abs(q.y - planeY) <= p.binSize
        }
    }
    let useMaxExtent = p.maxExtent || p.seedOnSide

    // Box candidates: above the plane, not far above the seed (side seed: up to a max-size box). XZ grid.
    let lo = planeY + p.abovePlane
    let hi = seed.y + (p.seedOnSide ? p.maxBoxSize : p.maxExtent ? p.maxAboveSeed : p.topSlab * 2.5)
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
    guard let start else { return fail(.noSeedCell) }

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

    var compPts: [SIMD3<Float>] = []
    var compKeys: [Int] = []
    var slabPts: [(key: Int, xz: SIMD2<Float>)] = []
    var slabCount: [Int: Int] = [:]
    for (j, k) in keys.enumerated() where comp.contains(k) {
        let q = points[idx[j]]
        compPts.append(q); compKeys.append(k)
        if collect { d.objectIndices.append(idx[j]) }
        if !useMaxExtent && abs(q.y - seed.y) <= p.topSlab {
            slabPts.append((k, SIMD2(q.x, q.z)))
            slabCount[k, default: 0] += 1
        }
    }
    guard compPts.count >= p.minBoxPoints else { return fail(.tooFewPoints) }
    let allXZ = compPts.map { SIMD2($0.x, $0.z) }

    let rect: (center: SIMD2<Float>, size: SIMD2<Float>, angle: Float)
    let height: Float
    if useMaxExtent {
        // C4: every height counts. Comp cells already have >= minCellPoints; drop cells with few
        // occupied neighbours and cells without vertical support, then footprintRect trims stragglers.
        guard let top = supportedTop(compPts, p) else { return fail(.tooFewPoints) }
        height = top - planeY
        let keep = denseCells(cellCount.filter { comp.contains($0.key) }, p)
        // Vertical support: a footprint cell must hold points in >= `columnBins` distinct y-bins (capped at
        // half the object's bins above `lo`, so low objects keep their walls). Walls pass; a flat shelf of
        // edge bleed past a top edge, or glossy-floor noise just above `lo`, spans only 1-3 bins.
        let need = min(p.columnBins, Int(0.5 * (top - lo) / p.binSize))
        var bins: [Int: Set<Int>] = [:]
        if need > 1 {
            for (j, k) in compKeys.enumerated() where keep[k] != nil {
                bins[k, default: []].insert(Int((compPts[j].y / p.binSize).rounded(.down)))
            }
        }
        let ok = { (k: Int) in keep[k] != nil && (need <= 1 || bins[k]!.count >= need) }
        let xz = compKeys.indices.filter { ok(compKeys[$0]) }.map { allXZ[$0] }
        rect = footprintRect(xz.count >= p.minBoxPoints ? xz : allXZ, p)
    } else {
        // Footprint from top-slab points. Cell filters use slab-only counts, so sparse/isolated
        // bleed cells drop out. footprintRect then trims stragglers that survive next to the real edge.
        let keep = denseCells(slabCount, p)
        let slabXZ = slabPts.filter { keep[$0.key] != nil }.map(\.xz)
        rect = footprintRect(slabXZ.count >= p.minTopSlabPoints ? slabXZ : allXZ, p)
        let ys = compPts.map(\.y).sorted()
        let pi = min(ys.count - 1, max(0, Int((p.heightPercentile * Float(ys.count - 1)).rounded())))
        height = ys[pi] - planeY
    }
    let (l, w) = (rect.size.x, rect.size.y)
    guard l > 0, w > 0, height > 0, l <= p.maxBoxSize, w <= p.maxBoxSize, height <= p.maxBoxSize else { return fail(.outOfRange) }

    // rect angle is atan2(dz, dx) in (x, z); right-handed yaw about +y is its negation.
    var yaw = -rect.angle
    if yaw <= -.pi / 2 { yaw += .pi }
    var e = BoxEstimate(length: l, width: w, height: height,
                        center: SIMD3(rect.center.x, planeY, rect.center.y),
                        yaw: yaw, planeY: planeY, pointCount: compPts.count)
    if p.detectShape && useMaxExtent, let f = shapeFeatures(compPts, planeY: planeY, height: height, rect: rect) {
        e.shape = classify(f)
        if e.shape == .cylinder, let dia = cylinderDiameter(compPts, center: f.center, planeY: planeY, p), dia <= p.maxBoxSize {
            e.length = dia; e.width = dia; e.yaw = 0
            e.center = SIMD3(f.center.x, planeY, f.center.y)
        } else if e.shape == .cylinder { e.shape = .box }
    }
    return (e, d)
}

// MARK: - SPEC §13 shape detection

/// Mid-height (planeY + 2 cm ... top - 2 cm) points of the object, which excludes floor noise and the top
/// surface / its edge bleed. `circle` / `rect` = median distance to a robust circle fit / to the footprint
/// rectangle's outline, both divided by the rectangle's half-size sqrt(L/2 * W/2). `coverage` = fraction of
/// 36 x 10° sectors around the circle center holding >= 3 points.
struct ShapeFeatures { var circle: Float; var rect: Float; var coverage: Float; var center: SIMD2<Float>; var radius: Float }

func shapeFeatures(_ pts: [SIMD3<Float>], planeY: Float, height: Float, rect: (center: SIMD2<Float>, size: SIMD2<Float>, angle: Float)) -> ShapeFeatures? {
    let lo = planeY + 0.02, hi = planeY + height - 0.02
    let xz = pts.filter { $0.y > lo && $0.y < hi }.map { SIMD2($0.x, $0.z) }
    guard xz.count >= 50, rect.size.y > 0 else { return nil }
    guard var (c, r) = kasaCircle(xz) else { return nil }
    // One robust refit: drop points beyond 3 x median residual + 2 mm (e.g. a rim or a handle).
    var res = xz.map { abs(simd_distance($0, c) - r) }
    let cut = 3 * medianOf(res) + 0.002
    if let fit = kasaCircle(xz.indices.filter { res[$0] < cut }.map { xz[$0] }) { (c, r) = fit }
    res = xz.map { abs(simd_distance($0, c) - r) }
    let u = SIMD2<Float>(cos(rect.angle), sin(rect.angle)), v = SIMD2<Float>(-u.y, u.x)
    let a = rect.size.x / 2, b = rect.size.y / 2, half = (a * b).squareRoot()
    let rres = xz.map { q -> Float in
        let d = q - rect.center
        return min(abs(a - abs(simd_dot(d, u))), abs(b - abs(simd_dot(d, v))))
    }
    var sectors = [Int](repeating: 0, count: 36)
    for q in xz { sectors[sectorIndex(q - c)] += 1 }
    return ShapeFeatures(circle: medianOf(res) / half, rect: medianOf(rres) / half,
                         coverage: Float(sectors.filter { $0 >= 3 }.count) / 36, center: c, radius: r)
}

@inline(__always) func sectorIndex(_ d: SIMD2<Float>) -> Int {
    min(35, max(0, Int((atan2(d.y, d.x) + .pi) / (2 * .pi) * 36)))
}

/// Thresholds (device logs 2026-10-02, 11 scans): cylinder circle 0.034 / rect 0.126; boxes circle >= 0.125
/// and circle/rect >= 1.3. Cylinder: circle < 0.06, circle < 0.5 x rect, coverage >= 0.75 (a full round
/// wall, not an arc). Irregular: neither fits (both > 0.3). Else box.
func classify(_ f: ShapeFeatures) -> ShapeKind {
    if f.circle < 0.06 && f.circle < 0.5 * f.rect && f.coverage >= 0.75 { return .cylinder }
    if f.circle > 0.3 && f.rect > 0.3 { return .irregular }
    return .box
}

/// Algebraic (Kasa) least-squares circle in Double.
func kasaCircle(_ pts: [SIMD2<Float>]) -> (SIMD2<Float>, Float)? {
    guard pts.count >= 3 else { return nil }
    let o = pts.reduce(.zero, +) / Float(pts.count)   // center the data for conditioning
    var m = simd_double3x3(), rhs = SIMD3<Double>.zero
    for q in pts {
        let x = Double(q.x - o.x), z = Double(q.y - o.y), row = SIMD3(2 * x, 2 * z, 1)
        m += simd_double3x3(rows: [row * row.x, row * row.y, row * row.z])
        rhs += row * (x * x + z * z)
    }
    guard abs(m.determinant) > 1e-18 else { return nil }
    let s = m.inverse * rhs
    let r2 = s.z + s.x * s.x + s.y * s.y
    guard r2 > 0 else { return nil }
    return (o + SIMD2(Float(s.x), Float(s.y)), Float(r2.squareRoot()))
}

/// SPEC §13 E2: max over 1 cm height bands of the band's p90 radius about the axis, only for bands that go
/// all the way round (>= 60 % of 36 sectors with >= 2 points, >= 50 points): a lid rim is a full ring and
/// counts, edge bleed is patchy and does not. Bands start `cylinderBase` above the plane: glossy-floor
/// noise forms a full ring around the base too (device log 113528: p95 14 cm at h 1-4 cm vs 13.3 rim).
/// ponytail: fixed base offset; estimate it from the floor's noise if low flanges on matte floors matter.
func cylinderDiameter(_ pts: [SIMD3<Float>], center c: SIMD2<Float>, planeY: Float, _ p: Params) -> Float? {
    var bands: [Int: [SIMD2<Float>]] = [:]
    let lo = planeY + p.cylinderBase
    for q in pts where q.y >= lo { bands[Int(((q.y - lo) / p.binSize).rounded(.down)), default: []].append(SIMD2(q.x, q.z) - c) }
    var best: Float?
    for band in bands.values where band.count >= 50 {
        var sectors = [Int](repeating: 0, count: 36)
        for d in band { sectors[sectorIndex(d)] += 1 }
        guard Float(sectors.filter { $0 >= 2 }.count) / 36 >= 0.6 else { continue }
        let r = band.map { simd_length($0) }.sorted()
        let p90 = r[min(r.count - 1, Int(0.9 * Float(r.count - 1)))]
        best = max(best ?? 0, p90)
    }
    return best.map { 2 * $0 }
}

/// Cells with >= minCellPoints points and >= slabNeighbours occupied (present in `counts`) 8-neighbours.
func denseCells(_ counts: [Int: Int], _ p: Params) -> [Int: Int] {
    counts.filter { k, c in
        guard c >= p.minCellPoints else { return false }
        let ix = k >> 32, iz = Int(Int32(truncatingIfNeeded: k))
        var n = 0
        for dx in -1...1 { for dz in -1...1 where (dx != 0 || dz != 0) && counts[cellKey(ix + dx, iz + dz)] != nil { n += 1 } }
        return n >= p.slabNeighbours
    }
}

/// Robust max y (C4): the highest 1 cm y-bin b such that some 3x3-cell XZ neighbourhood holds
/// >= heightSupport points in bins b-1...b (the bin below absorbs a flat top's noise straddling a bin
/// edge). Returns the median y of those points, so a flat top reads its surface, not its noise ceiling;
/// isolated flyers above the object lack support. A 3 cm-wide protrusion has support and counts.
func supportedTop(_ pts: [SIMD3<Float>], _ p: Params) -> Float? {
    let inv = 1 / p.gridCell, binInv = 1 / p.binSize
    func key(_ q: SIMD3<Float>) -> (cell: Int, ix: Int, iz: Int, b: Int) {
        let ix = Int((q.x * inv).rounded(.down)), iz = Int((q.z * inv).rounded(.down))
        return (cellKey(ix, iz), ix, iz, Int((q.y * binInv).rounded(.down)))
    }
    var bins: [Int: [Int: Int]] = [:]   // y-bin -> cell -> count
    for q in pts { let k = key(q); bins[k.b, default: [:]][k.cell, default: 0] += 1 }
    for b in bins.keys.sorted(by: >) {
        // Best-supported neighbourhood in this bin (ties -> smaller key): Dictionary order is per-instance
        // random, so "first qualifying cell" made the height non-deterministic run to run.
        var best: (n: Int, k: Int)?
        for k in bins[b]!.keys {
            let ix = k >> 32, iz = Int(Int32(truncatingIfNeeded: k))
            var n = 0
            for dx in -1...1 { for dz in -1...1 { for bb in (b - 1)...b { n += bins[bb]?[cellKey(ix + dx, iz + dz)] ?? 0 } } }
            if n >= p.heightSupport, best == nil || n > best!.n || (n == best!.n && k < best!.k) { best = (n, k) }
        }
        guard let k = best?.k else { continue }
        let ix = k >> 32, iz = Int(Int32(truncatingIfNeeded: k))
        let ys = pts.filter { let q = key($0); return abs(q.ix - ix) <= 1 && abs(q.iz - iz) <= 1 && (b - 1...b).contains(q.b) }.map(\.y)
        return medianOf(ys)
    }
    return nil
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


/// k-th smallest and k-th largest of `vals` (k clamped to the data).
func trimmedRange(_ vals: [Float], _ k: Int) -> (lo: Float, hi: Float) {
    let k = max(1, min(k, vals.count / 4))
    let s = vals.sorted()
    return (s[k - 1], s[s.count - k])
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
        // Fused real surfaces are a ~5 mm-sigma shell with a cm-long outer tail: a fixed handful of trimmed
        // points sits ~3 sigma out on dense clouds, so trim a fraction of the points too.
        let k = max(p.trimPoints, Int(p.trimFraction * Float(pts.count)))
        let ru = trimmedRange(pu, k), rv = trimmedRange(pv, k)
        let inliers = pts.indices.filter {
            pu[$0] >= ru.lo - p.trimMargin && pu[$0] <= ru.hi + p.trimMargin &&
            pv[$0] >= rv.lo - p.trimMargin && pv[$0] <= rv.hi + p.trimMargin
        }.map { pts[$0] }
        r = minAreaRect(inliers)
    }
    guard p.wallBand > 0, r.size.y > 0 else { return r }
    // Each edge = outer half-max of the densest 2.5 mm slab (the wall) within wallBand inside the extent: fused LiDAR walls
    // are a ~5 mm shell with a 1-2 cm outer tail, so the extent overshoots the surface on every side.
    let u = SIMD2<Float>(cos(r.angle), sin(r.angle)), v = SIMD2<Float>(-u.y, u.x)
    func edges(_ axis: SIMD2<Float>, _ size: Float) -> (Float, Float) {
        let proj = pts.map { simd_dot($0, axis) }, c = simd_dot(r.center, axis)
        let band = min(p.wallBand, size / 3)
        // Outer half-max edge of the densest (3-slab smoothed) slab: ~1 sigma outside the shell core.
        func core(_ from: Float, _ to: Float, outward: Int) -> Float {
            let bin: Float = 0.0025, n = max(3, Int((to - from) / bin))
            var count = [Int](repeating: 0, count: n)
            for x in proj where x >= from && x < to { count[min(n - 1, Int((x - from) / bin))] += 1 }
            let sm = count.indices.map { k in count[max(0, k - 1)...min(n - 1, k + 1)].reduce(0, +) }
            var i = sm.indices.max { sm[$0] < sm[$1] }!
            // A second, outer wall (a real step / band protruding past the dense wall) wins if it is a local
            // peak >= 30 % of the main one; a monotonic noise tail never is.
            let floorCount = Float(sm[i]) * 0.3
            var j = i + outward
            while j >= 0 && j < n {
                let inner = sm[j - outward], outer = j + outward >= 0 && j + outward < n ? sm[j + outward] : 0
                if Float(sm[j]) >= floorCount && sm[j] > inner && sm[j] >= outer { i = j }
                j += outward
            }
            let half = sm[i] / 2
            while i + outward >= 0 && i + outward < n && sm[i + outward] >= half { i += outward }
            return from + Float(i) * bin + (outward > 0 ? bin : 0)
        }
        return (core(c - size / 2, c - size / 2 + band, outward: -1), core(c + size / 2 - band, c + size / 2, outward: 1))
    }
    let (u0, u1) = edges(u, r.size.x), (v0, v1) = edges(v, r.size.y)
    let center = u * (u0 + u1) / 2 + v * (v0 + v1) / 2
    return u1 - u0 >= v1 - v0 ? (center, SIMD2(u1 - u0, v1 - v0), r.angle)
                              : (center, SIMD2(v1 - v0, u1 - u0), normAngle(r.angle + .pi / 2))
}
