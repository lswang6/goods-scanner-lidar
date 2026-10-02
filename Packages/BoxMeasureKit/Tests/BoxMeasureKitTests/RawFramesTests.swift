import XCTest
import simd
@testable import BoxMeasureKit

/// ARKit-like intrinsics for a 1920x1440 capturedImage; depth maps are 256x192.
private let K = simd_float3x3(SIMD3(1450, 0, 0), SIMD3(0, 1450, 0), SIMD3(960, 720, 1))
private let res = SIMD2<Float>(1920, 1440)
private let W = 256, H = 192

private func lookAt(_ eye: SIMD3<Float>, _ target: SIMD3<Float>) -> simd_float4x4 {
    let f = simd_normalize(target - eye), r = simd_normalize(simd_cross(f, SIMD3(0, 1, 0))), u = simd_cross(r, f)
    return simd_float4x4(SIMD4(r, 0), SIMD4(u, 0), SIMD4(-f, 0), SIMD4(eye, 1))
}

/// Depth map (meters along -z) for a scene given as ray -> nearest hit distance `t` (ray dir has camera z = -1,
/// so t is the depth). Exact inverse of DepthCamera.
private func render(_ transform: simd_float4x4, _ hit: (SIMD3<Float>, SIMD3<Float>) -> Float?) -> [Float] {
    let cam = DepthCamera(width: W, height: H, intrinsics: K, imageResolution: res, transform: transform)
    let o = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    var d = [Float](repeating: .nan, count: W * H)
    for v in 0..<H { for u in 0..<W {
        let c = cam.cameraPoint(u, v, 1)
        let w = transform * SIMD4(c, 0)
        if let t = hit(o, SIMD3(w.x, w.y, w.z)) { d[v * W + u] = t }
    } }
    return d
}

/// Floor y = 0 plus `b` (oriented box on the floor).
private func boxScene(_ b: Box) -> (SIMD3<Float>, SIMD3<Float>) -> Float? { { o, d in boxHit(b, o, d)?.t } }

/// Floor + the 5 visible faces of `b`, each seen displaced outward (toward the camera) along its normal by
/// `bias(θ)` m (walls tapered to 0 at the top edge), θ = this ray's incidence: the per-face model the estimator corrects.
private func biasedBoxScene(_ b: Box, _ bias: @escaping (Float) -> Float) -> (SIMD3<Float>, SIMD3<Float>) -> Float? {
    let c = SIMD3(b.cx, b.baseY + b.h / 2, b.cz), up = SIMD3<Float>(0, 1, 0)
    // (normal, half-extent along normal, in-plane axes with half extents)
    let faces: [(SIMD3<Float>, Float, SIMD3<Float>, Float, SIMD3<Float>, Float)] = [
        (b.u, b.l / 2, b.v, b.w / 2, up, b.h / 2), (-b.u, b.l / 2, b.v, b.w / 2, up, b.h / 2),
        (b.v, b.w / 2, b.u, b.l / 2, up, b.h / 2), (-b.v, b.w / 2, b.u, b.l / 2, up, b.h / 2),
        (up, b.h / 2, b.u, b.l / 2, b.v, b.w / 2)]
    return { o, d in
        var best: Float = d.y < 0 ? -o.y / d.y : .infinity
        for (n, hn, a1, h1, a2, h2) in faces {
            let dn = simd_dot(d, n)
            guard dn < 0 else { continue }
            let full = bias(acos(-dn / simd_length(d)) * 180 / .pi)
            func hit(_ off: Float) -> Float { simd_dot(c + n * (hn + off) - o, n) / dn }
            // Walls attach at the top edge (device logs: +0.8 cm in the top 4 cm, full offset from ~8 cm down).
            let taper = n.y > 0.5 ? 1 : min(1, max(0, (c.y + b.h / 2 - (o + d * hit(full)).y) / 0.08))
            let t = hit(full * taper)
            let q = o + d * t - c
            if t > 0, t < best, abs(simd_dot(q, a1)) <= h1, abs(simd_dot(q, a2)) <= h2 { best = t }
        }
        return best.isFinite ? best : nil
    }
}

/// Nearest hit; `n` = box face normal (nil for the floor).
private func boxHit(_ b: Box, _ o: SIMD3<Float>, _ d: SIMD3<Float>) -> (t: Float, n: SIMD3<Float>?)? {
    do {
        var best: Float = .infinity, normal: SIMD3<Float>?
        if d.y < 0 { best = -o.y / d.y }
        // Slab test in box-local axes (u, y, v).
        let c = SIMD3(b.cx, b.baseY + b.h / 2, b.cz)
        let lo = SIMD3(simd_dot(o - c, b.u), o.y - c.y, simd_dot(o - c, b.v))
        let ld = SIMD3(simd_dot(d, b.u), d.y, simd_dot(d, b.v))
        let half = SIMD3(b.l / 2, b.h / 2, b.w / 2)
        var t0: Float = 0, t1: Float = .infinity
        for k in 0..<3 {
            if abs(ld[k]) < 1e-9 { if abs(lo[k]) > half[k] { t0 = .infinity }; continue }
            let a = (-half[k] - lo[k]) / ld[k], z = (half[k] - lo[k]) / ld[k]
            t0 = max(t0, min(a, z)); t1 = min(t1, max(a, z))
        }
        if t0 <= t1, t0 > 0, t0 < best {
            best = t0
            let lp = lo + ld * t0
            let k = (0..<3).max { abs(lp[$0]) / half[$0] < abs(lp[$1]) / half[$1] }!
            let axes = [b.u, SIMD3<Float>(0, 1, 0), b.v]
            normal = axes[k] * (lp[k] > 0 ? 1 : -1)
        }
        return best.isFinite ? (best, normal) : nil
    }
}

private func tmpDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("bmk-\(UUID().uuidString)")
    return u
}

extension BoxMeasureKitTests {
    func testUnprojectPlane() {
        // Camera 1.5 m in front of a plane, rotated 90° about y and translated.
        let t = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0))) * simd_float4x4(diagonal: .one)
        var m = t; m.columns.3 = SIMD4(1, 2, 3, 1)
        let depth = [Float](repeating: 1.5, count: W * H)
        let pts = unproject(depth: depth, confidence: nil, width: W, height: H, intrinsics: K, imageResolution: res, transform: m, minConfidence: 1)
        XCTAssertEqual(pts.count, W * H)
        let fwd = -SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z), pos = SIMD3<Float>(1, 2, 3)
        for p in pts { XCTAssertEqual(simd_dot(p - pos, fwd), 1.5, accuracy: 1e-4) }
        // Intrinsics scaled to depth pixels, pixel-center origin: (960 + 0.5) * 256/1920 - 0.5.
        let cam = DepthCamera(width: W, height: H, intrinsics: K, imageResolution: res, transform: m)
        XCTAssertEqual(cam.cx, 127.5667, accuracy: 1e-3); XCTAssertEqual(cam.cy, 95.5667, accuracy: 1e-3)
        XCTAssertEqual(cam.fx, 1450 * 256 / 1920, accuracy: 1e-3)
        // Confidence window + stride.
        var conf = [UInt8](repeating: 2, count: W * H); conf[0] = 0; conf[1] = 1
        XCTAssertEqual(unproject(depth: depth, confidence: conf, camera: cam, minConfidence: 2).count, W * H - 2)
        XCTAssertEqual(unproject(depth: depth, confidence: conf, camera: cam, minConfidence: 1, maxConfidence: 1).count, 1)
        XCTAssertEqual(unproject(depth: depth, confidence: nil, camera: cam, minConfidence: 2, stride: 2).count, W * H / 4)
        XCTAssertEqual(scaledDepth(depth, by: 2)[7], 3)
    }

    func testRawFramesRoundTrip() throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var rng = SplitMix64(state: 3)
        var index = RawFramesIndex(width: W, height: H, liveSource: .smoothed, fuseFrames: 3)
        index.lockTime = 1.25; index.lockSeed = SIMD3(0.1, 0.2, 0.3); index.lockPlaneY = -0.9; index.seedOnSide = true
        let w = try RawFramesWriter(dir: dir, index: index)
        var written: [RawFrame] = []
        for i in 0..<3 {
            let h = { (0..<W * H).map { _ in Float16(bitPattern: UInt16.random(in: 0...UInt16.max, using: &rng)) } }
            let c = { (0..<W * H).map { _ in UInt8.random(in: 0...2, using: &rng) } }
            var f = RawFrame(timestamp: 1 + Double(i) * 0.2, phase: UInt8(i % 2), tracking: 2, thermal: UInt8(i),
                             transform: lookAt(SIMD3(Float(i), 1, 2), .zero), intrinsics: K, imageResolution: res,
                             raw: i == 2 ? nil : h(), rawConf: i == 2 ? nil : c(), smoothed: h(), smoothedConf: c())
            f.ring = i == 0; f.lock = i == 1; f.estimated = i == 2
            try w.append(f); written.append(f)
        }
        try w.close()
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("frames.bin").path)[.size] as? Int,
                       3 * (120 + W * H * 6))
        let r = try RawFrames(dir: dir)
        XCTAssertEqual(r.count, 3)
        XCTAssertEqual(r.index.lockSeed, index.lockSeed); XCTAssertEqual(r.index.seedOnSide, true); XCTAssertEqual(r.index.liveSource, .smoothed)
        for (i, a) in written.enumerated() {
            let b = r[i]
            XCTAssertEqual(a.timestamp, b.timestamp); XCTAssertEqual(a.phase, b.phase); XCTAssertEqual(a.thermal, b.thermal)
            XCTAssertEqual(a.tracking, b.tracking)
            XCTAssertEqual([a.ring, a.lock, a.estimated], [b.ring, b.lock, b.estimated])
            XCTAssertEqual(a.transform, b.transform); XCTAssertEqual(a.intrinsics, b.intrinsics); XCTAssertEqual(a.imageResolution, b.imageResolution)
            XCTAssertEqual(a.raw?.map(\.bitPattern), b.raw?.map(\.bitPattern))
            XCTAssertEqual(a.smoothed?.map(\.bitPattern), b.smoothed?.map(\.bitPattern))
            XCTAssertEqual(a.rawConf, b.rawConf); XCTAssertEqual(a.smoothedConf, b.smoothedConf)
            XCTAssertEqual(r.meta(i).flags & 64 != 0, a.lock)
        }
        XCTAssertNil(r[2].raw)
    }

    /// Box + floor raycast from 8 poses, written with the shared writer, re-fused with the app's policy.
    func testRefuseSyntheticBox() throws {
        let b = Box(cx: 0.05, cz: -0.03, baseY: 0, l: 0.4, w: 0.3, h: 0.3, yaw: 20 * deg)
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var index = RawFramesIndex(width: W, height: H, liveSource: .smoothed, fuseFrames: 3)
        index.lockTime = 0; index.lockSeed = b.top; index.lockPlaneY = 0; index.seedOnSide = false
        let w = try RawFramesWriter(dir: dir, index: index)
        let scene = boxScene(b)
        func frame(_ t: Double, _ a: Float, phase: UInt8) -> RawFrame {
            let m = lookAt(SIMD3(b.cx + 1.2 * cos(a), 0.9, b.cz + 1.2 * sin(a)), SIMD3(b.cx, 0.15, b.cz))
            return RawFrame(timestamp: t, phase: phase, tracking: 2, thermal: 0, transform: m, intrinsics: K, imageResolution: res,
                            raw: nil, rawConf: nil, smoothed: render(m, scene).map(Float16.init), smoothedConf: nil)
        }
        var lock = frame(0, 0.1, phase: 0); lock.ring = true; lock.lock = true
        try w.append(lock)
        for i in 0..<8 {
            var f = frame(0.2 * Double(i + 1), 0.1 + Float(i) / 8 * 2 * .pi + 0.05, phase: 1)
            f.estimated = i == 3 || i == 7
            try w.append(f)
        }
        try w.close()
        let r = try RawFrames(dir: dir)
        var p = Params.fused
        p.incidenceBias = 0   // unbiased synthetic depth: the incidence-bias model must stay off
        let fused = try XCTUnwrap(r.refuse(params: p))
        XCTAssertEqual(fused.frames, 9); XCTAssertEqual(fused.estimates, 2)
        print("  refuse: \(fused.fusion.cloud.count) voxels")
        let t = fused.fusion.tagged()
        check(BoxMeasurer.estimate(points: t.points, seed: b.top, params: p, incidence: t.incidence), b)
    }

    /// Overhead walk-around (camera 0.7 m above the top, 0.45-0.6 m out) of a box whose faces carry the fitted
    /// incidence bias: the plain fused estimate reads ~2 cm per wall too large, the corrected one is within 1.5 cm.
    func testRefuseSyntheticBiasedBox() throws {
        let b = Box(cx: 0.05, cz: -0.03, baseY: 0, l: 0.4, w: 0.3, h: 0.3, yaw: 20 * deg)
        let p = Params.fused
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var index = RawFramesIndex(width: W, height: H, liveSource: .smoothed, fuseFrames: 3)
        index.lockTime = 0; index.lockSeed = b.top; index.lockPlaneY = 0; index.seedOnSide = false
        let w = try RawFramesWriter(dir: dir, index: index)
        let scene = biasedBoxScene(b) { incidenceBias(thetaDeg: $0, range: 0.8, p) }
        for i in 0..<17 {
            let a = Float(i) / 16 * 2 * .pi + 0.1, r: Float = i % 2 == 0 ? 0.45 : 0.6
            let m = lookAt(SIMD3(b.cx + r * cos(a), 1.0, b.cz + r * sin(a)), SIMD3(b.cx, 0.1, b.cz))
            var f = RawFrame(timestamp: 0.2 * Double(i), phase: i == 0 ? 0 : 1, tracking: 2, thermal: 0, transform: m, intrinsics: K,
                             imageResolution: res, raw: nil, rawConf: nil, smoothed: render(m, scene).map(Float16.init), smoothedConf: nil)
            f.ring = i == 0; f.lock = i == 0; f.estimated = i % 4 == 0 && i > 0
            try w.append(f)
        }
        try w.close()
        let fused = try XCTUnwrap(try RawFrames(dir: dir).refuse(params: p)).fusion.tagged()
        let plain = try XCTUnwrap(BoxMeasurer.estimate(points: fused.points, seed: b.top, params: p))
        let fixed = try XCTUnwrap(BoxMeasurer.estimate(points: fused.points, seed: b.top, params: p, incidence: fused.incidence))
        print(String(format: "  biased synthetic: plain %.1f x %.1f x %.1f  corrected %.1f x %.1f x %.1f", plain.length * 100, plain.width * 100,
                     plain.height * 100, fixed.length * 100, fixed.width * 100, fixed.height * 100))
        for f in fixed.surfaces ?? [] { print(String(format: "    %@ θ %.0f° δ %.1f cm", f.face, f.thetaDeg, f.delta * 100)) }
        XCTAssertGreaterThan(plain.length, 0.42)
        XCTAssertEqual(fixed.length, 0.40, accuracy: 0.015); XCTAssertEqual(fixed.width, 0.30, accuracy: 0.015)
        XCTAssertEqual(fixed.height, 0.30, accuracy: 0.015)
    }

    func testDropGrazing() {
        let cam = DepthCamera(width: W, height: H, intrinsics: K, imageResolution: res, transform: matrix_identity_float4x4)
        let interior = (W - 2) * (H - 2)
        var front = [Float](repeating: 1, count: W * H)
        dropGrazing(depth: &front, camera: cam, maxDegrees: 60)
        // Frontal plane: incidence <= ~33° at the corners, every interior pixel kept.
        XCTAssertEqual(front.filter { !$0.isNaN }.count, interior)
        // Plane through (0,0,-1) tilted 60° about x: incidence ~34°...86° across the image.
        let n = SIMD3<Float>(0, sin(60 * deg), cos(60 * deg)), p0 = SIMD3<Float>(0, 0, -1)
        var tilted = [Float](repeating: .nan, count: W * H), angle = [Float](repeating: 0, count: W * H)
        for v in 0..<H { for u in 0..<W {
            let dir = cam.cameraPoint(u, v, 1)
            tilted[v * W + u] = simd_dot(n, p0) / simd_dot(n, dir)
            angle[v * W + u] = acos(abs(simd_dot(n, dir)) / simd_length(dir)) / deg
        } }
        dropGrazing(depth: &tilted, camera: cam, maxDegrees: 60)
        var grazing = 0, kept = 0
        for v in 1..<(H - 1) { for u in 1..<(W - 1) {
            let i = v * W + u
            if angle[i] > 61 { grazing += 1; XCTAssert(tilted[i].isNaN, "grazing \(angle[i])° kept") }
            if angle[i] < 59 { kept += 1; XCTAssertFalse(tilted[i].isNaN, "\(angle[i])° dropped") }
        } }
        XCTAssertGreaterThan(grazing, 1000); XCTAssertGreaterThan(kept, 1000)
    }
}

extension BoxMeasureKitTests {
    /// Grazing-only shell 2 cm in front of a head-on wall (normal +z) is dropped; a grazing-only patch far away is kept.
    func testHeadOnFiltered() {
        var c = VoxelCloud(center: .zero, radius: 3)
        var wall: [SIMD3<Float>] = [], shell: [SIMD3<Float>] = [], far: [SIMD3<Float>] = []
        for i in 0..<40 { for j in 0..<40 {
            let x = Float(i) * 0.005 + 0.0025, y = Float(j) * 0.005 + 0.0025
            wall.append(SIMD3(x, y, 0.0025)); shell.append(SIMD3(x, y, 0.0225)); far.append(SIMD3(x + 1, y, 0.0025))
        } }
        for _ in 0..<2 {
            c.insert(wall, incidence: Array(repeating: SIMD4(0, 0, 1, 1), count: wall.count))
            c.insert(shell + far, incidence: Array(repeating: SIMD4(0, 0, 1, 0.2), count: shell.count + far.count))
        }
        let t = c.headOnFiltered()
        XCTAssertEqual(t.points.count, wall.count + far.count)
        XCTAssertFalse(t.points.contains { abs($0.z - 0.0225) < 1e-4 })
        XCTAssertEqual(t.headOn.filter { $0 }.count, wall.count)
        XCTAssertEqual(c.centroids().count, 3 * wall.count)   // unfiltered API unchanged
        var e = BoxEstimate(length: 0.2, width: 0.2, height: 0.2, center: SIMD3(0.1, 0, 0.1), yaw: 0, planeY: 0, pointCount: 0)
        e.height = 0.5
        _ = headOnCoverage(t, e)   // smoke
    }

    /// Device log F (2026-10-02 18:35, 40x30x30 box, phone at mid-wall height; every 2nd scan frame, 12 MB):
    /// walls were seen head-on, so head-on-aware fusion drops their grazing shells (L 42.9 -> 41.3). The top was only seen
    /// grazing (camera ~12 cm above it): H keeps the old behaviour and top coverage is low; the incidence-bias
    /// correction then brings H down.
    func testRefuseDeviceLogF() throws {
        guard let dir = deviceFixture("raw-20261002-183534") else { throw XCTSkip("device fixture missing (private, gitignored)") }
        let frames = try RawFrames(dir: dir)
        var p = Params.fused
        p.seedOnSide = frames.index.seedOnSide ?? false
        let seed = try XCTUnwrap(frames.index.lockSeed)
        func run(_ headOn: Bool) throws -> (BoxEstimate, (walls: Float, top: Float)) {
            var o = RefuseOptions(); o.headOn = headOn
            let f = try XCTUnwrap(frames.refuse(params: p, options: o)).fusion.tagged()
            let e = try XCTUnwrap(BoxMeasurer.estimate(points: f.points, seed: seed, params: p))
            print(String(format: "  F headOn=%d: %.1f x %.1f x %.1f", headOn ? 1 : 0, e.length * 100, e.width * 100, e.height * 100))
            return (e, headOnCoverage(f, e))
        }
        let (old, _) = try run(false), (new, cov) = try run(true)
        XCTAssertGreaterThan(old.length, 0.42)
        XCTAssertEqual(new.length, 0.40, accuracy: 0.015); XCTAssertEqual(new.width, 0.30, accuracy: 0.015)
        XCTAssertEqual(new.height, old.height, accuracy: 0.005)
        XCTAssertGreaterThan(cov.walls, 0.8); XCTAssertLessThan(cov.top, 0.3)
        // + incidence-bias correction (Params.fused model): the grazing-only top comes down to ~30.
        var o = RefuseOptions(); o.headOn = true
        let f = try XCTUnwrap(frames.refuse(params: p, options: o)).fusion.tagged()
        let fixed = try XCTUnwrap(BoxMeasurer.estimate(points: f.points, seed: seed, params: p, incidence: f.incidence))
        print(String(format: "  F corrected: %.1f x %.1f x %.1f", fixed.length * 100, fixed.width * 100, fixed.height * 100))
        XCTAssertEqual(fixed.length, 0.40, accuracy: 0.015); XCTAssertEqual(fixed.width, 0.30, accuracy: 0.015)
        XCTAssertEqual(fixed.height, 0.30, accuracy: 0.015)
        XCTAssertEqual(fixed.surfaces?.count, 5)
    }
}
