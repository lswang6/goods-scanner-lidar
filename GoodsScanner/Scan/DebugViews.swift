import SwiftUI
import SceneKit
import BoxMeasureKit

// SPEC §11 D4/D5: debug-mode overlay, point-cloud review and on-disk scan logs.

/// Per-frame diagnostics published by ScanSession (filled on its queue, copied to main in `finish`).
struct ScanDebugInfo {
    var vertical: Bool?
    /// Support plane y relative to the seed (m, negative = below).
    var planeY: Float?
    var high = 0, medium = 0
    var voxels = 0, voxelCap = 0
    var millis: Double = 0
    var failure: EstimateFailure?
    var history: [BoxEstimate] = []
}

/// Final fused cloud + its `estimateDebug`, captured when a debug-mode scan finishes.
struct ScanCapture {
    var points: [SIMD3<Float>]
    var seed: SIMD3<Float>
    var vertical: Bool
    var params: Params
    var estimate: BoxEstimate?
    var debug: EstimateDebug
    var sectors: Int
    var voxels: Int
}

/// `Documents/ScanLogs/<yyyyMMdd-HHmmss>/` (scan.json + points.ply via ScanLogIO). Visible in 文件 App
/// through UIFileSharingEnabled.
enum ScanLogStore {
    static var dir: URL { URL.documentsDirectory.appending(path: "ScanLogs", directoryHint: .isDirectory) }

    static var count: Int {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter(\.hasDirectoryPath).count ?? 0
    }

    static func clear() { try? FileManager.default.removeItem(at: dir) }

    /// Background write; `done(true)` on main when saved.
    static func save(_ cap: ScanCapture, delivered: ScanResult, done: @escaping (Bool) -> Void) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let now = Date()
        let url = dir.appending(path: f.string(from: now), directoryHint: .isDirectory)
        let log = ScanLog(date: now, seed: cap.seed, seedVertical: cap.vertical, params: cap.params,
                          estimate: cap.estimate, failure: cap.debug.failure,
                          deliveredCm: [delivered.lengthCm, delivered.widthCm, delivered.heightCm],
                          coveredSectors: cap.sectors, voxelCount: cap.voxels)
        DispatchQueue.global(qos: .utility).async {
            let ok: Bool
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try ScanLogIO.write(points: cap.points, log: log, to: url)
                ok = true
            } catch {
                ok = false
            }
            DispatchQueue.main.async { done(ok) }
        }
    }
}

/// Compact monospaced HUD (top-left, under the status capsule).
struct DebugOverlay: View {
    let info: ScanDebugInfo
    let spread: Float
    let sectors: Int
    let tracking: String

    var body: some View {
        let cm = { (v: Float) in String(format: "%.1f", v * 100) }
        VStack(alignment: .leading, spacing: 1) {
            Text("seed  \(info.vertical.map { $0 ? "side" : "top" } ?? "—")")
            Text("planeY \(info.planeY.map { String(format: "%+.3f m", $0) } ?? "—")")
            Text("frame \(info.high) / \(info.medium) (hi/med)")
            Text("voxels \(info.voxels) / \(info.voxelCap)")
            Text(String(format: "est   %.0f ms", info.millis))
            Text("fail  \(info.failure?.rawValue ?? "—")")
            ForEach(info.history.indices, id: \.self) { i in
                let e = info.history[i]
                Text("  \(cm(e.length)) × \(cm(e.width)) × \(cm(e.height))")
            }
            Text(String(format: "spread %.1f%%  sectors %d/12", spread * 100, sectors))
            Text("track \(tracking)")
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.white)
        .lineLimit(1)
        .padding(6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: Radius.tag, style: .continuous))
        .frame(maxWidth: 240, alignment: .leading)
        .allowsHitTesting(false)
    }
}

/// D4 review: orbitable point cloud (object green / plane blue / other gray) + delivered box + numbers.
struct ScanReviewView: View {
    let capture: ScanCapture
    let box: BoxEstimate
    let result: ScanResult
    let saved: Bool
    let onUse: () -> Void
    let onRescan: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            PointCloudView(capture: capture, box: box)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            VStack(spacing: 4) {
                DimsBadge(l: result.lengthCm, w: result.widthCm, h: result.heightCm, shape: result.shape)
                Group {
                    if let e = capture.estimate {
                        Text("最终点云估计 " + CargoItem.dimsText(Double(e.length * 100), Double(e.width * 100), Double(e.height * 100),
                                                               shape: e.shape.rawValue) + " cm · " + CargoItem.shapeLabel(e.shape.rawValue))
                    } else {
                        Text("最终点云估计失败：\(capture.debug.failure.map(ScanSession.text) ?? "—")")
                    }
                    Text("\(capture.points.count) 点 · 物体 \(capture.debug.objectIndices.count) · 支撑面 \(capture.debug.planeIndices.count) · \(capture.vertical ? "侧面" : "箱顶")种子")
                    if saved { Text("已保存调试数据").foregroundStyle(Color.scanText) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("重新扫描", action: onRescan).buttonStyle(SecondaryButtonStyle())
                Button("使用此结果", action: onUse).buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(16)
        .interactiveDismissDisabled()
    }
}

private struct PointCloudView: UIViewRepresentable {
    let capture: ScanCapture
    let box: BoxEstimate
    static let maxPoints = 200_000

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.backgroundColor = .black
        v.allowsCameraControl = true
        v.antialiasingMode = .none
        v.scene = scene()
        v.pointOfView = v.scene?.rootNode.childNodes.first { $0.camera != nil }
        return v
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    /// Everything is translated so the box center is the origin (allowsCameraControl orbits around it).
    private func scene() -> SCNScene {
        let origin = box.center + SIMD3(0, box.height / 2, 0)
        let pts = capture.points
        var label = [UInt8](repeating: 0, count: pts.count)
        for i in capture.debug.planeIndices where i < pts.count { label[i] = 1 }
        for i in capture.debug.objectIndices where i < pts.count { label[i] = 2 }
        let step = max(1, (pts.count + Self.maxPoints - 1) / Self.maxPoints)
        var verts: [SCNVector3] = [], colors: [SIMD4<Float>] = []
        verts.reserveCapacity(pts.count / step + 1); colors.reserveCapacity(pts.count / step + 1)
        for i in stride(from: 0, to: pts.count, by: step) {
            let p = pts[i] - origin
            verts.append(SCNVector3(p.x, p.y, p.z))
            colors.append(label[i] == 2 ? SIMD4(0.2, 0.9, 0.4, 1) : label[i] == 1 ? SIMD4(0.3, 0.5, 1, 1) : SIMD4(0.55, 0.55, 0.55, 1))
        }
        let scene = SCNScene()
        if !verts.isEmpty {
            let colorSource = SCNGeometrySource(data: colors.withUnsafeBytes { Data($0) }, semantic: .color, vectorCount: colors.count,
                                                usesFloatComponents: true, componentsPerVector: 4,
                                                bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                                dataStride: MemoryLayout<SIMD4<Float>>.stride)
            let element = SCNGeometryElement(indices: Array(0..<Int32(verts.count)), primitiveType: .point)
            element.pointSize = 3
            element.minimumPointScreenSpaceRadius = 1.5
            element.maximumPointScreenSpaceRadius = 1.5
            let g = SCNGeometry(sources: [SCNGeometrySource(vertices: verts), colorSource], elements: [element])
            let m = SCNMaterial()
            m.lightingModel = .constant
            g.materials = [m]
            scene.rootNode.addChildNode(SCNNode(geometry: g))
        }
        let wire = ScanSession.makeWireframe()
        var b = box
        b.center -= origin
        ScanSession.place(wire, b)
        wire.isHidden = false
        wire.geometry?.firstMaterial?.diffuse.contents = UIColor.orange  // fresh geometry per call; stands out from green points
        scene.rootNode.addChildNode(wire)

        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.zNear = 0.01
        let r = max(1.0, max(box.length, box.height) * 2.5)
        cam.simdPosition = SIMD3(0, r * 0.6, r)
        cam.simdLook(at: .zero)
        scene.rootNode.addChildNode(cam)
        return scene
    }
}
