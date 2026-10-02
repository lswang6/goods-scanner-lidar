import XCTest
import SwiftUI
@testable import GoodsScanner

/// Static renders of the scan guidance stages (AR doesn't run in the simulator). PNGs go to
/// $GUIDANCE_RENDER_DIR (pass as TEST_RUNNER_GUIDANCE_RENDER_DIR to xcodebuild) or the temp dir.
@MainActor
final class ScanGuidanceRenderTests: XCTestCase {
    func testSymbolsExist() {
        for name in ["square.topthird.inset.filled", "square.leadingthird.inset.filled", "checkmark.circle.fill"] {
            XCTAssertNotNil(UIImage(systemName: name), name)
        }
    }

    func testRenderStages() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GUIDANCE_RENDER_DIR"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var covered = [Bool](repeating: false, count: 12)
        covered[0] = true
        let stages: [(String, AnyView, [Bool], Bool)] = [
            ("1-aim", AnyView(ZStack { LaserSweep(); AimReticle(surface: nil, progress: 0) }), Array(repeating: false, count: 12), false),
            ("2-detected-top", AnyView(ZStack { LaserSweep(); AimReticle(surface: .top, progress: 0.6) }), Array(repeating: false, count: 12), false),
            ("2b-detected-side", AnyView(AimReticle(surface: .side, progress: 0.3)), Array(repeating: false, count: 12), false),
            ("3-locked", AnyView(LockBurst()), covered, false),
            ("4-scanning", AnyView(OrbitArrow(flown: false, target: .zero)), covered, false),
            ("5-done", AnyView(EmptyView()), Array(repeating: true, count: 12), true),
        ]
        for (name, overlay, sectors, done) in stages {
            let screen = ZStack {
                LinearGradient(colors: [Color(white: 0.45), Color(red: 0.45, green: 0.35, blue: 0.25)], startPoint: .top, endPoint: .bottom)
                overlay
                VStack {
                    Text("对准箱顶或侧面，周围留出地面").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10).background(.black.opacity(0.4), in: Capsule())
                        .padding(.top, 60)
                    Spacer()
                    SectorRing(covered: sectors, done: done).padding(32)
                        .frame(maxWidth: .infinity, alignment: .leading).background(.black.opacity(0.4))
                }
            }
            .frame(width: 402, height: 874)
            .environment(\.colorScheme, .dark)
            let r = ImageRenderer(content: screen)
            r.scale = 2
            let data = try XCTUnwrap(r.uiImage?.pngData(), name)
            try data.write(to: dir.appendingPathComponent("\(name).png"))
        }
        print("guidance renders:", dir.path)
    }
}
