import XCTest
import simd
@testable import BoxMeasureKit

extension Orbit {
    /// Walk-around capture of an upright cylinder (radius r, height h, base on the floor) with an optional
    /// full rim ring (radius rimR from rimY0 to rimY1, e.g. a lid). Same view model as `capture`.
    mutating func captureCylinder(cx: Float, cz: Float, radius: Float, h: Float, rim: (r: Float, y0: Float, y1: Float)? = nil,
                                  floorRadius: Float = 1.2, camRadius: Float = 1.2, camHeight: Float = 1.4, views: Int = 12) {
        let outer = max(radius, rim?.r ?? 0)
        for i in 0..<views {
            let a = Float(i) / Float(views) * 2 * .pi + 0.1
            let cam = SIMD3(cx + camRadius * cos(a), camHeight, cz + camRadius * sin(a))
            for _ in 0..<Int(Float.pi * floorRadius * floorRadius * density) {
                let x = r(-floorRadius, floorRadius), z = r(-floorRadius, floorRadius)
                let d2 = x * x + z * z
                guard d2 <= floorRadius * floorRadius, d2 > outer * outer else { continue }
                add(SIMD3(cx + x, 0, cz + z))
            }
            for _ in 0..<Int(Float.pi * outer * outer * density) {   // top disc (lid covers the rim)
                let x = r(-outer, outer), z = r(-outer, outer)
                if x * x + z * z <= outer * outer { add(SIMD3(cx + x, h, cz + z)) }
            }
            func wall(_ rad: Float, _ y0: Float, _ y1: Float) {
                for _ in 0..<Int(2 * .pi * rad * (y1 - y0) * density / 2) {
                    let t = r(0, 2 * .pi), n = SIMD3(cos(t), 0, sin(t))
                    let q = SIMD3(cx, r(y0, y1), cz) + rad * n
                    if simd_dot(n, cam - q) > 0 { add(q) }
                }
            }
            if let rim { wall(radius, 0, rim.y0); wall(rim.r, rim.y0, rim.y1); wall(radius, rim.y1, h) } else { wall(radius, 0, h) }
        }
    }
}

extension BoxMeasureKitTests {
    func fusedEstimate(_ o: Orbit, seed: SIMD3<Float>) -> BoxEstimate? {
        BoxMeasurer.estimate(points: o.fused(center: seed), seed: seed, params: Params.fused)
    }

    func testShapeCylinder() throws {
        for rim in [false, true] {
            var o = Orbit()
            o.captureCylinder(cx: 0.1, cz: -0.2, radius: 0.115, h: 0.255, rim: rim ? (0.13, 0.21, 0.24) : nil)
            let e = try XCTUnwrap(fusedEstimate(o, seed: SIMD3(0.1, 0.255, -0.2)))
            print(String(format: "  cylinder rim=%d: %@ L %.4f W %.4f H %.4f", rim ? 1 : 0, e.shape.rawValue, e.length, e.width, e.height))
            XCTAssertEqual(e.shape, .cylinder, "rim=\(rim)")
            let dia: Float = rim ? 0.26 : 0.23
            XCTAssertEqual(e.length, dia, accuracy: 0.01, "rim=\(rim)")
            XCTAssertEqual(e.width, dia, accuracy: 0.01, "rim=\(rim)")
            XCTAssertEqual(e.height, 0.255, accuracy: 0.01, "rim=\(rim)")
            XCTAssertEqual(e.center.x, 0.1, accuracy: 0.005); XCTAssertEqual(e.center.z, -0.2, accuracy: 0.005)
        }
    }

    /// Boxes stay boxes: plain, rotated, thin (7 cm), and bulging (a 1.5 cm-per-side wider middle band).
    func testShapeBoxes() throws {
        let cases: [[Box]] = [
            [Box(cx: 0, cz: 0, baseY: 0, l: 0.4, w: 0.3, h: 0.3, yaw: 0)],
            [Box(cx: 0.1, cz: 0.05, baseY: 0, l: 0.4, w: 0.3, h: 0.3, yaw: 37 * deg)],
            [Box(cx: 0, cz: 0, baseY: 0, l: 0.355, w: 0.07, h: 0.38, yaw: 20 * deg)],
            [Box(cx: 0, cz: 0, baseY: 0, l: 0.4, w: 0.3, h: 0.3, yaw: 10 * deg),
             Box(cx: 0, cz: 0, baseY: 0.08, l: 0.43, w: 0.33, h: 0.14, yaw: 10 * deg)],
        ]
        for parts in cases {
            var o = Orbit()
            o.capture(parts, floorRadius: 1.2, camRadius: 1.2, camHeight: 1.4)
            let e = try XCTUnwrap(fusedEstimate(o, seed: parts[0].top))
            print(String(format: "  box %.2fx%.2f parts %d: %@ L %.4f W %.4f", parts[0].l, parts[0].w, parts.count, e.shape.rawValue, e.length, e.width))
            XCTAssertEqual(e.shape, .box)
            XCTAssertEqual(e.length, parts.map(\.l).max()!, accuracy: 0.015)
            XCTAssertEqual(e.width, parts.map(\.w).max()!, accuracy: 0.015)
        }
    }

    /// Documented decision: stepped / L-shaped unions are measured as their bounding rectangle (E3), and
    /// the classifier reports .box unless neither a rectangle nor a circle fits the mid-height outline.
    func testShapeTaperedAndLShape() throws {
        let tiers = [Box(cx: 0, cz: 0, baseY: 0, l: 0.5, w: 0.4, h: 0.1, yaw: 20 * deg),
                     Box(cx: 0, cz: 0, baseY: 0.1, l: 0.4, w: 0.3, h: 0.1, yaw: 20 * deg),
                     Box(cx: 0, cz: 0, baseY: 0.2, l: 0.3, w: 0.2, h: 0.1, yaw: 20 * deg)]
        let lShape = [Box(cx: 0, cz: 0, baseY: 0, l: 0.4, w: 0.3, h: 0.2, yaw: 0), Box(cx: 0.3, cz: 0, baseY: 0, l: 0.2, w: 0.3, h: 0.4, yaw: 0)]
        for (parts, name) in [(tiers, "tapered"), (lShape, "L")] {
            var o = Orbit()
            o.capture(parts, floorRadius: 1.2, camRadius: 1.2, camHeight: 1.4)
            let e = try XCTUnwrap(fusedEstimate(o, seed: parts.last!.top))
            print(String(format: "  %@: %@ L %.4f W %.4f H %.4f", name, e.shape.rawValue, e.length, e.width, e.height))
            XCTAssertNotEqual(e.shape, .cylinder, name)
        }
    }

    func testAggregatorShapeMajority() {
        func s(_ k: ShapeKind) -> BoxEstimate { var e = BoxEstimate(length: 1, width: 1, height: 1, center: .zero, yaw: 0, planeY: 0, pointCount: 1); e.shape = k; return e }
        var a = BoxAggregator(capacity: 5)
        for k in [ShapeKind.cylinder, .cylinder, .box] { a.add(s(k)) }
        XCTAssertEqual(a.median()?.shape, .cylinder)
        a.add(s(.box))   // 2 : 2 tie -> latest
        XCTAssertEqual(a.median()?.shape, .box)
    }
}

extension BoxMeasureKitTests {
    /// Threshold table (see `classify`): device features cylinder (0.034, 0.126), boxes circle >= 0.125.
    func testClassifyThresholds() {
        func f(_ c: Float, _ r: Float, _ cov: Float = 1) -> ShapeFeatures { ShapeFeatures(circle: c, rect: r, coverage: cov, center: .zero, radius: 0.1) }
        XCTAssertEqual(classify(f(0.034, 0.126)), .cylinder)
        XCTAssertEqual(classify(f(0.034, 0.126, 0.5)), .box)       // an arc, not a full round wall
        XCTAssertEqual(classify(f(0.125, 0.083)), .box)            // big box
        XCTAssertEqual(classify(f(0.442, 0.123)), .box)            // gift box
        XCTAssertEqual(classify(f(0.40, 0.35)), .irregular)        // neither fits
    }
}
