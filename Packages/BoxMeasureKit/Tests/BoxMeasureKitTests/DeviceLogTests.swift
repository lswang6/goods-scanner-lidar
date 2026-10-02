import XCTest
@testable import BoxMeasureKit

/// Real iPhone 17 Pro Max walk-around logs (2026-10-02): thin upright gift box, glossy tile floor.
/// Tape: L 35.5, W 7.0, H 38.0 cm; rope handle reaches ~2 cm above the top (max-extent counts it).
/// All three clouds were truncated by the old VoxelCloud cap (floor filled it): the back long face is
/// missing, so W is only bounded from the end walls + a bowed front wall and is asserted loosely.
final class DeviceLogTests: XCTestCase {
    /// (log, L tol, W lo...hi) in m. Old logs (old cap; back face missing): W only loosely bounded.
    /// New logs (2026-10-02 11:04, floor budget build): the wall cores are 7.7-8.8 cm apart at mid-height
    /// (6.5-6.8 at the top edge where the tape went): the sides bulge, and max-extent counts the bulge.
    static let cases: [(String, Float, ClosedRange<Float>)] = [
        ("20261002-103302", 0.015, 0.04...0.10), ("20261002-103326", 0.015, 0.04...0.10), ("20261002-103406", 0.015, 0.04...0.10),
        ("20261002-110405", 0.015, 0.07...0.105), ("20261002-110433", 0.015, 0.07...0.105),
    ]

    func testGiftBoxLogs() throws {
        for (name, lTol, wRange) in Self.cases {
            let dir = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
            let (pts, log) = try ScanLogIO.read(from: dir)
            var p = Params.fused   // replay with today's fused-cloud params
            p.seedOnSide = log.params.seedOnSide
            let e = try XCTUnwrap(BoxMeasurer.estimate(points: pts, seed: log.seed, params: p), name)
            print(String(format: "  %@: L %.1f  W %.1f  H %.1f cm", name, e.length * 100, e.width * 100, e.height * 100))
            XCTAssertEqual(e.length, 0.355, accuracy: lTol, "L \(name)")
            XCTAssertEqual(e.height, 0.40, accuracy: 0.015, "H incl. ~2 cm rope \(name)")
            XCTAssertTrue(wRange.contains(e.width), "W \(e.width) \(name)")
        }
    }
}
