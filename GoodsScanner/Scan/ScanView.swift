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
    @State private var orbitHint = false

    private var stable: Bool { scan.spread <= ScanSession.stableSpread }
    private var coveredCount: Int { scan.sectors.filter { $0 }.count }

    var body: some View {
        ZStack {
            ARContainer(view: scan.view).ignoresSafeArea()
            if scan.phase == .aim {
                Image(systemName: "plus").font(.system(size: 36, weight: .thin)).foregroundStyle(.white).shadow(radius: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).ignoresSafeArea()  // screen center == depth-map center
            }
            VStack(spacing: 12) {
                statusCapsule
                Spacer()
                if scan.phase == .aim {
                    guide("ScanAim", "对准箱顶，保持 1 秒")
                } else if orbitHint && scan.phase == .scan && coveredCount <= 1 {  // lock already covers 1 sector
                    guide("ScanOrbit", "绕箱子走一圈")
                }
                bottomCard
            }
            .padding(16)
            .animation(.easeInOut(duration: 0.3), value: scan.phase)
            .animation(.easeInOut(duration: 0.3), value: orbitHint)
            .animation(.easeInOut(duration: 0.3), value: coveredCount <= 1)
        }
        .environment(\.colorScheme, .dark)  // HUD over camera feed
        .onAppear { scan.start() }
        .onDisappear { scan.pause() }
        .onChange(of: scan.phase) { _, p in if p == .done { deliver() } }
        .task(id: scan.phase) {
            guard scan.phase == .scan else { orbitHint = false; return }
            orbitHint = true
            try? await Task.sleep(for: .seconds(3))
            orbitHint = false
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

    private func guide(_ image: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(image).resizable().scaledToFit().frame(width: 72, height: 56)
            Text(text).font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .transition(.opacity)
    }

    private var bottomCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                SectorRing(covered: scan.sectors)
                VStack(alignment: .leading, spacing: 2) {
                    Text("长 × 宽 × 高").font(.caption).foregroundStyle(.secondary)
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
        return String(format: "%.1f × %.1f × %.1f", m.length * 100, m.width * 100, m.height * 100)
    }

    /// Single result path for 完成 and auto-finish. Calibration offset is applied here and only here:
    /// each side minus offset, 0.1 cm resolution, >= 0.1.
    /// confidence = max(0, 1 - spread) (spread = max relative L/W/H range over the retained samples:
    /// last 5 fused estimates after lock, last 10 single-frame ones before).
    /// Photos (C2): every shot (or one current frame if none) annotated with the measured box geometry
    /// and the delivered, post-offset numbers.
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
                        .stroke(covered[i] ? Color.scan : Color.secondary.opacity(0.35), lineWidth: 6)
                }
            }
            .rotationEffect(.degrees(-90))
            Text("\(covered.filter { $0 }.count)/\(covered.count)").font(.num(.caption2))
        }
        .frame(width: 60, height: 60)
    }
}

private struct ARContainer: UIViewRepresentable {
    let view: ARSCNView
    func makeUIView(context: Context) -> ARSCNView { view }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
