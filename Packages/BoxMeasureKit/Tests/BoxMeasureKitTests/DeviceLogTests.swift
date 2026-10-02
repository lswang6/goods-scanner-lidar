import XCTest
@testable import BoxMeasureKit

/// Real iPhone 17 Pro Max walk-around logs (2026-10-02), replayed with `Params.fused`.
/// Gift box: tape L 35.5, W 7.0 (top edge), H 38 (+~2 cm rope, counted under max extent).
/// Cylinder: max diameter 26.0 (lid rim, 2-3 cm tall, ~1.5 cm proud of a ~23 cm body), H 25.5.
/// Big box: rigid 40x30x30.
///
/// Known instrument artifact (scratchpad analysis 2026-10-02): fused LiDAR vertical walls bow ~1-1.3 cm per
/// side outward at mid-height, anchored at the floor and top edges (big box cores 40.3x31.5 bottom,
/// 42.8x33.5 mid, 39.3x30.8 top; even the gift box's 7 cm end panels: L cores 35.5 -> 37.5 -> 35.0).
/// Max extent measures the bow, so big box and some gift-box L readings miss the tape. The cylinder's sparse
/// lid rim is cut by the column-support/trim filters that remove gift-box edge bleed. Both are open: the
/// strict targets are `XCTExpectFailure` so this test flags when a fix lands; the plain asserts guard against
/// regressions from today's numbers.
final class DeviceLogTests: XCTestCase {
    struct Case { let name: String; let l, w, h: Float; let guardL, guardW, guardH: Float; let strict: Bool; let wMax: Float? }
    // guard* = today's value +/- slack (regression); l/w/h = truth targets (strict = expected to pass now).
    static let cases: [Case] = [
        // old cap build, back face missing: L/H only meaningful, W loose
        Case(name: "20261002-103302", l: 0.355, w: 0.07, h: 0.40, guardL: 0.360, guardW: 0.070, guardH: 0.392, strict: true, wMax: 0.10),
        Case(name: "20261002-110405", l: 0.355, w: 0.07, h: 0.40, guardL: 0.366, guardW: 0.100, guardH: 0.394, strict: true, wMax: 0.105),
        Case(name: "20261002-110433", l: 0.355, w: 0.07, h: 0.40, guardL: 0.354, guardW: 0.096, guardH: 0.393, strict: true, wMax: 0.105),
        Case(name: "20261002-113419", l: 0.355, w: 0.07, h: 0.40, guardL: 0.380, guardW: 0.105, guardH: 0.392, strict: false, wMax: 0.105),
        Case(name: "20261002-113528", l: 0.26, w: 0.26, h: 0.255, guardL: 0.232, guardW: 0.226, guardH: 0.265, strict: false, wMax: nil),
        Case(name: "20261002-113611", l: 0.40, w: 0.30, h: 0.30, guardL: 0.429, guardW: 0.342, guardH: 0.315, strict: false, wMax: nil),
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
            let target = {
                XCTAssertEqual(e.length, c.l, accuracy: 0.015, "L target \(c.name)")
                if let wMax = c.wMax { XCTAssertTrue(e.width >= c.w - 0.005 && e.width <= wMax, "W target \(c.name)") }
                else { XCTAssertEqual(e.width, c.w, accuracy: 0.015, "W target \(c.name)") }
                XCTAssertEqual(e.height, c.h, accuracy: 0.015, "H target \(c.name)")
            }
            if c.strict { target() } else { XCTExpectFailure("open: mid-height wall bow / cylinder rim (see type doc)", failingBlock: target) }
        }
    }
}
