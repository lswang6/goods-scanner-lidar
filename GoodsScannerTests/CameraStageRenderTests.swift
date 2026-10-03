import XCTest
import SwiftUI
@testable import GoodsScanner

/// Static renders of the camera-mode scan stages (ScanStageScreen.cameraStages) for design review.
/// PNGs go to $GUIDANCE_RENDER_DIR (pass as TEST_RUNNER_GUIDANCE_RENDER_DIR to xcodebuild) or the temp dir.
/// Animated version: ScanGuidanceDemo (#Preview, or launch with -scanGuidanceDemo and tap the scan button).
@MainActor
final class CameraStageRenderTests: XCTestCase {
    func testSymbolsExist() {
        for name in ["shippingbox.fill", "iphone.gen3"] { XCTAssertNotNil(UIImage(systemName: name), name) }
    }

    func testRenderCameraStages() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GUIDANCE_RENDER_DIR"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertEqual(ScanStageScreen.cameraStages.count, 7)
        for (name, screen) in ScanStageScreen.cameraStages {
            let r = ImageRenderer(content: screen.frame(width: 402, height: 874))
            r.scale = 2
            let data = try XCTUnwrap(r.uiImage?.pngData(), name)
            try data.write(to: dir.appendingPathComponent("\(name).png"))
        }
        print("camera stage renders:", dir.path)
    }
}
