import XCTest
import simd
@testable import BoxMeasureKit

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Oriented box in world space. Length axis = (cos yaw, 0, -sin yaw) (right-handed about +y).
struct Box {
    var cx: Float, cz: Float, baseY: Float
    var l: Float, w: Float, h: Float
    var yaw: Float
    var u: SIMD3<Float> { SIMD3(cos(yaw), 0, -sin(yaw)) }
    var v: SIMD3<Float> { SIMD3(sin(yaw), 0, cos(yaw)) }
    var top: SIMD3<Float> { SIMD3(cx, baseY + h, cz) }
    func local(_ x: Float, _ z: Float) -> (Float, Float) {
        let d = SIMD3(x - cx, 0, z - cz)
        return (simd_dot(d, u), simd_dot(d, v))
    }
    func covers(_ x: Float, _ z: Float, margin: Float = 0) -> Bool {
        let (a, b) = local(x, z)
        return abs(a) <= l / 2 + margin && abs(b) <= w / 2 + margin
    }
    func at(_ a: Float, _ b: Float, _ y: Float) -> SIMD3<Float> { SIMD3(cx, y, cz) + a * u + b * v }
}

/// Synthetic scene seen by a downward-ish camera at `cam`: horizontal surfaces at `density` pts/m^2,
/// visible side faces at a third of that (oblique), +/-3 mm uniform noise.
struct Scene {
    var rng = SplitMix64(state: 42)
    var pts: [SIMD3<Float>] = []
    var density: Float = 20000
    let cam = SIMD3<Float>(0, 1.6, -1.5)
    let noise: Float = 0.003

    mutating func r(_ a: Float, _ b: Float) -> Float { Float.random(in: a...b, using: &rng) }
    mutating func add(_ q: SIMD3<Float>) {
        pts.append(q + SIMD3(r(-noise, noise), r(-noise, noise), r(-noise, noise)))
    }
    /// Horizontal plane at y over [x0,x1]x[z0,z1], keeping points where `keep` holds.
    mutating func floor(y: Float, x0: Float, x1: Float, z0: Float, z1: Float, keep: (Float, Float) -> Bool) {
        let n = Int((x1 - x0) * (z1 - z0) * density)
        for _ in 0..<n {
            let x = r(x0, x1), z = r(z0, z1)
            if keep(x, z) { add(SIMD3(x, y, z)) }
        }
    }
    /// Top face (minus `occluders`' footprints) + the side faces facing the camera.
    mutating func box(_ b: Box, topDensity: Float? = nil, occluders: [Box] = []) {
        let n = Int(b.l * b.w * (topDensity ?? density))
        for _ in 0..<n {
            let q = b.at(r(-b.l / 2, b.l / 2), r(-b.w / 2, b.w / 2), b.baseY + b.h)
            if !occluders.contains(where: { $0.covers(q.x, q.z) }) { add(q) }
        }
        let faces: [(SIMD3<Float>, Float, Float)] = [(b.u, b.l, b.w), (-b.u, b.l, b.w), (b.v, b.w, b.l), (-b.v, b.w, b.l)]
        for (normal, _, along) in faces {
            let faceCenter = SIMD3(b.cx, b.baseY + b.h / 2, b.cz) + normal * (normal == b.u || normal == -b.u ? b.l / 2 : b.w / 2)
            guard simd_dot(normal, cam - faceCenter) > 0 else { continue }
            let tangent = SIMD3(-normal.z, 0, normal.x)
            let m = Int(along * b.h * density / 3)
            for _ in 0..<m {
                add(faceCenter + tangent * r(-along / 2, along / 2) + SIMD3(0, r(-b.h / 2, b.h / 2), 0))
            }
        }
    }
    /// Silhouette bleed: points in a `band`-wide ring outside the outline, at random heights base..top.
    mutating func bleed(_ b: Box, band: Float = 0.02, perM2: Float = 10000) {
        let n = Int((b.l + 2 * band) * (b.w + 2 * band) * perM2)
        for _ in 0..<n {
            let a = r(-b.l / 2 - band, b.l / 2 + band), c = r(-b.w / 2 - band, b.w / 2 + band)
            if abs(a) <= b.l / 2 && abs(c) <= b.w / 2 { continue }
            add(b.at(a, c, b.baseY + r(0, b.h)))
        }
    }
}

func yawErr(_ a: Float, _ b: Float) -> Float {
    var d = (a - b).truncatingRemainder(dividingBy: .pi)
    if d > .pi / 2 { d -= .pi }
    if d < -.pi / 2 { d += .pi }
    return abs(d)
}

final class BoxMeasureKitTests: XCTestCase {
    let deg: Float = .pi / 180

    func check(_ e: BoxEstimate?, _ b: Box, tol: Float = 0.01, file: StaticString = #filePath, line: UInt = #line) {
        guard let e else { return XCTFail("nil estimate", file: file, line: line) }
        print(String(format: "  L %.4f (%.4f)  W %.4f (%.4f)  H %.4f (%.4f)  planeY %.4f  yaw %.2f° (%.2f°)  n=%d",
                     e.length, b.l, e.width, b.w, e.height, b.h, e.planeY, e.yaw / deg, b.yaw / deg, e.pointCount))
        XCTAssertEqual(e.length, b.l, accuracy: tol, "length", file: file, line: line)
        XCTAssertEqual(e.width, b.w, accuracy: tol, "width", file: file, line: line)
        XCTAssertEqual(e.height, b.h, accuracy: tol, "height", file: file, line: line)
        XCTAssertEqual(e.planeY, b.baseY, accuracy: 0.005, "planeY", file: file, line: line)
        XCTAssertEqual(e.center.x, b.cx, accuracy: tol, file: file, line: line)
        XCTAssertEqual(e.center.z, b.cz, accuracy: tol, file: file, line: line)
        if b.l - b.w > 0.05 { XCTAssertLessThan(yawErr(e.yaw, b.yaw), 2 * deg, "yaw", file: file, line: line) }
    }

    func floorScene(_ boxes: [Box], half: Float = 1.5, seed: UInt64 = 42) -> Scene {
        var s = Scene(rng: SplitMix64(state: seed))
        s.floor(y: 0, x0: -half, x1: half, z0: -half, z1: half) { x, z in !boxes.contains { $0.covers(x, z) } }
        for b in boxes { s.box(b) }
        return s
    }

    // 1
    func testRotatedBoxOnFloor() {
        let b = Box(cx: 0.1, cz: -0.05, baseY: 0, l: 0.4, w: 0.3, h: 0.2, yaw: 30 * deg)
        for seed: UInt64 in 1...10 {
            let s = floorScene([b], seed: seed)
            check(BoxMeasurer.estimate(points: s.pts, seed: b.top), b)
        }
        // Sparse-top-slab fallback: footprint from all component points.
        var p = Params(); p.minTopSlabPoints = 100_000
        check(BoxMeasurer.estimate(points: floorScene([b]).pts, seed: b.top, params: p), b)
    }

    // 2
    func testNeighbourBoxIgnored() {
        let a = Box(cx: 0, cz: 0, baseY: 0, l: 0.4, w: 0.3, h: 0.2, yaw: 30 * deg)
        // a's x half-extent = (0.4 cos30 + 0.3 sin30)/2 = 0.248; b's = 0.15 -> 20 cm gap.
        let b = Box(cx: 0.248 + 0.20 + 0.15, cz: 0, baseY: 0, l: 0.3, w: 0.3, h: 0.25, yaw: 0)
        let s = floorScene([a, b])
        check(BoxMeasurer.estimate(points: s.pts, seed: a.top), a)
        check(BoxMeasurer.estimate(points: s.pts, seed: b.top), b)
    }

    // 3
    func testBoxOnTable() {
        let table = Box(cx: 0, cz: 0, baseY: 0, l: 1.2, w: 0.8, h: 0.75, yaw: 0)
        let b = Box(cx: 0.1, cz: 0.05, baseY: 0.75, l: 0.4, w: 0.3, h: 0.2, yaw: 30 * deg)
        var s = Scene()
        s.floor(y: 0, x0: -2, x1: 2, z0: -2, z1: 2) { x, z in !table.covers(x, z) }
        s.box(table, occluders: [b])
        s.box(b)
        check(BoxMeasurer.estimate(points: s.pts, seed: b.top), b)
    }

    // 4
    func testBoxOnPalletWithDenserFloor() {
        let pallet = Box(cx: 0, cz: 0, baseY: 0, l: 1.2, w: 1.0, h: 0.15, yaw: 0)
        let b = Box(cx: -0.1, cz: 0.1, baseY: 0.15, l: 0.4, w: 0.3, h: 0.2, yaw: 30 * deg)
        var s = Scene()
        s.floor(y: 0, x0: -1.5, x1: 1.5, z0: -1.5, z1: 1.5) { x, z in !pallet.covers(x, z) }
        s.box(pallet, topDensity: s.density / 2, occluders: [b])   // slatted pallet: sparser than floor
        s.box(b)
        let r2: Float = 1.0
        let inR = s.pts.filter { ($0.x - b.cx) * ($0.x - b.cx) + ($0.z - b.cz) * ($0.z - b.cz) <= r2 }
        let floorN = inR.filter { abs($0.y) < 0.01 }.count
        let palletN = inR.filter { abs($0.y - 0.15) < 0.01 }.count
        XCTAssertGreaterThan(floorN, palletN, "scene must have more floor than pallet-top points")
        check(BoxMeasurer.estimate(points: s.pts, seed: b.top), b)
    }

    // 5
    func testSilhouetteBleed() {
        let b = Box(cx: 0.1, cz: -0.05, baseY: 0, l: 0.4, w: 0.3, h: 0.2, yaw: 30 * deg)
        for seed: UInt64 in 1...10 {
            var s = floorScene([b], seed: seed)
            s.bleed(b)
            check(BoxMeasurer.estimate(points: s.pts, seed: b.top), b)
        }
    }

    // 6
    func testMinAreaRect() {
        let ang: Float = 25 * deg
        let u = SIMD2<Float>(cos(ang), sin(ang)), v = SIMD2<Float>(-sin(ang), cos(ang))
        let c = SIMD2<Float>(1, 2)
        var pts: [SIMD2<Float>] = []
        for i in 0...20 { for j in 0...10 { pts.append(c + u * (Float(i) / 20 - 0.5) * 0.6 + v * (Float(j) / 10 - 0.5) * 0.2) } }
        let r = minAreaRect(pts)
        XCTAssertEqual(r.size.x, 0.6, accuracy: 1e-4)
        XCTAssertEqual(r.size.y, 0.2, accuracy: 1e-4)
        XCTAssertEqual(r.center.x, 1, accuracy: 1e-4)
        XCTAssertEqual(r.center.y, 2, accuracy: 1e-4)
        XCTAssertEqual(r.angle, ang, accuracy: 1e-4)

        // Long side vertical -> angle ~ +/- 90 deg, normalized into (-pi/2, pi/2].
        let tall = minAreaRect([SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 3), SIMD2(0, 3)])
        XCTAssertEqual(tall.size, SIMD2(3, 1))
        XCTAssertEqual(tall.angle, .pi / 2, accuracy: 1e-5)

        XCTAssertEqual(minAreaRect([]).size, .zero)
        let one = minAreaRect([SIMD2(3, 4)])
        XCTAssertEqual(one.center, SIMD2(3, 4)); XCTAssertEqual(one.size, .zero)
        let two = minAreaRect([SIMD2(0, 0), SIMD2(0, 2)])
        XCTAssertEqual(two.size, SIMD2(2, 0)); XCTAssertEqual(two.center, SIMD2(0, 1))
        let dup = minAreaRect([SIMD2(1, 1), SIMD2(1, 1), SIMD2(1, 1)])
        XCTAssertEqual(dup.size, .zero); XCTAssertFalse(dup.angle.isNaN)

        let line = minAreaRect((0...10).map { SIMD2(Float($0), Float($0)) })
        XCTAssertEqual(line.size.x, 10 * Float(2).squareRoot(), accuracy: 1e-4)
        XCTAssertEqual(line.size.y, 0)
        XCTAssertEqual(line.center, SIMD2(5, 5))
        XCTAssertEqual(line.angle, .pi / 4, accuracy: 1e-5)
        XCTAssertFalse(line.center.x.isNaN || line.size.x.isNaN || line.angle.isNaN)
    }

    // 7
    func testAggregator() {
        var agg = BoxAggregator(capacity: 3)
        XCTAssertNil(agg.median()); XCTAssertEqual(agg.spread, 0)
        func e(_ l: Float, _ w: Float, _ h: Float) -> BoxEstimate {
            BoxEstimate(length: l, width: w, height: h, center: SIMD3(l, 0, 0), yaw: 0, planeY: 0, pointCount: 1)
        }
        agg.add(e(9, 9, 9))           // evicted
        agg.add(e(0.40, 0.30, 0.20))
        agg.add(e(0.44, 0.31, 0.19))
        agg.add(e(0.42, 0.29, 0.22))
        XCTAssertEqual(agg.samples.count, 3)
        let m = agg.median()!
        XCTAssertEqual(m.length, 0.42, accuracy: 1e-6)
        XCTAssertEqual(m.width, 0.30, accuracy: 1e-6)
        XCTAssertEqual(m.height, 0.20, accuracy: 1e-6)
        XCTAssertEqual(m.center.x, 0.42, accuracy: 1e-6)  // latest sample
        // L: 0.04/0.42, W: 0.02/0.30, H: 0.03/0.20 = 0.15 (max)
        XCTAssertEqual(agg.spread, 0.15, accuracy: 1e-5)
        agg.reset()
        XCTAssertNil(agg.median())
    }

    // 8
    func testLargeBoxRadiusGrowth() {
        let b = Box(cx: 0, cz: 0, baseY: 0, l: 1.2, w: 1.0, h: 1.0, yaw: 15 * deg)
        var s = Scene()
        // Floor only visible beyond 1.05 m from the seed, so the 1.0 m first pass finds no plane.
        s.floor(y: 0, x0: -2.2, x1: 2.2, z0: -2.2, z1: 2.2) { x, z in
            (x * x + z * z) >= 1.05 * 1.05 && !b.covers(x, z)
        }
        s.box(b)
        var p = Params(); p.maxSearchRadius = 1.0
        XCTAssertNil(BoxMeasurer.estimate(points: s.pts, seed: b.top, params: p), "no plane inside 1.0 m")
        check(BoxMeasurer.estimate(points: s.pts, seed: b.top), b, tol: 0.02)
    }

    func testNoPlaneReturnsNil() {
        let b = Box(cx: 0, cz: 0, baseY: 0, l: 0.4, w: 0.3, h: 0.2, yaw: 0)
        var s = Scene()
        s.box(b)   // floating box, no support surface... except its side faces, which are sparse
        var p = Params(); p.minPlanePoints = 10_000
        XCTAssertNil(BoxMeasurer.estimate(points: s.pts, seed: b.top, params: p))
        XCTAssertNil(BoxMeasurer.estimate(points: [], seed: .zero))
    }

    func testTiming50k() {
        let b = Box(cx: 0.1, cz: -0.05, baseY: 0, l: 0.4, w: 0.3, h: 0.2, yaw: 30 * deg)
        let s = floorScene([b], half: 0.78)
        XCTAssertGreaterThanOrEqual(s.pts.count, 49_000)
        _ = BoxMeasurer.estimate(points: s.pts, seed: b.top)
        let t0 = DispatchTime.now().uptimeNanoseconds
        let runs = 5
        for _ in 0..<runs { XCTAssertNotNil(BoxMeasurer.estimate(points: s.pts, seed: b.top)) }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 / Double(runs)
        print(String(format: "  estimate(%d pts): %.1f ms/call", s.pts.count, ms))
        XCTAssertLessThan(ms, 500, "generous bound for debug builds; release target is < 100 ms")
    }
}
