import XCTest
import simd
@testable import BoxMeasureKit

/// Params for fused (voxel-centroid) input: defaults pass (see report); ScanSession uses `Params()` too.
func voxelTestParams() -> Params { Params.fused }

/// Full walk-around capture (SPEC §9 B3): `views` cameras on a circle around the scene, each sees every
/// horizontal patch and the side faces that face it, +/-3 mm noise, plus flying-pixel outliers in mid-air.
/// No occlusion beyond back-face culling (floor under a box footprint is never sampled).
struct Orbit {
    var rng = SplitMix64(state: 7)
    var pts: [SIMD3<Float>] = []
    var density: Float = 30000      // pts/m^2 per view on horizontal surfaces; sides get half
    let noise: Float = 0.003

    mutating func r(_ a: Float, _ b: Float) -> Float { Float.random(in: a...b, using: &rng) }
    mutating func add(_ q: SIMD3<Float>) { pts.append(q + SIMD3(r(-noise, noise), r(-noise, noise), r(-noise, noise))) }

    /// `boxes` stacked bottom-up (pallet first). Floor = disc of `floorRadius` around the first box.
    mutating func capture(_ boxes: [Box], floorRadius: Float, camRadius: Float, camHeight: Float, views: Int = 12) {
        let c = SIMD2(boxes[0].cx, boxes[0].cz)
        for i in 0..<views {
            let a = Float(i) / Float(views) * 2 * .pi + 0.1
            let cam = SIMD3(c.x + camRadius * cos(a), camHeight, c.y + camRadius * sin(a))
            // Floor ring.
            let n = Int(Float.pi * floorRadius * floorRadius * density)
            for _ in 0..<n {
                let x = c.x + r(-floorRadius, floorRadius), z = c.y + r(-floorRadius, floorRadius)
                guard (x - c.x) * (x - c.x) + (z - c.y) * (z - c.y) <= floorRadius * floorRadius,
                      !boxes.contains(where: { $0.baseY == 0 && $0.covers(x, z) }) else { continue }
                add(SIMD3(x, 0, z))
            }
            for (j, b) in boxes.enumerated() {
                let above = boxes[(j + 1)...]
                for _ in 0..<Int(b.l * b.w * density * (j + 1 < boxes.count ? 0.5 : 1)) {   // pallet top: slatted, sparser
                    let q = b.at(r(-b.l / 2, b.l / 2), r(-b.w / 2, b.w / 2), b.baseY + b.h)
                    if !above.contains(where: { $0.covers(q.x, q.z) }) { add(q) }
                }
                for (normal, half, along) in [(b.u, b.l / 2, b.w), (-b.u, b.l / 2, b.w), (b.v, b.w / 2, b.l), (-b.v, b.w / 2, b.l)] {
                    let fc = SIMD3(b.cx, b.baseY + b.h / 2, b.cz) + normal * half
                    guard simd_dot(normal, cam - fc) > 0 else { continue }
                    let t = SIMD3(-normal.z, 0, normal.x)
                    for _ in 0..<Int(along * b.h * density / 2) {
                        add(fc + t * r(-along / 2, along / 2) + SIMD3(0, r(-b.h / 2, b.h / 2), 0))
                    }
                }
            }
            // Flying pixels: scattered between camera and the top box, never repeating a voxel.
            let top = boxes.last!.top
            for _ in 0..<300 { pts.append(cam + (top - cam) * r(0.2, 1.1) + SIMD3(r(-0.3, 0.3), r(-0.3, 0.3), r(-0.3, 0.3))) }
        }
    }

    func fused(center: SIMD3<Float>) -> [SIMD3<Float>] {
        var cloud = VoxelCloud(voxelSize: 0.005, center: center)
        cloud.insert(pts)
        return cloud.centroids(minHits: 2)
    }
}

extension BoxMeasureKitTests {
    func testVoxelCloudBasics() {
        var c = VoxelCloud(voxelSize: 0.01, center: .zero, radius: 1, maxVoxels: 3)
        c.insert([SIMD3(0.001, 0, 0), SIMD3(0.003, 0.002, 0), SIMD3(-0.005, 0, 0), SIMD3(5, 0, 0)])  // last: outside radius
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c.centroids(minHits: 2), [SIMD3(0.002, 0.001, 0)])
        XCTAssertEqual(c.centroids(minHits: 1).count, 2)
        c.insert([SIMD3(0.5, 0, 0), SIMD3(0.6, 0, 0)])  // cap: 0.5 fills it; 0.6 evicts the single-hit voxels
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c.centroids(minHits: 1).count, 2)
        c.removeAll()
        XCTAssertEqual(c.count, 0)
        // Packing: negative / positive neighbours and extremes never collide.
        let idx = [-(1 << 20), -1, 0, 1, (1 << 20) - 1]
        var keys = Set<Int>()
        for x in idx { for y in idx { for z in idx { keys.insert(voxelKey(x, y, z)) } } }
        XCTAssertEqual(keys.count, idx.count * idx.count * idx.count)
    }

    func testOrbitFusedBoxOnFloor() {
        let b = Box(cx: 0.1, cz: -0.05, baseY: 0, l: 0.4, w: 0.3, h: 0.2, yaw: 30 * deg)
        var o = Orbit()
        o.capture([b], floorRadius: 1.0, camRadius: 1.0, camHeight: 1.3)
        let seed = b.top + SIMD3(0.02, 0, -0.01)
        let pts = o.fused(center: seed)
        print("  orbit: \(o.pts.count) raw -> \(pts.count) voxels")
        check(BoxMeasurer.estimate(points: pts, seed: seed, params: voxelTestParams()), b)
    }

    func testOrbitFusedBoxOnPallet() {
        let pallet = Box(cx: 0, cz: 0, baseY: 0, l: 1.2, w: 1.0, h: 0.15, yaw: 0)
        let b = Box(cx: -0.1, cz: 0.1, baseY: 0.15, l: 0.4, w: 0.3, h: 0.2, yaw: 30 * deg)
        var o = Orbit()
        o.capture([pallet, b], floorRadius: 1.4, camRadius: 1.2, camHeight: 1.4)
        let pts = o.fused(center: b.top)
        print("  pallet orbit: \(o.pts.count) raw -> \(pts.count) voxels")
        check(BoxMeasurer.estimate(points: pts, seed: b.top, params: voxelTestParams()), b)
    }

    func testOrbitFusedLargeBox() {
        let b = Box(cx: 0, cz: 0, baseY: 0, l: 1.2, w: 1.0, h: 1.0, yaw: 15 * deg)
        var o = Orbit(density: 20000)
        o.capture([b], floorRadius: 1.6, camRadius: 1.6, camHeight: 1.6)
        let pts = o.fused(center: b.top)
        print("  large orbit: \(o.pts.count) raw -> \(pts.count) voxels")
        check(BoxMeasurer.estimate(points: pts, seed: b.top, params: voxelTestParams()), b, tol: 0.02)
    }
}

/// SPEC §10 C4: irregular objects measured by maximum extent (orbit + VoxelCloud, default Params).
extension BoxMeasureKitTests {
    /// Union footprint / height check; `b` = expected bounding box.
    func irregular(_ parts: [Box], seed: SIMD3<Float>, expect b: Box, params: Params = voxelTestParams(),
                   file: StaticString = #filePath, line: UInt = #line) -> BoxEstimate? {
        var o = Orbit()
        o.capture(parts, floorRadius: 1.2, camRadius: 1.2, camHeight: 1.4)
        let e = BoxMeasurer.estimate(points: o.fused(center: seed), seed: seed, params: params)
        if let e {
            print(String(format: "  irregular: L %.4f (%.4f)  W %.4f (%.4f)  H %.4f (%.4f)  planeY %.4f",
                         e.length, b.l, e.width, b.w, e.height, b.h, e.planeY))
        }
        return e
    }

    func assertDims(_ e: BoxEstimate?, _ l: Float, _ w: Float, _ h: Float, tol: Float, hTol: Float = 0.01,
                    file: StaticString = #filePath, line: UInt = #line) {
        guard let e else { return XCTFail("nil estimate", file: file, line: line) }
        XCTAssertEqual(e.length, l, accuracy: tol, "length", file: file, line: line)
        XCTAssertEqual(e.width, w, accuracy: tol, "width", file: file, line: line)
        XCTAssertEqual(e.height, h, accuracy: hTol, "height", file: file, line: line)
        XCTAssertEqual(e.planeY, 0, accuracy: 0.005, "planeY", file: file, line: line)
    }

    /// (a) Tapered stack 50x40 / 40x30 / 30x20, 10 cm tiers: footprint = bottom tier, height = 30.
    func testMaxExtentTaperedStack() {
        let tiers = [Box(cx: 0, cz: 0, baseY: 0, l: 0.5, w: 0.4, h: 0.1, yaw: 20 * deg),
                     Box(cx: 0, cz: 0, baseY: 0.1, l: 0.4, w: 0.3, h: 0.1, yaw: 20 * deg),
                     Box(cx: 0, cz: 0, baseY: 0.2, l: 0.3, w: 0.2, h: 0.1, yaw: 20 * deg)]
        let expect = Box(cx: 0, cz: 0, baseY: 0, l: 0.5, w: 0.4, h: 0.3, yaw: 20 * deg)
        assertDims(irregular(tiers, seed: tiers[2].top, expect: expect), 0.5, 0.4, 0.3, tol: 0.015)
        // Flag really switches: the v2 top slab measures the top tier only.
        var p = voxelTestParams(); p.maxExtent = false
        assertDims(irregular(tiers, seed: tiers[2].top, expect: Box(cx: 0, cz: 0, baseY: 0, l: 0.3, w: 0.2, h: 0.3, yaw: 20 * deg), params: p), 0.3, 0.2, 0.3, tol: 0.015)
    }

    /// (b) L shape: 40x30x20 + 20x30x40 side by side -> union rect 60x30, height 40. Seed on the LOW part.
    func testMaxExtentLShape() {
        let low = Box(cx: 0, cz: 0, baseY: 0, l: 0.4, w: 0.3, h: 0.2, yaw: 0)
        let tall = Box(cx: 0.3, cz: 0, baseY: 0, l: 0.2, w: 0.3, h: 0.4, yaw: 0)
        let expect = Box(cx: 0.1, cz: 0, baseY: 0, l: 0.6, w: 0.3, h: 0.4, yaw: 0)
        assertDims(irregular([low, tall], seed: low.top, expect: expect), 0.6, 0.3, 0.4, tol: 0.015)
    }

    /// (c) Documented: a thin protrusion with real support COUNTS (max extent). 3 cm-wide, 25 cm-long
    /// handle standing 5 cm above a 40x30x20 box -> height 25, footprint unchanged 40x30.
    func testMaxExtentHandleCounts() {
        let b = Box(cx: 0, cz: 0, baseY: 0, l: 0.4, w: 0.3, h: 0.2, yaw: 30 * deg)
        let handle = Box(cx: 0, cz: 0, baseY: 0.2, l: 0.25, w: 0.03, h: 0.05, yaw: 30 * deg)
        let expect = Box(cx: 0, cz: 0, baseY: 0, l: 0.4, w: 0.3, h: 0.25, yaw: 30 * deg)
        assertDims(irregular([b, handle], seed: b.top + SIMD3(0, 0, 0.1), expect: expect), 0.4, 0.3, 0.25, tol: 0.01)
    }
}

extension BoxMeasureKitTests {
    /// Device logs 2026-10-02: a glossy floor filled the cap and the box's far side was never stored.
    /// Floor voxels (y <= floorY) get at most half the cap; a wall seen afterwards still gets in.
    func testVoxelCapKeepsRoomAboveFloor() {
        var c = VoxelCloud(voxelSize: 0.005, center: .zero, radius: 2, maxVoxels: 1000, floorY: 0.015)
        var floor: [SIMD3<Float>] = []
        for i in 0..<100 { for j in 0..<100 { floor.append(SIMD3(Float(i) * 0.005, 0.002, Float(j) * 0.005)) } }
        c.insert(floor); c.insert(floor)
        XCTAssertEqual(c.count, 500)
        var wall: [SIMD3<Float>] = []
        for i in 0..<20 { for j in 0..<20 { wall.append(SIMD3(Float(i) * 0.005 + 0.0025, 0.05 + Float(j) * 0.005 + 0.0025, 0.3)) } }
        c.insert(wall); c.insert(wall)
        XCTAssertEqual(c.centroids(minHits: 2).filter { $0.y > 0.015 }.count, 400)
    }
}

extension BoxMeasureKitTests {
    /// Device log 110433: the cap was 57 % single-hit voxels. When full, singles are evicted once so a
    /// surface seen repeatedly later still gets stored.
    func testVoxelCapEvictsSingleHits() {
        var c = VoxelCloud(voxelSize: 0.005, center: .zero, radius: 10, maxVoxels: 1000)
        c.insert((0..<1000).map { SIMD3(Float($0) * 0.005 + 0.0025, 0.5, 0.0025) })   // 1000 one-hit speckles
        XCTAssertEqual(c.count, 1000)
        let wall = (0..<200).map { SIMD3(Float($0) * 0.005 + 0.0025, 0.1, 0.3) }
        c.insert(wall); c.insert(wall)
        XCTAssertEqual(c.centroids(minHits: 2).count, 200)
    }
}

#if canImport(Darwin)
import Darwin

/// Perf/memory probe for the 1.5M voxel cap. Opt-in: `VOXEL_PERF=1 swift test -c release --filter testVoxelCapPerf`.
extension BoxMeasureKitTests {
    private func residentMB() -> Double {
        var info = mach_task_basic_info()
        var n = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &n) } }
        return Double(info.resident_size) / 1_048_576
    }

    func testVoxelCapPerf() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VOXEL_PERF"] != nil, "set VOXEL_PERF=1")
        let s: Float = 0.005, b = Box(cx: 0, cz: 0, baseY: 0, l: 1.2, w: 1.0, h: 1.0, yaw: 15 * deg)
        var pts: [SIMD3<Float>] = []
        func grid(_ a: Float, _ c: Float) -> [Float] { stride(from: a, to: c, by: s).map { $0 + s / 2 } }
        // Floor: 1.5 m disc, 3 noise layers (fills the floor budget). Box: every face, 2 layers.
        for x in grid(-1.5, 1.5) { for z in grid(-1.5, 1.5) where x * x + z * z <= 2.25 && !b.covers(x, z) {
            for y in [-0.0025, 0.0025, 0.0075] as [Float] { pts.append(SIMD3(x, y, z)) } } }
        for d in [Float(0), s] {
            for x in grid(-b.l / 2, b.l / 2) { for z in grid(-b.w / 2, b.w / 2) { pts.append(b.at(x, z, b.h + d)) } }
            for y in grid(0, b.h) {
                for x in grid(-b.l / 2, b.l / 2) { pts.append(b.at(x, -b.w / 2 - d, y)); pts.append(b.at(x, b.w / 2 + d, y)) }
                for z in grid(-b.w / 2, b.w / 2) { pts.append(b.at(-b.l / 2 - d, z, y)); pts.append(b.at(b.l / 2 + d, z, y)) }
            }
        }
        // Clutter: surrounding objects on a 1.3-1.5 m ring up to 1 m high, until ~1.5M distinct voxels.
        var rng = SplitMix64(state: 3)
        while pts.count < 1_560_000 {
            let a = Float.random(in: 0..<(2 * .pi), using: &rng), r = Float.random(in: 1.3...1.49, using: &rng)
            pts.append(SIMD3(r * cos(a), Float.random(in: 0.03...1.0, using: &rng), r * sin(a)))
        }
        let before = residentMB()
        var c = VoxelCloud(voxelSize: s, center: .zero, radius: 1.5, floorY: 0.015)
        var t = CFAbsoluteTimeGetCurrent()
        c.insert(pts.flatMap { [$0, $0] })   // every voxel hit twice (back to back, so the cap's eviction keeps them)
        let insertMs = (CFAbsoluteTimeGetCurrent() - t) * 1000
        let after = residentMB()
        t = CFAbsoluteTimeGetCurrent()
        let cen = c.centroids(minHits: 2)
        let cenMs = (CFAbsoluteTimeGetCurrent() - t) * 1000
        t = CFAbsoluteTimeGetCurrent()
        let e = BoxMeasurer.estimate(points: cen, seed: b.top, params: .fused)
        let estMs = (CFAbsoluteTimeGetCurrent() - t) * 1000
        t = CFAbsoluteTimeGetCurrent()
        _ = BoxMeasurer.estimateDebug(points: cen, seed: b.top, params: .fused)
        let dbgMs = (CFAbsoluteTimeGetCurrent() - t) * 1000
        print(String(format: "  PERF voxels %d (cap %d)  stride %d B  resident +%.0f MB (%.0f B/voxel)  insert(2x%d pts) %.0f ms  centroids %.0f ms  estimate %.0f ms  estimateDebug %.0f ms",
                     c.count, c.maxVoxels, MemoryLayout<(hits: Int32, sum: SIMD3<Float>)>.stride, after - before,
                     (after - before) * 1_048_576 / Double(c.count), pts.count, insertMs, cenMs, estMs, dbgMs))
        var k = 0
        let sub = cen.filter { q in k += 1; return q.y > 0.015 || k % 4 == 0 }
        t = CFAbsoluteTimeGetCurrent()
        let e2 = BoxMeasurer.estimate(points: sub, seed: b.top, params: .fused)
        print(String(format: "  PERF floor 1/4: %d pts  estimate %.0f ms  L %.3f W %.3f H %.3f", sub.count, (CFAbsoluteTimeGetCurrent() - t) * 1000, e2?.length ?? 0, e2?.width ?? 0, e2?.height ?? 0))
        let noClutter = cen.filter { $0.x * $0.x + $0.z * $0.z < 1.69 }
        t = CFAbsoluteTimeGetCurrent()
        _ = BoxMeasurer.estimate(points: noClutter, seed: b.top, params: .fused)
        print(String(format: "  PERF r<1.3: %d pts  estimate %.0f ms", noClutter.count, (CFAbsoluteTimeGetCurrent() - t) * 1000))
        if let e { print(String(format: "  PERF estimate L %.3f W %.3f H %.3f", e.length, e.width, e.height)) }
        XCTAssertNotNil(e)
    }
}
#endif
