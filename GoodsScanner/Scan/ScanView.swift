import SwiftUI
import ARKit
import BoxMeasureKit

/// LiDAR scan screen. Falls back to an explanation on simulator / non-LiDAR devices (`lidarAvailable`).
struct ScanView: View {
    let onResult: (ScanResult) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if lidarAvailable {
            ARScanScreen(onResult: onResult)
        } else {
            NavigationStack {
                EmptyState(image: "ScanAim", title: "无法使用 LiDAR 扫描",
                           message: "本机或模拟器不支持 LiDAR 深度，请返回手动录入尺寸，并用「拍照」添加照片。",
                           action: ("返回手动录入", { dismiss() }))
                    .toolbar { Button("关闭") { dismiss() } }
            }
        }
    }
}

private struct ARScanScreen: View {
    let onResult: (ScanResult) -> Void
    @StateObject private var scan = ScanSession()
    @AppStorage("calibrationOffsetCm") private var offsetCm = 0.0
    @Environment(\.dismiss) private var dismiss
    @State private var delivered = false
    @State private var ringCenter: CGPoint?
    @State private var tickShots = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("debugMode") private var debugMode = false
    @State private var review: Review?

    /// D4: debug-mode finish holds the already-built result until 使用此结果 / 重新扫描.
    private struct Review: Identifiable {
        let id = UUID()
        let result: ScanResult
        let box: BoxEstimate
        let capture: ScanCapture
        var saved = false
    }

    private var stable: Bool { scan.spread <= ScanSession.stableSpread }
    private var coveredCount: Int { scan.sectors.filter { $0 }.count }

    var body: some View {
        ZStack {
            ARContainer(view: scan.view).ignoresSafeArea()
            ScanGuidance(phase: scan.phase, surface: scan.aimSurface, progress: scan.lockProgress, ringCenter: ringCenter)
                .frame(maxWidth: .infinity, maxHeight: .infinity).ignoresSafeArea()  // screen center == depth-map center
            VStack(spacing: 12) {
                statusCapsule
                if debugMode {
                    DebugOverlay(info: scan.debugInfo, spread: scan.spread, sectors: coveredCount, tracking: scan.tracking)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer()
                bottomCard
            }
            .padding(16)
        }
        .coordinateSpace(name: ScanGuidance.space)
        .onPreferenceChange(RingCenterKey.self) { ringCenter = $0 }
        .environment(\.colorScheme, .dark)  // HUD over camera feed
        .onAppear { scan.debug = debugMode; scan.start() }
        .sheet(item: $review) { r in
            ScanReviewView(capture: r.capture, box: r.box, result: r.result, saved: r.saved,
                           onUse: { review = nil; onResult(r.result) },
                           onRescan: { review = nil; delivered = false; scan.reset() })
        }
        .onDisappear { scan.pause() }
        .task(id: scan.phase) {
            // Auto-finish: let SectorRing's completion sweep + ✓ play before delivering.
            guard scan.phase == .done, await pause(reduceMotion ? 0.4 : 1.1) else { return }
            deliver()
        }
        // Light tick per newly covered sector, except at the lock (success haptic) and when a C1 photo
        // (own haptic) fired for it: takeShot is enqueued on main before the sectors publish.
        .onChange(of: coveredCount) { old, new in
            defer { tickShots = scan.shots.count }
            guard new > old, old > 0, scan.phase == .scan, scan.shots.count == tickShots else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private var statusCapsule: some View {
        let (icon, tint): (String, Color) = switch scan.phase {
        case .aim: ("scope", .white)
        case .scan: ("arrow.triangle.2.circlepath", stable ? .scan : .warn)
        case .done: ("checkmark.circle.fill", .scan)
        }
        return HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(scan.status).lineLimit(1).minimumScaleFactor(0.8)
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var bottomCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                SectorRing(covered: scan.sectors, done: scan.phase == .done)
                    .background(GeometryReader { g in
                        let f = g.frame(in: .named(ScanGuidance.space))
                        Color.clear.preference(key: RingCenterKey.self, value: CGPoint(x: f.midX, y: f.midY))
                    })
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(scan.median?.shape == .cylinder ? "直径 × 高" : "长 × 宽 × 高").font(.caption).foregroundStyle(.secondary)
                        if let m = scan.median { ShapeChip(shape: m.shape.rawValue) }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(dims).font(.num(.title))
                        Text("cm").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .lineLimit(1).minimumScaleFactor(0.6)
                    Text("按最大外形尺寸计量" + (scan.shots.isEmpty ? "" : " · 已拍 \(scan.shots.count)/\(ScanSession.maxShots)"))
                        .font(.caption2).foregroundStyle(.secondary)
                    if scan.sampleCount >= 2 {
                        Text(String(format: "离散度 %.1f%%（%d 次）", scan.spread * 100, scan.sampleCount)
                         + (stable ? "" : " 不稳定，建议重扫"))
                            .font(.caption).foregroundStyle(stable ? Color.scan : Color.warn)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button("取消") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button("重置") { scan.reset() }.buttonStyle(SecondaryButtonStyle())
                Button("完成", action: deliver).buttonStyle(PrimaryButtonStyle()).disabled(scan.median == nil)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    private var dims: String {
        guard let m = scan.median else { return "— × — × —" }
        if m.shape == .cylinder { return String(format: "Ø %.1f × 高 %.1f", m.length * 100, m.height * 100) }
        return String(format: "%.1f × %.1f × %.1f", m.length * 100, m.width * 100, m.height * 100)
    }

    /// Single result path for 完成 and auto-finish. Calibration offset is applied here and only here:
    /// each side minus offset, 0.1 cm resolution, >= 0.1.
    /// confidence = max(0, 1 - spread) (spread = max relative L/W/H range over the retained samples:
    /// last 5 fused estimates after lock, last 10 single-frame ones before).
    /// Photos (C2): every shot (or one current frame if none) annotated with the measured box geometry
    /// and the delivered, post-offset numbers.
    /// Debug mode (D4/D5): the result is built here (photos need the current frame), then held while the
    /// final cloud is captured on the scan queue, logged in the background and shown for review.
    private func deliver() {
        guard !delivered, let m = scan.median else { return }
        delivered = true
        var r = ScanResult(m, confidence: max(0, 1 - Double(scan.spread)), photos: [])
        let adj = { (cm: Double) in max(0.1, ((cm - offsetCm) * 10).rounded() / 10) }
        r.lengthCm = adj(r.lengthCm); r.widthCm = adj(r.widthCm); r.heightCm = adj(r.heightCm)
        let shots = scan.shots.isEmpty ? [scan.captureShot()].compactMap { $0 } : scan.shots
        r.photos = shots.map {
            PhotoAnnotator.annotate(image: $0.image, transform: $0.transform, intrinsics: $0.intrinsics,
                                    imageResolution: $0.imageResolution, box: m, labels: (r.lengthCm, r.widthCm, r.heightCm))
        }
        scan.clearShots()
        guard debugMode else { return onResult(r) }
        scan.finishCapture { cap in
            review = Review(result: r, box: m, capture: cap)
            let id = review?.id
            ScanLogStore.save(cap, delivered: r) { ok in if ok, review?.id == id { review?.saved = true } }
        }
    }
}

private struct ARContainer: UIViewRepresentable {
    let view: ARSCNView
    func makeUIView(context: Context) -> ARSCNView { view }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
