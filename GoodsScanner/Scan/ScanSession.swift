import ARKit
import SceneKit
import CoreImage
import BoxMeasureKit

/// Walk-around scan (SPEC §9): aim (single-frame estimate on the crosshair seed) -> seed lock ->
/// scan (depth points fused into a VoxelCloud while the user circles the box) -> done.
/// Threading: ARSession delegate runs on main (default). Each throttled frame is copied into plain
/// arrays on main (ARFrame is never retained) and processed on `queue`. Everything under "queue only"
/// is touched only on `queue`; @Published state, `lockPhoto` and SceneKit only on main.
/// Mesh overlay: see MeshOverlay (own queue).
final class ScanSession: NSObject, ObservableObject, ARSessionDelegate {
    enum Phase { case aim, scan, done }

    @Published private(set) var phase = Phase.aim
    @Published private(set) var median: BoxEstimate?
    @Published private(set) var spread: Float = 0
    @Published private(set) var sampleCount = 0
    @Published private(set) var status = "瞄准箱顶，周围留出地面"
    @Published private(set) var sectors = [Bool](repeating: false, count: ScanSession.sectorCount)
    /// Photo taken at seed lock (facing the box); nil if 完成 was tapped before lock.
    private(set) var lockPhoto: UIImage?

    let view = ARSCNView(frame: .zero)
    private let overlay = MeshOverlay()
    private let wireframe = ScanSession.makeWireframe()
    private let ciContext = CIContext()

    // main only
    private var busy = false
    private var lastTime: TimeInterval = 0
    // queue only
    private let queue = DispatchQueue(label: "GoodsScanner.scan", qos: .userInitiated)
    private var qPhase = Phase.aim
    private var ring: [[SIMD3<Float>]] = []
    private var aggregator = BoxAggregator(capacity: 10)
    private var lastSeed: SIMD3<Float>?
    private var seedHistory: [(t: TimeInterval, p: SIMD3<Float>)] = []
    private var lockedSeed: SIMD3<Float>?
    private var cloud: VoxelCloud?
    private var scanAgg = BoxAggregator(capacity: ScanSession.finishSamples)
    private var lastScanEstimate: BoxEstimate?
    private var lastEstimateTime: TimeInterval = 0
    private var covered = [Bool](repeating: false, count: ScanSession.sectorCount)

    static let interval: TimeInterval = 0.2
    static let fuseFrames = 3
    static let minHighPoints = 2000
    static let seedJump: Float = 0.10
    static let stableSpread: Float = 0.05
    // walk-around (SPEC §9 B3-B6)
    static let lockDrift: Float = 0.05
    static let lockHold: TimeInterval = 1.0
    static let estimateInterval: TimeInterval = 0.5
    static let cloudRadius: Float = 1.5     // 2 m of floor alone is ~500k 5 mm voxels (the cap); estimator needs <= 1 m
    static let cloudAboveSeed: Float = 0.1  // estimator ignores points above seed.y + 5 cm; drop walls/ceiling early
    static let minHits = 2
    static let voxelParams = Params()       // defaults pass the orbit tests (BoxMeasureKitTests testOrbit*)
    static let sectorCount = 12
    static let finishSectors = 9
    static let finishSamples = 5
    static let finishSpread: Float = 0.02

    override init() {
        super.init()
        view.scene = SCNScene()
        view.scene.rootNode.addChildNode(wireframe)
        view.session.delegate = self
        view.delegate = overlay
    }

    func start() {
        let c = ARWorldTrackingConfiguration()
        c.planeDetection = []
        c.frameSemantics = ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) ? .smoothedSceneDepth : .sceneDepth
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) { c.sceneReconstruction = .mesh }
        view.session.run(c, options: [.resetTracking, .removeExistingAnchors])
        reset()
    }

    func pause() { view.session.pause() }

    /// Back to aim: clears seed lock, fused points, samples and coverage (重置 / tracking lost).
    func reset(status: String = "瞄准箱顶，周围留出地面") {
        queue.async {
            self.qPhase = .aim
            self.ring.removeAll(); self.aggregator.reset(); self.lastSeed = nil; self.seedHistory.removeAll()
            self.lockedSeed = nil; self.cloud = nil; self.scanAgg.reset(); self.lastScanEstimate = nil
            self.covered = Array(repeating: false, count: Self.sectorCount)
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
        guard phase != .done, !busy, frame.timestamp - lastTime >= Self.interval else { return }
        lastTime = frame.timestamp
        let cam = frame.camera.transform.columns.3
        if phase == .aim { overlay.setFocus(SIMD3(cam.x, cam.y, cam.z)) }
        switch frame.camera.trackingState {
        case .normal: break
        case .limited where phase == .scan:
            // Keep seed + voxels; ARKit usually recovers in place. Resume on .normal.
            status = "缓慢移动，保持箱子和周围在画面内"; return
        default:
            return reset(status: "缓慢移动手机以完成追踪")
        }
        guard let depth = frame.smoothedSceneDepth ?? frame.sceneDepth,
              CVPixelBufferGetPixelFormatType(depth.depthMap) == kCVPixelFormatType_DepthFloat32,
              let d = copyPixels(depth.depthMap, Float.self) else { return }
        let conf = depth.confidenceMap.flatMap { copyPixels($0, UInt8.self) }.flatMap { $0.w == d.w && $0.h == d.h ? $0 : nil }
        let snap = Snapshot(depth: d.data, conf: conf?.data, w: d.w, h: d.h, transform: frame.camera.transform,
                            intrinsics: frame.camera.intrinsics, res: frame.camera.imageResolution, time: frame.timestamp)
        busy = true
        queue.async { self.process(snap) }
    }

    // MARK: processing (queue)

    private struct Snapshot {
        var depth: [Float]; var conf: [UInt8]?; var w: Int; var h: Int
        var transform: simd_float4x4; var intrinsics: simd_float3x3; var res: CGSize; var time: TimeInterval
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

        if qPhase == .scan, let seed = lockedSeed {
            return scanStep(s, points: (high + medium).filter { $0.y <= seed.y + Self.cloudAboveSeed }, seed: seed)
        }
        let points = high.count >= Self.minHighPoints ? high : high + medium

        // Seed: median of the central 5x5 window (depth-map center == screen center, portrait aspect-fill).
        var win: [SIMD3<Float>] = [], winMed: [SIMD3<Float>] = []
        for v in (s.h / 2 - 2)...(s.h / 2 + 2) { for u in (s.w / 2 - 2)...(s.w / 2 + 2) {
            let c = level(u, v)
            guard c >= 1, let p = world(u, v) else { continue }
            if c >= 2 { win.append(p) } else { winMed.append(p) }
        } }
        if win.count < 5 { win += winMed }
        guard win.count >= 5 else { seedHistory.removeAll(); return finish(nil, "准星处无有效深度，靠近一点") }
        let seed = SIMD3(Self.median(win.map(\.x)), Self.median(win.map(\.y)), Self.median(win.map(\.z)))

        ring.append(points)
        if ring.count > Self.fuseFrames { ring.removeFirst(ring.count - Self.fuseFrames) }
        if let last = lastSeed, simd_length(SIMD2(seed.x - last.x, seed.z - last.z)) > Self.seedJump { aggregator.reset() }
        lastSeed = seed

        guard let e = BoxMeasurer.estimate(points: Array(ring.joined()), seed: seed) else {
            seedHistory.removeAll()
            return finish(nil, points.count < Self.minHighPoints ? "点云不足，靠近一点" : "未识别到箱体：瞄准箱顶，周围留出地面")
        }
        aggregator.add(e)

        // B4 seed lock: crosshair seed stayed within 5 cm for >= 1 s with an estimate every frame.
        seedHistory.append((s.time, seed))
        seedHistory.removeAll { s.time - $0.t > Self.lockHold + 0.5 }
        if let first = seedHistory.first, s.time - first.t >= Self.lockHold,
           seedHistory.allSatisfy({ simd_length($0.p - seed) < Self.lockDrift }) {
            qPhase = .scan
            lockedSeed = seed
            var c = VoxelCloud(center: seed, radius: Self.cloudRadius)
            for f in ring { c.insert(f.filter { $0.y <= seed.y + Self.cloudAboveSeed }) }
            cloud = c
            lastEstimateTime = s.time
            updateCoverage(s, center: seed)
            return finish(e, "已锁定，绕箱子走一圈", event: .locked(seed))
        }
        finish(e, "瞄准箱顶，保持 1 秒…")
    }

    private func scanStep(_ s: Snapshot, points: [SIMD3<Float>], seed: SIMD3<Float>) {
        cloud?.insert(points)
        let center = lastScanEstimate.map { $0.center + SIMD3(0, $0.height / 2, 0) } ?? seed
        updateCoverage(s, center: center)
        let n = covered.filter { $0 }.count
        let remaining = max(0, Self.finishSectors - n)
        let hint = n <= 1 ? "已锁定，绕箱子走一圈" : remaining > 0 ? "还差 \(remaining) 个方向" : "覆盖完成，尺寸收敛中…"

        guard s.time - lastEstimateTime >= Self.estimateInterval, let cloud else { return finish(nil, hint, keepWireframe: true) }
        lastEstimateTime = s.time
        guard let e = BoxMeasurer.estimate(points: cloud.centroids(minHits: Self.minHits), seed: seed, params: Self.voxelParams) else {
            return finish(nil, hint, keepWireframe: true)
        }
        scanAgg.add(e)
        lastScanEstimate = e
        // B6 auto-finish.
        if remaining == 0, scanAgg.samples.count >= Self.finishSamples, scanAgg.spread <= Self.finishSpread {
            qPhase = .done
            return finish(e, "完成", event: .done)
        }
        finish(e, hint)
    }

    /// B5: sector of the camera's azimuth around `center`, counted only at 0.3-2.5 m with the center in view.
    private func updateCoverage(_ s: Snapshot, center c: SIMD3<Float>) {
        let cam = s.transform.columns.3
        let dist = simd_length(SIMD2(cam.x - c.x, cam.z - c.z))
        guard dist >= 0.3, dist <= 2.5 else { return }
        let p = simd_inverse(s.transform) * SIMD4(c, 1)
        guard p.z < 0 else { return }
        let K = s.intrinsics
        let u = K[0][0] * p.x / -p.z + K[2][0], v = K[2][1] - K[1][1] * p.y / -p.z
        guard u >= 0, u < Float(s.res.width), v >= 0, v < Float(s.res.height) else { return }
        let a = atan2(cam.z - c.z, cam.x - c.x) + .pi   // 0...2pi
        covered[min(Self.sectorCount - 1, Int(a / (2 * .pi) * Float(Self.sectorCount)))] = true
    }

    private enum Event { case none, locked(SIMD3<Float>), done }

    private func finish(_ latest: BoxEstimate?, _ status: String, event: Event = .none, keepWireframe: Bool = false) {
        // Scan phase reports the fused estimates; until the first one exists, keep the aim result so 完成 works.
        let agg = qPhase != .aim && !scanAgg.samples.isEmpty ? scanAgg : aggregator
        let med = agg.median(), sp = agg.spread, n = agg.samples.count, phase = qPhase, cov = covered
        DispatchQueue.main.async {
            self.busy = false
            self.median = med; self.spread = sp; self.sampleCount = n; self.sectors = cov
            switch event {
            case .none: break
            case .locked(let seed):
                self.lockPhoto = self.capturePhoto()
                self.overlay.setFocus(seed)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .done:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            self.phase = phase
            if phase == .aim { self.lockPhoto = nil }
            if !keepWireframe { self.publish(latest, status: status) } else { self.status = status }
        }
    }

    // MARK: main-thread UI state

    private func publish(_ latest: BoxEstimate?, status: String) {
        self.status = status
        if latest != nil || median == nil { overlay.setBox(latest) }  // transient misses keep the last colouring
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
