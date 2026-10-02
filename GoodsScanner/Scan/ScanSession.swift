import ARKit
import SceneKit
import CoreImage
import BoxMeasureKit

/// Walk-around scan (SPEC §9): aim (single-frame estimate on the crosshair seed) -> seed lock ->
/// scan (depth points fused into a VoxelCloud while the user circles the box) -> done.
/// Threading: ARSession delegate runs on main (default). Each throttled frame is copied into plain
/// arrays on main (ARFrame is never retained) and processed on `queue`. Everything under "queue only"
/// is touched only on `queue`; @Published state (incl. `shots`) and SceneKit only on main.
/// Mesh overlay: see MeshOverlay (own queue).
final class ScanSession: NSObject, ObservableObject, ARSessionDelegate {
    enum Phase { case aim, scan, done }

    @Published private(set) var phase = Phase.aim
    @Published private(set) var median: BoxEstimate?
    @Published private(set) var spread: Float = 0
    @Published private(set) var sampleCount = 0
    @Published private(set) var status = ScanSession.aimHint
    @Published private(set) var sectors = [Bool](repeating: false, count: ScanSession.sectorCount)
    /// C1: photo at seed lock + one per newly covered sector >= 90° from all photographed ones, max 4.
    /// Raw (unannotated); ScanView annotates them with the final estimate and calls `clearShots()`.
    @Published private(set) var shots: [CameraShot] = []
    /// D4 overlay data (published with every processed frame) and ARKit tracking state (debug only).
    @Published private(set) var debugInfo = ScanDebugInfo()
    @Published private(set) var tracking = ""
    /// D4/D7: set by ScanView from 设置 → 调试模式 before `start()`. Main only (copied into each Snapshot).
    var debug = false

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
    private var lastVertical = false
    private var seedHistory: [(t: TimeInterval, p: SIMD3<Float>, vertical: Bool)] = []
    private var lockedSeed: SIMD3<Float>?
    private var lockedVertical = false
    private var scanParams = ScanSession.voxelParams
    /// Voxel cloud upward crop: seed.y + maxAboveSeed (top seed) or + maxBoxSize (side seed, D1).
    /// The estimator ignores points above this anyway; dropping them early keeps walls/ceiling out.
    private var cloudTop: Float = 0
    private var cloud: VoxelCloud?
    private var scanAgg = BoxAggregator(capacity: ScanSession.finishSamples)
    private var lastScanEstimate: BoxEstimate?
    private var lastEstimateTime: TimeInterval = 0
    private var covered = [Bool](repeating: false, count: ScanSession.sectorCount)
    private var photoSectors: [Int] = []
    private var dbg = ScanDebugInfo()
    private var lastReasonTime: TimeInterval = -.infinity

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
    static let minHits = 2
    static let voxelParams = Params.fused  // passes the orbit tests (BoxMeasureKitTests testOrbit*) + DeviceLogTests
    /// Aim phase is single-view: silhouette bleed inflates max-extent by ~2 cm, so use the top-slab footprint.
    static let aimParams: Params = { var p = Params(); p.maxExtent = false; return p }()
    /// D1 side seed (the kit forces the max-extent path for it).
    static let aimSideParams: Params = { var p = aimParams; p.seedOnSide = true; return p }()
    static let aimHint = "对准箱顶或侧面，周围留出地面"
    /// D7: without debug mode, estimateDebug runs only on a miss and at most this often (it is slower).
    static let reasonInterval: TimeInterval = 1.0
    static let sectorCount = 12
    static let finishSectors = 9
    static let finishSamples = 5
    static let finishSpread: Float = 0.02
    static let maxShots = 4
    static let shotSectorGap = 3            // 90°

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

    /// Back to aim: clears seed lock, fused points, samples and coverage (重置 / tracking lost / 重新扫描).
    func reset(status: String = ScanSession.aimHint) {
        queue.async {
            self.qPhase = .aim
            self.ring.removeAll(); self.aggregator.reset(); self.lastSeed = nil; self.seedHistory.removeAll()
            self.lockedSeed = nil; self.cloud = nil; self.scanAgg.reset(); self.lastScanEstimate = nil
            self.covered = Array(repeating: false, count: Self.sectorCount); self.photoSectors.removeAll()
            self.dbg = ScanDebugInfo(); self.lastReasonTime = -.infinity
            self.finish(nil, status)
        }
    }

    /// Current camera image, portrait (app is portrait-locked; back camera buffer is landscape-right),
    /// with the pose/intrinsics of that same frame. Main only.
    /// ponytail: CIContext render on main (~tens of ms, <= 4x per scan); move to a queue with a reset
    /// generation check if it shows up as a hitch.
    func captureShot() -> CameraShot? {
        guard let frame = view.session.currentFrame else { return nil }
        let cam = frame.camera
        let ci = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return CameraShot(image: cg, transform: cam.transform, intrinsics: cam.intrinsics, imageResolution: cam.imageResolution)
    }

    /// Release the full-res photos once they are delivered.
    func clearShots() { shots.removeAll() }

    /// D4/D5 (debug-mode finish): stop processing, then hand the final fused cloud and its `estimateDebug`
    /// to `done` on main (phase becomes .done). Before lock (完成 during aim) it falls back to the last
    /// fused frames with the aim params. The estimate runs on `queue`.
    func finishCapture(_ done: @escaping (ScanCapture) -> Void) {
        queue.async {
            self.qPhase = .done
            let locked = self.lockedSeed != nil
            let seed = self.lockedSeed ?? self.lastSeed ?? .zero
            let vertical = locked ? self.lockedVertical : self.lastVertical
            let params = locked ? self.scanParams : vertical ? Self.aimSideParams : Self.aimParams
            let pts = self.cloud?.centroids(minHits: Self.minHits) ?? Array(self.ring.joined())
            let (e, d) = BoxMeasurer.estimateDebug(points: pts, seed: seed, params: params)
            let cap = ScanCapture(points: pts, seed: seed, vertical: vertical, params: params, estimate: e, debug: d,
                                  sectors: self.covered.filter { $0 }.count, voxels: self.cloud?.count ?? 0)
            DispatchQueue.main.async { self.phase = .done; done(cap) }
        }
    }

    // MARK: ARSessionDelegate (main queue)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard phase != .done, !busy, frame.timestamp - lastTime >= Self.interval else { return }
        lastTime = frame.timestamp
        if debug {
            let t: String = switch frame.camera.trackingState {
            case .normal: "normal"
            case .notAvailable: "notAvailable"
            case .limited(let r): "limited(\(r))"
            }
            if tracking != t { tracking = t }
        }
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
                            intrinsics: frame.camera.intrinsics, res: frame.camera.imageResolution, time: frame.timestamp,
                            debug: debug)
        busy = true
        queue.async { self.process(snap) }
    }

    // MARK: processing (queue)

    private struct Snapshot {
        var depth: [Float]; var conf: [UInt8]?; var w: Int; var h: Int
        var transform: simd_float4x4; var intrinsics: simd_float3x3; var res: CGSize; var time: TimeInterval
        var debug: Bool
    }

    private func process(_ s: Snapshot) {
        // A frame enqueued just before finishCapture / auto-finish: drop it, but release `busy`.
        guard qPhase != .done else { DispatchQueue.main.async { self.busy = false }; return }
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
        dbg.high = high.count; dbg.medium = medium.count

        if qPhase == .scan, let seed = lockedSeed {
            return scanStep(s, points: (high + medium).filter { $0.y <= cloudTop }, seed: seed)
        }
        let points = high.count >= Self.minHighPoints ? high : high + medium

        // Seed: median of the central 5x5 window (depth-map center == screen center, portrait aspect-fill).
        // D1: the surrounding 7x7 window (all conf >= 1) decides top vs side face.
        var win: [SIMD3<Float>] = [], winMed: [SIMD3<Float>] = [], normalWin: [SIMD3<Float>] = []
        for v in (s.h / 2 - 3)...(s.h / 2 + 3) { for u in (s.w / 2 - 3)...(s.w / 2 + 3) {
            let c = level(u, v)
            guard c >= 1, let p = world(u, v) else { continue }
            normalWin.append(p)
            guard abs(u - s.w / 2) <= 2, abs(v - s.h / 2) <= 2 else { continue }
            if c >= 2 { win.append(p) } else { winMed.append(p) }
        } }
        if win.count < 5 { win += winMed }
        guard win.count >= 5 else { seedHistory.removeAll(); return finish(nil, "准星处无有效深度，靠近一点") }
        let seed = SIMD3(Self.median(win.map(\.x)), Self.median(win.map(\.y)), Self.median(win.map(\.z)))
        let vertical = isVerticalSurface(normalWin)
        dbg.vertical = vertical

        ring.append(points)
        if ring.count > Self.fuseFrames { ring.removeFirst(ring.count - Self.fuseFrames) }
        if let last = lastSeed, simd_length(SIMD2(seed.x - last.x, seed.z - last.z)) > Self.seedJump || vertical != lastVertical {
            aggregator.reset()  // don't mix top-seed and side-seed estimates in one median
        }
        lastSeed = seed; lastVertical = vertical

        guard let e = estimate(Array(ring.joined()), seed: seed, params: vertical ? Self.aimSideParams : Self.aimParams, s) else {
            seedHistory.removeAll()
            return finish(nil, dbg.failure.map(Self.text)
                          ?? (points.count < Self.minHighPoints ? "点云不足，靠近一点" : "未识别到箱体：对准箱顶或侧面"))
        }
        aggregator.add(e)

        // B4 seed lock: crosshair seed stayed within 5 cm and on the same face type (D1) for >= 1 s,
        // with an estimate every frame.
        seedHistory.append((s.time, seed, vertical))
        seedHistory.removeAll { s.time - $0.t > Self.lockHold + 0.5 }
        if let first = seedHistory.first, s.time - first.t >= Self.lockHold,
           seedHistory.allSatisfy({ simd_length($0.p - seed) < Self.lockDrift && $0.vertical == vertical }) {
            qPhase = .scan
            lockedSeed = seed
            lockedVertical = vertical
            scanParams = Self.voxelParams
            scanParams.seedOnSide = vertical
            cloudTop = seed.y + (vertical ? scanParams.maxBoxSize : scanParams.maxAboveSeed)
            var c = VoxelCloud(center: seed, radius: Self.cloudRadius, floorY: e.planeY + scanParams.abovePlane)
            for f in ring { c.insert(f.filter { $0.y <= cloudTop }) }
            cloud = c
            lastEstimateTime = s.time
            updateCoverage(s, center: seed)
            photoSectors = [Self.sector(s.transform, center: seed)]
            return finish(e, lockLabel + "，绕箱子走一圈", event: .locked(seed))
        }
        finish(e, "对准箱顶或侧面，保持 1 秒…")
    }

    private var lockLabel: String { lockedVertical ? "已锁定（侧面）" : "已锁定（箱顶）" }

    /// D7. Debug mode: `estimateDebug` every time (overlay data). Otherwise plain `estimate`; on a miss,
    /// `estimateDebug` re-runs at most every `reasonInterval` only to name the failure (the scan-phase
    /// cloud can be ~500k points, so never per attempt there). `dbg.failure` keeps the last known reason
    /// until the next success.
    private func estimate(_ pts: [SIMD3<Float>], seed: SIMD3<Float>, params: Params, _ s: Snapshot) -> BoxEstimate? {
        let t0 = CACurrentMediaTime()
        let e: BoxEstimate?
        if s.debug {
            let (r, d) = BoxMeasurer.estimateDebug(points: pts, seed: seed, params: params)
            e = r
            dbg.planeY = (r?.planeY ?? d.planeY).map { $0 - seed.y }
            dbg.failure = r == nil ? d.failure : nil
        } else {
            e = BoxMeasurer.estimate(points: pts, seed: seed, params: params)
            if e != nil { dbg.failure = nil } else if s.time - lastReasonTime >= Self.reasonInterval {
                lastReasonTime = s.time
                dbg.failure = BoxMeasurer.estimateDebug(points: pts, seed: seed, params: params).1.failure
            }
        }
        dbg.millis = (CACurrentMediaTime() - t0) * 1000
        return e
    }

    static func text(_ f: EstimateFailure) -> String {
        switch f {
        case .noPlane: "未找到地面/托盘，后退一点让支撑面入镜"
        case .noSeedCell: "准星处没有物体"
        case .tooFewPoints: "点太少，靠近一点"
        case .outOfRange: "尺寸超出范围（>2.5 m）"
        }
    }

    private func scanStep(_ s: Snapshot, points: [SIMD3<Float>], seed: SIMD3<Float>) {
        cloud?.insert(points)
        dbg.vertical = lockedVertical
        dbg.voxels = cloud?.count ?? 0; dbg.voxelCap = cloud?.maxVoxels ?? 0
        let center = lastScanEstimate.map { $0.center + SIMD3(0, $0.height / 2, 0) } ?? seed
        // C1: shoot when a newly covered sector is >= 90° from every photographed one.
        if let sec = updateCoverage(s, center: center), photoSectors.count < Self.maxShots,
           photoSectors.allSatisfy({ d in let a = abs(d - sec); return min(a, Self.sectorCount - a) >= Self.shotSectorGap }) {
            photoSectors.append(sec)
            DispatchQueue.main.async { self.takeShot() }
        }
        let n = covered.filter { $0 }.count
        let remaining = max(0, Self.finishSectors - n)
        let coverage = n <= 1 ? lockLabel + "，绕箱子走一圈" : remaining > 0 ? "还差 \(remaining) 个方向" : "覆盖完成，尺寸收敛中…"
        // D7: last known failure (cleared on success), so the text doesn't flicker between estimates.
        var hint: String { dbg.failure.map(Self.text) ?? coverage }

        guard s.time - lastEstimateTime >= Self.estimateInterval, let cloud else { return finish(nil, hint, keepWireframe: true) }
        lastEstimateTime = s.time
        guard let e = estimate(cloud.centroids(minHits: Self.minHits), seed: seed, params: scanParams, s) else {
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
    /// Returns the sector if it was newly covered by this frame.
    @discardableResult
    private func updateCoverage(_ s: Snapshot, center c: SIMD3<Float>) -> Int? {
        let cam = s.transform.columns.3
        let dist = simd_length(SIMD2(cam.x - c.x, cam.z - c.z))
        guard dist >= 0.3, dist <= 2.5 else { return nil }
        let p = simd_inverse(s.transform) * SIMD4(c, 1)
        guard p.z < 0 else { return nil }
        let K = s.intrinsics
        let u = K[0][0] * p.x / -p.z + K[2][0], v = K[2][1] - K[1][1] * p.y / -p.z
        guard u >= 0, u < Float(s.res.width), v >= 0, v < Float(s.res.height) else { return nil }
        let i = Self.sector(s.transform, center: c)
        guard !covered[i] else { return nil }
        covered[i] = true
        return i
    }

    private static func sector(_ transform: simd_float4x4, center c: SIMD3<Float>) -> Int {
        let cam = transform.columns.3
        let a = atan2(cam.z - c.z, cam.x - c.x) + .pi   // 0...2pi
        return min(sectorCount - 1, Int(a / (2 * .pi) * Float(sectorCount)))
    }

    /// Main only. Extra C1 photo with a subtle shutter haptic.
    private func takeShot() {
        guard phase == .scan, shots.count < Self.maxShots, let shot = captureShot() else { return }
        shots.append(shot)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private enum Event { case none, locked(SIMD3<Float>), done }

    private func finish(_ latest: BoxEstimate?, _ status: String, event: Event = .none, keepWireframe: Bool = false) {
        // Scan phase reports the fused estimates; until the first one exists, keep the aim result so 完成 works.
        let agg = qPhase != .aim && !scanAgg.samples.isEmpty ? scanAgg : aggregator
        let med = agg.median(), sp = agg.spread, n = agg.samples.count, phase = qPhase, cov = covered
        var info = dbg
        info.history = Array(agg.samples.suffix(5))
        DispatchQueue.main.async {
            self.busy = false
            self.debugInfo = info
            self.median = med; self.spread = sp; self.sampleCount = n; self.sectors = cov
            switch event {
            case .none: break
            case .locked(let seed):
                self.shots = self.captureShot().map { [$0] } ?? []
                self.overlay.setFocus(seed)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .done:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            self.phase = phase
            if phase == .aim { self.shots.removeAll() }
            if !keepWireframe { self.publish(latest, status: status) } else { self.status = status }
        }
    }

    // MARK: main-thread UI state

    private func publish(_ latest: BoxEstimate?, status: String) {
        self.status = status
        if latest != nil || median == nil { overlay.setBox(latest) }  // transient misses keep the last colouring
        guard let e = latest else { wireframe.isHidden = true; return }
        wireframe.isHidden = false
        Self.place(wireframe, e)
        wireframe.geometry?.firstMaterial?.diffuse.contents = spread <= Self.stableSpread ? UIColor.green : UIColor.yellow
    }

    /// Fit the unit-cube wireframe to `e`.
    static func place(_ node: SCNNode, _ e: BoxEstimate) {
        node.simdPosition = e.center + SIMD3(0, e.height / 2, 0)
        // BoxMeasureKit yaw: length axis = (cos yaw, 0, -sin yaw) = +x rotated by yaw about +y.
        node.simdOrientation = simd_quatf(angle: e.yaw, axis: SIMD3(0, 1, 0))
        node.simdScale = SIMD3(e.length, e.height, e.width)
    }

    /// Unit cube, 12 edges as line primitives (SCNBox .lines would also draw face diagonals).
    static func makeWireframe() -> SCNNode {
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
