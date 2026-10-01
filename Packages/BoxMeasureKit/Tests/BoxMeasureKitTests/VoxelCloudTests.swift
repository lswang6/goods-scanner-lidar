import XCTest
import simd
@testable import BoxMeasureKit

/// Params for fused (voxel-centroid) input: defaults pass (see report); ScanSession uses `Params()` too.
func voxelTestParams() -> Params { Params() }

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
        c.insert([SIMD3(0.5, 0, 0), SIMD3(0.6, 0, 0)])  // cap: only one more voxel
        XCTAssertEqual(c.count, 3)
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
