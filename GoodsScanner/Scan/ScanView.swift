import SwiftUI
import ARKit
import AVFoundation
import BoxMeasureKit

/// Scan screen: LiDAR, or the camera-only pipeline (SPEC §14) without LiDAR / with 设置 → 强制相机模式.
/// Falls back to an explanation on simulator / devices without world tracking.
struct ScanView: View {
    let onResult: (ScanResult) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("forceCameraMode") private var storedForceCamera = false
    /// Release builds ignore the stored debug switch (testers' phones may carry a stale `true`).
    private var forceCamera: Bool { storedForceCamera && DebugTools.available }

    var body: some View {
        if cameraScanAvailable {
            ARScanScreen(onResult: onResult, cameraMode: !lidarAvailable || forceCamera)
        } else if scanGuidanceDemo {
            demo
        } else {
            NavigationStack {
                EmptyState(image: "ScanAim", title: "AR scanning unavailable",
                           message: "This device or simulator doesn't support AR scanning. Go back to enter the size by hand, and use Take Photo to add photos.",
                           action: ("Enter size manually", { dismiss() }))
                    .toolbar { Button("Close") { dismiss() } }
            }
        }
    }

    /// `-scanGuidanceDemo` (Debug only, see `scanGuidanceDemo`).
    @ViewBuilder private var demo: some View {
        #if DEBUG
        ScanGuidanceDemo(camera: !CommandLine.arguments.contains("-lidar")).overlay(alignment: .topTrailing) {
            Button("Close") { dismiss() }.buttonStyle(.borderedProminent).padding(.top, 60).padding(.trailing, 16)
        }
        #endif
    }
}

private struct ARScanScreen: View {
    let onResult: (ScanResult) -> Void
    let cameraMode: Bool
    @StateObject private var scan = ScanSession()
    @AppStorage("calibrationOffsetCm") private var offsetCm = 0.0
    @Environment(\.dismiss) private var dismiss
    @State private var delivered = false
    @State private var ringCenter: CGPoint?
    @State private var tickShots = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("debugMode") private var storedDebugMode = false
    private var debugMode: Bool { storedDebugMode && DebugTools.available }
    @State private var review: Review?
    @State private var cameraDenied = false

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
        if cameraDenied || scan.cameraDenied {
            NavigationStack {
                EmptyState(image: "ScanAim", title: "Camera access needed",
                           message: "Allow camera access in Settings to measure items, or go back to enter the size by hand.",
                           action: ("Open Settings", { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }))
                    .toolbar { Button("Close") { dismiss() } }
            }
        } else {
            scanScreen
        }
    }

    private var scanScreen: some View {
        ZStack {
            ARContainer(view: scan.view).ignoresSafeArea()
            ScanGuidance(phase: scan.phase, surface: scan.aimSurface, progress: scan.lockProgress, ringCenter: ringCenter,
                         cameraStage: cameraMode ? scan.cameraStage : nil)
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
        .task {
            // Don't start AR without camera access: the view would stay black. ARKit's own prompt is pre-empted here.
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: break
            case .notDetermined: guard await AVCaptureDevice.requestAccess(for: .video) else { cameraDenied = true; return }
            default: cameraDenied = true; return
            }
            scan.debug = debugMode; scan.cameraMode = cameraMode; scan.start()
        }
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
        ScanCard(phase: scan.phase, cameraStage: cameraMode ? scan.cameraStage : nil, sectors: scan.sectors, median: scan.median,
                 spread: scan.spread, sampleCount: scan.sampleCount, shots: scan.shots.count,
                 onCancel: { dismiss() }, onReset: { scan.reset() }, onDone: deliver)
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
        r.method = cameraMode ? "camera" : "lidar"
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

/// Bottom card of the scan screen: coverage ring, size readout, note, Cancel / Reset / Done.
/// `cameraStage` nil = LiDAR. Camera mode: before lock a neutral "— × — × —" with an aim hint; while collecting,
/// "walk halfway around" progress with the k/needed ring; then "Measuring…" until the first hull estimate (SPEC §14 F5: >= cameraMinSectors sectors). Also used by ScanGuidanceDemo.
struct ScanCard: View {
    let phase: ScanSession.Phase
    let cameraStage: ScanSession.CameraStage?
    let sectors: [Bool]
    let median: BoxEstimate?
    let spread: Float
    let sampleCount: Int
    let shots: Int
    var onCancel: () -> Void = {}
    var onReset: () -> Void = {}
    var onDone: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var stable: Bool { spread <= ScanSession.stableSpread }
    private var camera: Bool { cameraStage != nil }
    private var covered: Int { sectors.filter { $0 }.count }
    private var collecting: Bool { if case .collecting = cameraStage { true } else { false } }
    /// Camera mode, not locked yet: neutral placeholder readout.
    private var preLock: Bool {
        switch cameraStage { case .findingFloor, .searching, .locking: true; default: false }
    }
    /// Camera mode after lock, before the first estimate: sectors needed to measure (0 = enough, measuring).
    private var gate: Int? {
        guard median == nil, phase != .done else { return nil }
        return collecting ? ScanSession.cameraMinSectors : cameraStage == .measuring ? 0 : nil
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                SectorRing(covered: sectors, done: phase == .done, needed: collecting ? ScanSession.cameraMinSectors : nil)
                    .background(GeometryReader { g in
                        let f = g.frame(in: .named(ScanGuidance.space))
                        Color.clear.preference(key: RingCenterKey.self, value: CGPoint(x: f.midX, y: f.midY))
                    })
                VStack(alignment: .leading, spacing: 2) {
                    if let gate { walkProgress(gate) } else { readout }
                    HStack(spacing: 4) {
                        Text(camera ? "Camera estimate · about ±3 cm" : "Measured by maximum outer dimensions")
                        if shots > 0 { Text("· \(shots)/\(ScanSession.maxShots) photos") }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    if sampleCount >= 2 {
                        let pct = Double(spread).formatted(.percent.precision(.fractionLength(1)))
                        Group {
                            if stable { Text("Spread \(pct) (\(sampleCount) samples)") }
                            else { Text("Spread \(pct) (\(sampleCount) samples), unstable, rescan recommended") }
                        }
                        .font(.caption).foregroundStyle(stable ? Color.scan : Color.warn)
                    }
                }
                .animation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy, value: gate)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button("Cancel", action: onCancel).buttonStyle(SecondaryButtonStyle())
                Button("Reset", action: onReset).buttonStyle(SecondaryButtonStyle())
                Button("Done", action: onDone).buttonStyle(PrimaryButtonStyle()).disabled(median == nil)
                    .accessibilityHint(median != nil ? Text("") : camera ? Text("Available after walking halfway around the item")
                                       : Text("Available once the size is measured"))
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    /// Camera mode, no estimate yet: progress toward half a lap, or "Measuring…" once enough views exist.
    @ViewBuilder private func walkProgress(_ needed: Int) -> some View {
        if needed == 0 {
            Text("Measuring…").font(.headline).transition(.opacity)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Walk halfway around to measure").font(.headline)
                // Plain bar, not ProgressView: renders in ImageRenderer (CameraStageRenderTests).
                Capsule().fill(.white.opacity(0.2)).frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { g in
                            Capsule().fill(Color.scan).frame(width: g.size.width * CGFloat(min(covered, needed)) / CGFloat(needed))
                        }
                    }
                    .animation(reduceMotion ? nil : .snappy, value: covered)
                    .accessibilityHidden(true)   // SectorRing carries the k/needed label
            }
            .transition(.opacity)
        }
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(preLock ? "Aim at the item" : median?.shape == .cylinder ? "Diameter × H" : "L × W × H")
                    .font(.caption).foregroundStyle(.secondary)
                if let m = median { ShapeChip(shape: m.shape.rawValue) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(dims).font(.num(.title))
                    .contentTransition(reduceMotion ? .opacity : .numericText())
                    .animation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy, value: dims)
                Text("cm").font(.subheadline).foregroundStyle(.secondary)
            }
            .lineLimit(1).minimumScaleFactor(0.6)
        }
        .transition(.opacity)
    }

    private var dims: String {
        guard let m = median else { return "— × — × —" }
        let f = { (v: Float) in Double(v * 100).localized(1...1) }
        if m.shape == .cylinder { return String(localized: "Ø \(f(m.length)) × H \(f(m.height))") }
        return "\(f(m.length)) × \(f(m.width)) × \(f(m.height))"
    }
}
