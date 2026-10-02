import XCTest
import simd
@testable import BoxMeasureKit

/// SPEC §11 (P11a): isVerticalSurface, side seeds, estimateDebug, ScanLogIO.
extension BoxMeasureKitTests {

    // MARK: isVerticalSurface

    /// `k`x`k` depth-pixel window around the image center of a camera at the origin pitched down by
    /// `pitch`, hitting the plane {q : dot(n, q) = d}. fx = 212 px (LiDAR depth map, 256x192).
    /// Noise: +-3 mm along the ray plus +-1 mm per axis.
    func window(pitch: Float, n: SIMD3<Float>, d: Float, k: Int = 7, rng: inout SplitMix64) -> [SIMD3<Float>] {
        let fwd = SIMD3<Float>(0, -sin(pitch), cos(pitch)), right = SIMD3<Float>(1, 0, 0)
        let up = simd_cross(right, fwd)
        var pts: [SIMD3<Float>] = []
        for i in 0..<k { for j in 0..<k {
            let ray = simd_normalize(fwd + right * Float(i - k / 2) / 212 + up * Float(j - k / 2) / 212)
            let t = d / simd_dot(n, ray) + Float.random(in: -0.003...0.003, using: &rng)
            pts.append(ray * t + SIMD3((-1...1).map { _ in Float.random(in: -0.001...0.001, using: &rng) }))
        } }
        return pts
    }

    func testIsVerticalSurface() {
        var rng = SplitMix64(state: 3)
        for trial in 0..<50 {
            for k in [5, 7, 9] {
                // Camera tilted 30 deg down, 1 m range to a box top (horizontal) ...
                let top = window(pitch: 30 * deg, n: SIMD3(0, 1, 0), d: -0.5, k: k, rng: &rng)
                XCTAssertFalse(isVerticalSurface(top), "top k=\(k) trial \(trial)")
                // ... and to a side face, square-on and yawed 40 deg away from the camera.
                let side = window(pitch: 30 * deg, n: SIMD3(0, 0, -1), d: -0.866, k: k, rng: &rng)
                XCTAssertTrue(isVerticalSurface(side), "side k=\(k) trial \(trial)")
                let a: Float = 40 * deg
                let yawed = window(pitch: 30 * deg, n: SIMD3(sin(a), 0, -cos(a)), d: -0.866 * cos(a), k: k, rng: &rng)
                XCTAssertTrue(isVerticalSurface(yawed), "yawed side k=\(k) trial \(trial)")
                // Steep camera (60 deg down) still sees a top as horizontal, a side as vertical.
                XCTAssertFalse(isVerticalSurface(window(pitch: 60 * deg, n: SIMD3(0, 1, 0), d: -0.866, k: k, rng: &rng)))
                XCTAssertTrue(isVerticalSurface(window(pitch: 60 * deg, n: SIMD3(0, 0, -1), d: -0.5, k: k, rng: &rng)))
            }
        }
        if let n = surfaceNormal(window(pitch: 30 * deg, n: SIMD3(0, 0, -1), d: -0.866, rng: &rng)) {
            print(String(format: "  side normal (%.3f, %.3f, %.3f)", n.x, n.y, n.z))
        }
        // Degenerate input -> false.
        XCTAssertFalse(isVerticalSurface([]))
        XCTAssertFalse(isVerticalSurface([SIMD3(0, 0, 0), SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)]))  // < 5
        XCTAssertFalse(isVerticalSurface((0..<9).map { SIMD3(0, Float($0) * 0.01, 1) }))                     // collinear
        XCTAssertFalse(isVerticalSurface(Array(repeating: SIMD3(0, 0, 1), count: 9)))                        // one point
        var nan = window(pitch: 30 * deg, n: SIMD3(0, 0, -1), d: -0.866, rng: &rng)
        nan[3].y = .nan
        XCTAssertFalse(isVerticalSurface(nan))
    }

    // MARK: side seed

    /// Center of the face of `b` that faces `cam` most directly, at mid-height.
    func sideSeed(_ b: Box, cam: SIMD3<Float>) -> SIMD3<Float> {
        let faces = [(b.u, b.l / 2), (-b.u, b.l / 2), (b.v, b.w / 2), (-b.v, b.w / 2)]
        let mid = SIMD3(b.cx, b.baseY + b.h / 2, b.cz)
        let f = faces.max { simd_dot($0.0, simd_normalize(cam - mid)) < simd_dot($1.0, simd_normalize(cam - mid)) }!
        return mid + f.0 * f.1
    }

    func sideParams() -> Params { var p = Params(); p.seedOnSide = true; return p }

    func testSideSeedSmallBox() {
        let b = Box(cx: 0.1, cz: -0.05, baseY: 0, l: 0.4, w: 0.3, h: 0.2, yaw: 30 * deg)
        // Single view: max-extent footprint includes oblique side-face spread.
        for seed: UInt64 in 1...5 {
            let s = floorScene([b], seed: seed)
            let seedPt = sideSeed(b, cam: s.cam)
            check(BoxMeasurer.estimate(points: s.pts, seed: seedPt, params: sideParams()), b, tol: 0.025)
            // Top-seed default would cap points at seed.y + 0.5 anyway; side seed reaches the top from mid-height.
        }
        // Orbit + voxel fusion.
        var o = Orbit()
        o.capture([b], floorRadius: 1.0, camRadius: 1.0, camHeight: 1.3)
        let seedPt = sideSeed(b, cam: SIMD3(b.cx, 1, b.cz - 1))
        check(BoxMeasurer.estimate(points: o.fused(center: seedPt), seed: seedPt, params: sideParams()), b)
    }

    /// Big box, camera close: top only visible within 40 cm of the near edge; floor only as a 40 cm strip
    /// in front and at the sides. `orbit`: front + left + right faces seen (back face never).
    func bigBoxSideScene(orbit: Bool) -> (pts: [SIMD3<Float>], seed: SIMD3<Float>, box: Box) {
        let b = Box(cx: 0, cz: 0, baseY: 0, l: 1.2, w: 1.0, h: 1.0, yaw: 10 * deg)
        // Near side = -v (camera at -z).
        let keep = { (q: SIMD3<Float>) -> Bool in
            let (a, c) = b.local(q.x, q.z)
            if abs(q.y) < 0.01 {   // floor: 40 cm strip, not behind the box
                return abs(a) <= b.l / 2 + 0.4 && c >= -b.w / 2 - 0.4 && c <= b.w / 2 && !b.covers(q.x, q.z)
            }
            if q.y > b.h - 0.01 { return c <= -b.w / 2 + 0.4 }      // partial top
            return !(c > b.w / 2 - 0.01 && abs(a) < b.l / 2 - 0.01)  // no back face (side faces kept)
        }
        let raw: [SIMD3<Float>]
        if orbit {
            var o = Orbit(density: 20000)
            o.capture([b], floorRadius: 1.8, camRadius: 1.6, camHeight: 1.6)
            raw = o.fused(center: SIMD3(0, 0.5, -0.5))
        } else {
            var s = Scene()
            s.floor(y: 0, x0: -2, x1: 2, z0: -2, z1: 2) { _, _ in true }
            s.box(b)
            raw = s.pts
        }
        let pts = raw.filter(keep)
        return (pts, sideSeed(b, cam: SIMD3(0, 1.6, -1.5)), b)
    }

    func testSideSeedBigBox() {
        for orbit in [false, true] {
            let (pts, seed, b) = bigBoxSideScene(orbit: orbit)
            let (e, d) = BoxMeasurer.estimateDebug(points: pts, seed: seed, params: sideParams())
            guard let e else { return XCTFail("nil estimate orbit=\(orbit), failure \(String(describing: d.failure))") }
            print(String(format: "  big side seed %@: L %.4f W %.4f H %.4f planeY %.4f yaw %.2f° n=%d (%d pts, %.1f ms)",
                         orbit ? "orbit" : "single", e.length, e.width, e.height, e.planeY, e.yaw / deg, e.pointCount, pts.count, d.millis))
            // Vertical faces spread over y-bins: busiest side bin vs findPlaneY's 5%-of-radius threshold.
            let inR = pts.filter { simd_length(SIMD2($0.x - seed.x, $0.z - seed.z)) <= 1 }
            var bins: [Int: Int] = [:]
            for q in inR where q.y > 0.02 && q.y < seed.y - 0.03 { bins[Int((q.y / 0.01).rounded(.down)), default: 0] += 1 }
            let thr = max(30, Int((0.05 * Float(inR.count)).rounded(.up)))
            print("  side-face bin max \(bins.values.max() ?? 0) vs plane threshold \(thr)")
            XCTAssertLessThan(bins.values.max() ?? 0, thr)
            XCTAssertEqual(e.planeY, 0, accuracy: 0.005, "planeY orbit=\(orbit)")
            XCTAssertEqual(e.height, b.h, accuracy: 0.02, "height orbit=\(orbit)")
            if orbit { check(e, b, tol: 0.02) }
            // seedOnSide forces the max-extent path even with maxExtent = false.
            var p = sideParams(); p.maxExtent = false
            XCTAssertEqual(BoxMeasurer.estimate(points: pts, seed: seed, params: p), e)
            // Without seedOnSide the top-anchored cap (seed.y + 0.5) cuts the box at 1.0 m -> height wrong.
            if let t = BoxMeasurer.estimate(points: pts, seed: seed) {
                print(String(format: "    (seedOnSide=false: H %.4f)", t.height))
            }
        }
    }

    // MARK: estimateDebug

    func testEstimateDebugMatchesEstimate() {
        let b = Box(cx: 0.1, cz: -0.05, baseY: 0, l: 0.4, w: 0.3, h: 0.2, yaw: 30 * deg)
        let s = floorScene([b])
        var o = Orbit()
        o.capture([b], floorRadius: 1.0, camRadius: 1.0, camHeight: 1.3)
        let fused = o.fused(center: b.top)
        var top = Params(); top.maxExtent = false
        let big = bigBoxSideScene(orbit: false)
        let cases: [([SIMD3<Float>], SIMD3<Float>, Params)] = [
            (s.pts, b.top, Params()), (s.pts, b.top, top), (fused, b.top, Params()),
            (s.pts, sideSeed(b, cam: s.cam), sideParams()), (big.pts, big.seed, sideParams()),
        ]
        for (i, (pts, seed, p)) in cases.enumerated() {
            let (e, d) = BoxMeasurer.estimateDebug(points: pts, seed: seed, params: p)
            XCTAssertNotNil(e, "case \(i)")
            XCTAssertEqual(e, BoxMeasurer.estimate(points: pts, seed: seed, params: p), "case \(i)")
            XCTAssertNil(d.failure)
            XCTAssertEqual(d.planeY, e?.planeY)
            XCTAssertEqual(d.objectIndices.count, e?.pointCount)
            XCTAssertFalse(d.planeIndices.isEmpty)
            XCTAssertTrue(d.objectIndices.allSatisfy { pts.indices.contains($0) && pts[$0].y > d.planeY! })
            XCTAssertTrue(d.planeIndices.allSatisfy { abs(pts[$0].y - d.planeY!) <= p.binSize })
            XCTAssertTrue(Set(d.objectIndices).isDisjoint(with: d.planeIndices))
            XCTAssertGreaterThan(d.millis, 0)
            print(String(format: "  debug case %d: object %d plane %d  %.1f ms", i, d.objectIndices.count, d.planeIndices.count, d.millis))
        }
    }

    func testEstimateDebugFailures() {
        let b = Box(cx: 0, cz: 0, baseY: 0, l: 0.4, w: 0.3, h: 0.2, yaw: 0)
        func failure(_ pts: [SIMD3<Float>], _ seed: SIMD3<Float>, _ p: Params = .init()) -> EstimateFailure? {
            let (e, d) = BoxMeasurer.estimateDebug(points: pts, seed: seed, params: p)
            XCTAssertNil(e); XCTAssertNil(BoxMeasurer.estimate(points: pts, seed: seed, params: p))
            return d.failure
        }
        var floating = Scene(); floating.box(b)
        var p = Params(); p.minPlanePoints = 10_000
        XCTAssertEqual(failure(floating.pts, b.top, p), .noPlane)
        XCTAssertEqual(failure([], .zero), .noPlane)

        let s = floorScene([b])
        let air = SIMD3<Float>(0.8, 0.4, 0.6)   // floor below, nothing within seedCellSearch
        XCTAssertEqual(failure(s.pts, air), .noSeedCell)
        let (_, d) = BoxMeasurer.estimateDebug(points: s.pts, seed: air)
        XCTAssertEqual(d.planeY ?? 1, 0, accuracy: 0.005)
        XCTAssertFalse(d.planeIndices.isEmpty)

        p = Params(); p.minBoxPoints = 1_000_000
        XCTAssertEqual(failure(s.pts, b.top, p), .tooFewPoints)
        p = Params(); p.maxBoxSize = 0.3
        XCTAssertEqual(failure(s.pts, b.top, p), .outOfRange)
    }

    // MARK: ScanLogIO

    func testScanLogRoundTrip() throws {
        let b = Box(cx: 0.1, cz: -0.05, baseY: 0, l: 0.4, w: 0.3, h: 0.2, yaw: 30 * deg)
        var pts = floorScene([b]).pts
        pts += [SIMD3(-0.0, .leastNonzeroMagnitude, .greatestFiniteMagnitude), SIMD3(.infinity, -.infinity, .nan)]
        var p = Params(); p.seedOnSide = true; p.trimMargin = 0.0071
        let e = BoxMeasurer.estimate(points: pts, seed: b.top)
        var log = ScanLog(date: Date(timeIntervalSince1970: 1_790_000_000), seed: b.top, seedVertical: true, params: p,
                          estimate: e, failure: nil, deliveredCm: [40.1, 30.2, 20.3], coveredSectors: 9, voxelCount: pts.count)
        log.note = "round-trip ✓"
        // Fixed temp path (left in place) so bmk-replay can be smoke-tested on it.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bmk-roundtrip/nested")
        try? FileManager.default.removeItem(at: dir)
        try ScanLogIO.write(points: pts, log: log, to: dir)
        let (rp, rl) = try ScanLogIO.read(from: dir)
        XCTAssertEqual(rp.count, pts.count)
        XCTAssertTrue(zip(rp, pts).allSatisfy { $0.x.bitPattern == $1.x.bitPattern && $0.y.bitPattern == $1.y.bitPattern && $0.z.bitPattern == $1.z.bitPattern })
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys; enc.dateEncodingStrategy = .iso8601
        XCTAssertEqual(try enc.encode(rl), try enc.encode(log))
        XCTAssertEqual(rl.date, log.date)
        XCTAssertEqual(rl.estimate, e)
        let header = try String(decoding: Data(contentsOf: dir.appendingPathComponent("points.ply")).prefix(200), as: UTF8.self)
        XCTAssertTrue(header.hasPrefix("ply\nformat binary_little_endian 1.0\nelement vertex \(pts.count)\n"))
        XCTAssertThrowsError(try ScanLogIO.read(from: dir.appendingPathComponent("missing")))
        print("  scan log: \(dir.path)")
    }
}
