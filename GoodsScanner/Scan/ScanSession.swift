import ARKit
import SceneKit
import CoreImage
import BoxMeasureKit

/// Depth -> world point cloud -> BoxMeasureKit, plus the AR wireframe and the lock-time photo.
/// Threading: ARSession delegate runs on main (default). Each throttled frame is copied into plain
/// arrays on main (ARFrame is never retained) and processed on `queue`. `ring`, `aggregator` and
/// `lastSeed` are touched only on `queue`; @Published state and SceneKit only on main.
final class ScanSession: NSObject, ObservableObject, ARSessionDelegate {
    @Published private(set) var median: BoxEstimate?
    @Published private(set) var spread: Float = 0
    @Published private(set) var sampleCount = 0
    @Published private(set) var status = "对准箱顶，周围留出地面"

    let view = ARSCNView(frame: .zero)
    private let wireframe = ScanSession.makeWireframe()
    private let ciContext = CIContext()

    // main only
    private var busy = false
    private var lastTime: TimeInterval = 0
    // queue only
    private let queue = DispatchQueue(label: "GoodsScanner.scan", qos: .userInitiated)
    private var ring: [[SIMD3<Float>]] = []
    private var aggregator = BoxAggregator(capacity: 10)
    private var lastSeed: SIMD3<Float>?

    static let interval: TimeInterval = 0.2
    static let fuseFrames = 3
    static let minHighPoints = 2000
    static let seedJump: Float = 0.10
    static let stableSpread: Float = 0.05

    override init() {
        super.init()
        view.scene = SCNScene()
        view.scene.rootNode.addChildNode(wireframe)
        view.session.delegate = self
    }

    func start() {
        let c = ARWorldTrackingConfiguration()
        c.planeDetection = []
        c.frameSemantics = ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) ? .smoothedSceneDepth : .sceneDepth
        view.session.run(c, options: [.resetTracking, .removeExistingAnchors])
        reset()
    }

    func pause() { view.session.pause() }

    /// Clears fused points and samples (user aimed elsewhere / tracking reset / 重置).
    func reset(status: String = "对准箱顶，周围留出地面") {
        queue.async {
            self.ring.removeAll(); self.aggregator.reset(); self.lastSeed = nil
            self.finish(nil, status)
        }
    }

    /// Current camera image, portrait (app is portrait-locked; back camera buffer is landscape-right).
    func capturePhoto() -> UIImage? {
        guard let buf = view.session.currentFrame?.capturedImage else { return nil }
        let ci = CIImage(cvPixelBuffer: buf).oriented(.right)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: ARSessionDelegate (main queue)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard !busy, frame.timestamp - lastTime >= Self.interval else { return }
        lastTime = frame.timestamp
        guard case .normal = frame.camera.trackingState else {
            return reset(status: "缓慢移动手机以完成追踪")
        }
        guard let depth = frame.smoothedSceneDepth ?? frame.sceneDepth,
              CVPixelBufferGetPixelFormatType(depth.depthMap) == kCVPixelFormatType_DepthFloat32,
              let d = copyPixels(depth.depthMap, Float.self) else { return }
        let conf = depth.confidenceMap.flatMap { copyPixels($0, UInt8.self) }.flatMap { $0.w == d.w && $0.h == d.h ? $0 : nil }
        let snap = Snapshot(depth: d.data, conf: conf?.data, w: d.w, h: d.h, transform: frame.camera.transform,
                            intrinsics: frame.camera.intrinsics, res: frame.camera.imageResolution)
        busy = true
        queue.async { self.process(snap) }
    }

    // MARK: processing (queue)

    private struct Snapshot {
        var depth: [Float]; var conf: [UInt8]?; var w: Int; var h: Int
        var transform: simd_float4x4; var intrinsics: simd_float3x3; var res: CGSize
    }

    private func process(_ s: Snapshot) {
        // Intrinsics are for capturedImage (landscape, same orientation as the depth map); scale to
        // depth-map pixels. Origin is the center of the upper-left pixel, hence the +/-0.5.
        let sx = Float(s.w) / Float(s.res.width), sy = Float(s.h) / Float(s.res.height)
        let K = s.intrinsics
        let fx = K[0][0] * sx, fy = K[1][1] * sy
        let cx = (K[2][0] + 0.5) * sx - 0.5, cy = (K[2][1] + 0.5) * sy - 0.5
        // Camera space: x right, y up, looking down -z; image v grows downward -> flip y and z.
        func world(_ u: Int, _ v: Int) -> SIMD3<Float>? {
            let d = s.depth[v * s.w + u]
            guard d.isFinite, d > 0 else { return nil }
            let p = s.transform * SIMD4((Float(u) - cx) * d / fx, -(Float(v) - cy) * d / fy, -d, 1)
            return SIMD3(p.x, p.y, p.z)
        }
        func level(_ u: Int, _ v: Int) -> UInt8 { s.conf?[v * s.w + u] ?? 2 }  // ARConfidenceLevel raw: 0 low, 1 medium, 2 high

        var high: [SIMD3<Float>] = [], medium: [SIMD3<Float>] = []
        high.reserveCapacity(s.w * s.h)
        for v in 0..<s.h { for u in 0..<s.w {
            let c = level(u, v)
            guard c >= 1, let p = world(u, v) else { continue }
            if c >= 2 { high.append(p) } else { medium.append(p) }
        } }
        let points = high.count >= Self.minHighPoints ? high : high + medium

        // Seed: median of the central 5x5 window (depth-map center == screen center, portrait aspect-fill).
        var win: [SIMD3<Float>] = [], winMed: [SIMD3<Float>] = []
        for v in (s.h / 2 - 2)...(s.h / 2 + 2) { for u in (s.w / 2 - 2)...(s.w / 2 + 2) {
            let c = level(u, v)
            guard c >= 1, let p = world(u, v) else { continue }
            if c >= 2 { win.append(p) } else { winMed.append(p) }
        } }
        if win.count < 5 { win += winMed }
        guard win.count >= 5 else { return finish(nil, "准星处无有效深度，靠近一点") }
        let seed = SIMD3(Self.median(win.map(\.x)), Self.median(win.map(\.y)), Self.median(win.map(\.z)))

        ring.append(points)
        if ring.count > Self.fuseFrames { ring.removeFirst(ring.count - Self.fuseFrames) }
        if let last = lastSeed, simd_length(SIMD2(seed.x - last.x, seed.z - last.z)) > Self.seedJump { aggregator.reset() }
        lastSeed = seed

        guard let e = BoxMeasurer.estimate(points: Array(ring.joined()), seed: seed) else {
            return finish(nil, points.count < Self.minHighPoints ? "点云不足，靠近一点" : "未识别到箱体：对准箱顶，周围留出地面")
        }
        aggregator.add(e)
        let n = aggregator.samples.count, sp = aggregator.spread
        finish(e, n < 5 ? "测量中，保持对准…" : sp <= Self.stableSpread ? "稳定，可锁定" : "不稳定，保持手机不动或重扫")
    }

    private func finish(_ latest: BoxEstimate?, _ status: String) {
        let med = aggregator.median(), sp = aggregator.spread, n = aggregator.samples.count
        DispatchQueue.main.async {
            self.busy = false
            self.median = med; self.spread = sp; self.sampleCount = n
            self.publish(latest, status: status)
        }
    }

    // MARK: main-thread UI state

    private func publish(_ latest: BoxEstimate?, status: String) {
        self.status = status
        guard let e = latest else { wireframe.isHidden = true; return }
        wireframe.isHidden = false
        wireframe.simdPosition = e.center + SIMD3(0, e.height / 2, 0)
        // BoxMeasureKit yaw: length axis = (cos yaw, 0, -sin yaw) = +x rotated by yaw about +y.
        wireframe.simdOrientation = simd_quatf(angle: e.yaw, axis: SIMD3(0, 1, 0))
        wireframe.simdScale = SIMD3(e.length, e.height, e.width)
        wireframe.geometry?.firstMaterial?.diffuse.contents = spread <= Self.stableSpread ? UIColor.green : UIColor.yellow
    }

    /// Unit cube, 12 edges as line primitives (SCNBox .lines would also draw face diagonals).
    private static func makeWireframe() -> SCNNode {
        let corners = (0..<8).map { i in SCNVector3(Float(i & 1) - 0.5, Float(i >> 1 & 1) - 0.5, Float(i >> 2 & 1) - 0.5) }
        var idx: [Int32] = []
        for i in 0..<8 { for bit in [1, 2, 4] where i & bit == 0 { idx += [Int32(i), Int32(i | bit)] } }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: corners)],
                            elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor.green
        g.materials = [m]
        let node = SCNNode(geometry: g)
        node.isHidden = true
        return node
    }

    private static func median(_ v: [Float]) -> Float { v.sorted()[v.count / 2] }
}

/// Tight copy of a single-plane pixel buffer (honours row padding).
private func copyPixels<T>(_ buf: CVPixelBuffer, _: T.Type) -> (data: [T], w: Int, h: Int)? {
    CVPixelBufferLockBaseAddress(buf, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
    let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf), bpr = CVPixelBufferGetBytesPerRow(buf)
    guard let base = CVPixelBufferGetBaseAddress(buf), bpr >= w * MemoryLayout<T>.stride else { return nil }
    let data = [T](unsafeUninitializedCapacity: w * h) { out, count in
        let dst = UnsafeMutableRawPointer(out.baseAddress!)
        for r in 0..<h { dst.advanced(by: r * w * MemoryLayout<T>.stride).copyMemory(from: base.advanced(by: r * bpr), byteCount: w * MemoryLayout<T>.stride) }
        count = w * h
    }
    return (data, w, h)
}
