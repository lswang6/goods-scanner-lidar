import XCTest
@testable import BoxMeasureKit

/// Real iPhone 17 Pro Max walk-around logs (2026-10-02), replayed with `Params.fused`.
/// Gift box: tape L 35.5, W 7.0 (top edge), H 38 (+~2 cm rope, counted under max extent).
/// Cylinder: max diameter 26.0 (lid rim, 2-3 cm tall, ~1.5 cm proud of a ~23 cm body), H 25.5.
/// Big box: rigid 40x30x30.
///
/// SPEC §13 (user decision): walls bow ~1-1.3 cm per side at mid-height (big box cores 40.3x31.5 bottom,
/// 42.8x33.5 mid; gift box L cores 35.5 -> 37.5) and that belly counts under max extent. The cylinder is
/// detected (E1) and measured by full-ring height bands (E2), so its lid rim (Ø26 over a ~22.5 body) counts.
final class DeviceLogTests: XCTestCase {
    struct Case { let name: String; let l, w, h: Float; let guardL, guardW, guardH: Float; let shape: ShapeKind; let lMax: Float?; let wMax: Float? }
    // guard* = today's replay (regression, +/-1 cm); l/w/h = truth targets (lMax: gift-box bow accepted, L 35.5-38).
    static let cases: [Case] = [
        // old cap build, back face missing: L/H only meaningful, W loose
        Case(name: "20261002-103302", l: 0.355, w: 0.07, h: 0.40, guardL: 0.360, guardW: 0.070, guardH: 0.392, shape: .box, lMax: 0.38, wMax: 0.10),
        Case(name: "20261002-110405", l: 0.355, w: 0.07, h: 0.40, guardL: 0.366, guardW: 0.100, guardH: 0.394, shape: .box, lMax: 0.38, wMax: 0.105),
        Case(name: "20261002-110433", l: 0.355, w: 0.07, h: 0.40, guardL: 0.354, guardW: 0.096, guardH: 0.393, shape: .box, lMax: 0.38, wMax: 0.105),
        Case(name: "20261002-113419", l: 0.355, w: 0.07, h: 0.40, guardL: 0.380, guardW: 0.105, guardH: 0.392, shape: .box, lMax: 0.38, wMax: 0.105),
        // SPEC §13: max extent incl. the lid rim; body is ~22.5.
        Case(name: "20261002-113528", l: 0.26, w: 0.26, h: 0.255, guardL: 0.266, guardW: 0.266, guardH: 0.265, shape: .cylinder, lMax: nil, wMax: nil),
        // SPEC §13 E5: the bulge is real; max-extent belly reading.
        Case(name: "20261002-113611", l: 0.428, w: 0.335, h: 0.315, guardL: 0.429, guardW: 0.342, guardH: 0.315, shape: .box, lMax: nil, wMax: nil),
    ]

    func testDeviceLogs() throws {
        for c in Self.cases {
            let dir = try XCTUnwrap(Bundle.module.url(forResource: c.name, withExtension: nil, subdirectory: "Fixtures"))
            let (pts, log) = try ScanLogIO.read(from: dir)
            var p = Params.fused
            p.seedOnSide = log.params.seedOnSide
            let e = try XCTUnwrap(BoxMeasurer.estimate(points: pts, seed: log.seed, params: p), c.name)
            print(String(format: "  %@: L %.1f  W %.1f  H %.1f cm", c.name, e.length * 100, e.width * 100, e.height * 100))
            // Regression guard: within 1 cm of today's replay.
            XCTAssertEqual(e.length, c.guardL, accuracy: 0.01, "L guard \(c.name)")
            XCTAssertEqual(e.width, c.guardW, accuracy: 0.01, "W guard \(c.name)")
            XCTAssertEqual(e.height, c.guardH, accuracy: 0.01, "H guard \(c.name)")
            XCTAssertEqual(e.shape, c.shape, "shape \(c.name)")
            if let lMax = c.lMax { XCTAssertTrue(e.length >= c.l - 0.005 && e.length <= lMax, "L target \(c.name)") }
            else { XCTAssertEqual(e.length, c.l, accuracy: 0.015, "L target \(c.name)") }
            if let wMax = c.wMax { XCTAssertTrue(e.width >= c.w - 0.005 && e.width <= wMax, "W target \(c.name)") }
            else { XCTAssertEqual(e.width, c.w, accuracy: 0.015, "W target \(c.name)") }
            XCTAssertEqual(e.height, c.h, accuracy: 0.015, "H target \(c.name)")
        }
    }
}
