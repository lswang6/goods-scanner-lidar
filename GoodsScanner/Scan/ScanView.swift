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
                ContentUnavailableView("无法使用 LiDAR 扫描", systemImage: "cube.transparent",
                                       description: Text("本机或模拟器不支持 LiDAR 深度，请返回手动录入尺寸，并用「拍照」添加照片。"))
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

    private var stable: Bool { scan.spread <= ScanSession.stableSpread }

    var body: some View {
        ZStack {
            ARContainer(view: scan.view).ignoresSafeArea()
            if scan.phase == .aim {
                Image(systemName: "plus").font(.system(size: 36, weight: .thin)).foregroundStyle(.white).shadow(radius: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).ignoresSafeArea()  // screen center == depth-map center
            }
            VStack {
                Text(scan.status).font(.headline).padding(10).background(.ultraThinMaterial, in: Capsule())
                Spacer()
                VStack(spacing: 8) {
                    HStack(spacing: 16) {
                        if scan.phase != .aim { SectorRing(covered: scan.sectors) }
                        Text(dims).font(.title2.monospacedDigit().bold())
                    }
                    if scan.sampleCount >= 2 {
                        Text(String(format: "离散度 %.1f%%（%d 次）", scan.spread * 100, scan.sampleCount)
                         + (stable ? "" : " 不稳定，建议重扫"))
                            .font(.footnote).foregroundStyle(stable ? .green : .yellow)
                    }
                    HStack(spacing: 12) {
                        Button("取消") { dismiss() }.buttonStyle(.bordered)
                        Button("重置") { scan.reset() }.buttonStyle(.bordered)
                        Button("完成", action: deliver).buttonStyle(.borderedProminent).disabled(scan.median == nil)
                    }
                }
                .padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16)).padding()
            }
        }
        .onAppear { scan.start() }
        .onDisappear { scan.pause() }
        .onChange(of: scan.phase) { _, p in if p == .done { deliver() } }
    }

    private var dims: String {
        guard let m = scan.median else { return "— × — × — cm" }
        return String(format: "%.1f × %.1f × %.1f cm", m.length * 100, m.width * 100, m.height * 100)
    }

    /// Single result path for 完成 and auto-finish. Calibration offset is applied here and only here:
    /// each side minus offset, 0.1 cm resolution, >= 0.1.
    /// confidence = max(0, 1 - spread) (spread = max relative L/W/H range over the retained samples:
    /// last 5 fused estimates after lock, last 10 single-frame ones before).
    private func deliver() {
        guard !delivered, let m = scan.median else { return }
        delivered = true
        var r = ScanResult(m, confidence: max(0, 1 - Double(scan.spread)), photo: scan.lockPhoto ?? scan.capturePhoto())
        let adj = { (cm: Double) in max(0.1, ((cm - offsetCm) * 10).rounded() / 10) }
        r.lengthCm = adj(r.lengthCm); r.widthCm = adj(r.widthCm); r.heightCm = adj(r.heightCm)
        onResult(r)
    }
}

/// 12 arc segments, one per 30° azimuth sector around the box (not rotated to the camera heading).
private struct SectorRing: View {
    let covered: [Bool]
    var body: some View {
        ZStack {
            ZStack {
                ForEach(covered.indices, id: \.self) { i in
                    let n = CGFloat(covered.count)
                    Circle().trim(from: (CGFloat(i) + 0.08) / n, to: (CGFloat(i) + 0.92) / n)
                        .stroke(covered[i] ? Color.green : Color.white.opacity(0.35), lineWidth: 6)
                }
            }
            .rotationEffect(.degrees(-90))
            Text("\(covered.filter { $0 }.count)").font(.caption.monospacedDigit().bold())
        }
        .frame(width: 48, height: 48)
    }
}

private struct ARContainer: UIViewRepresentable {
    let view: ARSCNView
    func makeUIView(context: Context) -> ARSCNView { view }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
