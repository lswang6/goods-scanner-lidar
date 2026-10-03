import XCTest
import simd
@testable import BoxMeasureKit

final class SilhouetteHullTests: XCTestCase {
    static let K = simd_float3x3(SIMD3(1450, 0, 0), SIMD3(0, 1450, 0), SIMD3(960, 720, 1))
    static let res = SIMD2<Float>(1920, 1440)

    /// Camera at `p` looking at `target` (ARKit convention: looks down -z, y up).
    static func pose(_ p: SIMD3<Float>, _ target: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(p - target), x = simd_normalize(simd_cross(SIMD3(0, 1, 0), z)), y = simd_cross(z, x)
        return simd_float4x4(SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(p, 1))
    }

    /// Ray-cast mask of a box (BoxEstimate geometry) at w x h.
    static func render(_ b: BoxEstimate, _ t: simd_float4x4, w: Int = 480, h: Int = 360) -> Silhouette {
        let cam = DepthCamera(width: w, height: h, intrinsics: K, imageResolution: res, transform: t)
        let o = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let la = SIMD3(cos(b.yaw), 0, -sin(b.yaw)), wa = SIMD3(sin(b.yaw), 0, cos(b.yaw)), c = b.center + SIMD3(0, b.height / 2, 0)
        let half = SIMD3(b.length, b.height, b.width) / 2
        func local(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(simd_dot(v, la), v.y, simd_dot(v, wa)) }
        let ol = local(o - c)
        var mask = [UInt8](repeating: 0, count: w * h)
        for v in 0..<h { for u in 0..<w {
            let d4 = t * SIMD4(cam.cameraPoint(u, v, 1), 0)
            let dl = local(SIMD3(d4.x, d4.y, d4.z))
            let t1 = (-half - ol) / dl, t2 = (half - ol) / dl
            let tn = simd_reduce_max(simd_min(t1, t2)), tf = simd_reduce_min(simd_max(t1, t2))
            if tn <= tf, tf > 0 { mask[v * w + u] = 1 }
        } }
        return Silhouette(mask: mask, width: w, height: h, intrinsics: K, imageResolution: res, transform: t)
    }

    /// Walk-around at two phone heights: dims, center and yaw (length axis direction) within 1 cm / 1°.
    func testSyntheticBox() throws {
        let floorY: Float = -1.0
        let truth = BoxEstimate(length: 0.40, width: 0.30, height: 0.30, center: SIMD3(0.3, floorY, -0.5), yaw: 20 * .pi / 180,
                                planeY: floorY, pointCount: 0)
        let aim = truth.center + SIMD3(0, 0.15, 0)
        var views: [Silhouette] = []
        for k in 0..<24 {
            let a = Float(k) / 24 * 2 * .pi, r: Float = 0.9
            let p = SIMD3(truth.center.x + r * cos(a), floorY + (k % 2 == 0 ? 0.9 : 0.45), truth.center.z + r * sin(a))
            views.append(Self.render(truth, Self.pose(p, aim)))
        }
        // Seed off-center (as the app's floor anchor would be).
        let (e, surface) = try XCTUnwrap(SilhouetteHull.measure(views, floorY: floorY, center: SIMD2(0.25, -0.45)))
        print(String(format: "  synthetic: %.1f x %.1f x %.1f  yaw %.1f°", e.length * 100, e.width * 100, e.height * 100, e.yaw * 180 / .pi))
        XCTAssertEqual(e.length, 0.40, accuracy: 0.01); XCTAssertEqual(e.width, 0.30, accuracy: 0.01); XCTAssertEqual(e.height, 0.30, accuracy: 0.01)
        XCTAssertEqual(e.center.x, 0.3, accuracy: 0.01); XCTAssertEqual(e.center.z, -0.5, accuracy: 0.01); XCTAssertEqual(e.planeY, floorY)
        let dyaw = abs(remainder(e.yaw - truth.yaw, .pi))   // the length axis has no sign
        XCTAssertLessThan(dyaw, 1 * .pi / 180)
        XCTAssertFalse(surface.isEmpty)
    }

    /// Device scans 2026-10-03 of the 40x30x30 box with Vision foreground masks (docs/research/mask.swift, *.mask.pgm):
    /// matches the research script (hull_rgb.py: 40.6x31.4x30.5, 41.3x31.5x30.8, 40.7x31.6x31.2) and the tape.
    func testDeviceMasks() throws {
        let expected: [(String, SIMD3<Float>)] = [("raw-20261003-140542", SIMD3(40.6, 31.4, 30.5)),
                                                  ("raw-20261003-140612", SIMD3(41.3, 31.5, 30.8)),
                                                  ("raw-20261003-140642", SIMD3(40.7, 31.6, 31.2))]
        var ran = false
        for (name, py) in expected {
            guard let dir = deviceFixture(name) else { continue }
            ran = true
            let frames = try RawFrames(dir: dir)
            var views: [Silhouette] = []
            for i in 0..<frames.count where frames.meta(i).phase == 1 {
                let f = frames[i]
                let url = dir.appendingPathComponent(String(format: "images/%.6f.jpg.mask.pgm", f.timestamp))
                guard let pgm = try? Data(contentsOf: url) else { continue }
                // "P5\n<w> <h>\n255\n" + bytes
                let header = pgm.prefix(32).split(separator: 0x0A, maxSplits: 3, omittingEmptySubsequences: false)
                let wh = String(decoding: header[1], as: UTF8.self).split(separator: " ").compactMap { Int($0) }
                let w = wh[0], h = wh[1]
                views.append(Silhouette(mask: Array(pgm.suffix(w * h)), width: w, height: h, intrinsics: f.intrinsics,
                                        imageResolution: f.imageResolution, transform: f.transform))
            }
            let seed = try XCTUnwrap(frames.index.lockSeed), floorY = try XCTUnwrap(frames.index.lockPlaneY)
            let (e, _) = try XCTUnwrap(SilhouetteHull.measure(views, floorY: floorY, center: SIMD2(seed.x, seed.z)))
            let cm = SIMD3(e.length, e.width, e.height) * 100
            print(String(format: "  %@ (%d views): %.1f x %.1f x %.1f", name, views.count, cm.x, cm.y, cm.z))
            XCTAssertLessThan(simd_reduce_max(simd_abs(cm - py)), 0.8, name)
            XCTAssertLessThan(simd_reduce_max(simd_abs(cm - SIMD3(40, 30, 30))), 2.0, name)
        }
        if !ran { throw XCTSkip("device fixtures missing (private, gitignored)") }
    }

    /// Camera-mode device scans 2026-10-03 (no depth; ARKit plane as floor, lockSeed = floor anchor). 143157: ARKit's
    /// floor 7.5 cm low (the support plane comes from the hull). 143318/143344: tapered round pedal bin, Ø24 body,
    /// 26 with handle, H 27 -> cylinder at its widest extent.
    func testCameraModeScans() throws {
        let cases: [(String, ShapeKind, SIMD3<Float>)] = [
            ("raw-20261003-143157", .box, SIMD3(40, 30, 30)), ("raw-20261003-143226", .box, SIMD3(40, 30, 30)),
            ("raw-20261003-143249", .box, SIMD3(40, 30, 30)),
            ("raw-20261003-143318", .cylinder, SIMD3(24, 24, 27)), ("raw-20261003-143344", .cylinder, SIMD3(24, 24, 27))]
        var ran = false
        for (name, shape, truth) in cases {
            guard let dir = deviceFixture(name) else { continue }
            ran = true
            let (views, seed, floorY) = try Self.load(dir)
            let (e, _) = try XCTUnwrap(SilhouetteHull.measure(views, floorY: floorY, center: SIMD2(seed.x, seed.z)), name)
            let cm = SIMD3(e.length, e.width, e.height) * 100
            print(String(format: "  %@ %@ (%d views): %.1f x %.1f x %.1f  floor %+.1f cm", name, e.shape.rawValue, views.count,
                         cm.x, cm.y, cm.z, (e.planeY - floorY) * 100))
            XCTAssertEqual(e.shape, shape, name)
            XCTAssertLessThan(simd_reduce_max(simd_abs(cm - truth)), 3.0, name)
        }
        if !ran { throw XCTSkip("device fixtures missing (private, gitignored)") }
    }

    /// Scan-phase views (Vision masks from docs/research/mask.swift), lock seed, lock plane.
    static func load(_ dir: URL) throws -> ([Silhouette], SIMD3<Float>, Float) {
        let frames = try RawFrames(dir: dir)
        var views: [Silhouette] = []
        for i in 0..<frames.count where frames.meta(i).phase == 1 {
            let f = frames[i]
            let url = dir.appendingPathComponent(String(format: "images/%.6f.jpg.mask.pgm", f.timestamp))
            guard let pgm = try? Data(contentsOf: url) else { continue }
            // "P5\n<w> <h>\n255\n" + bytes
            let header = pgm.prefix(32).split(separator: 0x0A, maxSplits: 3, omittingEmptySubsequences: false)
            let wh = String(decoding: header[1], as: UTF8.self).split(separator: " ").compactMap { Int($0) }
            views.append(Silhouette(mask: Array(pgm.suffix(wh[0] * wh[1])), width: wh[0], height: wh[1], intrinsics: f.intrinsics,
                                    imageResolution: f.imageResolution, transform: f.transform))
        }
        return (views, try XCTUnwrap(frames.index.lockSeed), try XCTUnwrap(frames.index.lockPlaneY))
    }
}
