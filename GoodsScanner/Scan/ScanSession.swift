import ARKit
import SceneKit
import CoreImage
import Vision
import BoxMeasureKit

/// Walk-around scan (SPEC §9): aim (single-frame estimate on the crosshair seed) -> seed lock ->
/// scan (depth points fused into a VoxelCloud while the user circles the box) -> done.
/// Threading: ARSession delegate runs on main (default). Each throttled frame is copied into plain
/// arrays on main (ARFrame is never retained) and processed on `queue`. Everything under "queue only"
/// is touched only on `queue`; @Published state (incl. `shots`) and SceneKit only on main.
/// Mesh overlay: see MeshOverlay (own queue).
enum SurfaceHint { case top, side }

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
    /// Aim-phase guidance (ScanGuidance): face under the crosshair with a valid estimate, and the
    /// fraction of the `lockHold` window satisfied (< 1 until the lock fires; stays 1 after it).
    @Published private(set) var aimSurface: SurfaceHint?
    @Published private(set) var lockProgress = 0.0
    /// D4/D7: set by ScanView from 设置 → 调试模式 before `start()`. Main only (copied into each Snapshot).
    var debug = false
    /// SPEC §14: camera-only pipeline (no depth: Vision foreground masks + visual hull). Set by ScanView before `start()`.
    var cameraMode = false

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
    private var ring: [(points: [SIMD3<Float>], incidence: [SIMD4<Float>], camera: SIMD3<Float>)] = []
    private var aggregator = BoxAggregator(capacity: 10)
    private var lastSeed: SIMD3<Float>?
    private var lastVertical = false
    private var seedHistory: [(t: TimeInterval, p: SIMD3<Float>, vertical: Bool)] = []
    private var lockedSeed: SIMD3<Float>?
    private var lockedVertical = false
    private var scanParams = ScanSession.voxelParams
    /// Voxel cloud + insert crop (BoxMeasureKit.ScanFusion: upper crop seed.y + maxAboveSeed / + maxBoxSize for a
    /// side seed (D1), lower crop planeY - 0.05 and footprint radius once an estimate exists).
    private var fusion: ScanFusion?
    private var scanAgg = BoxAggregator(capacity: ScanSession.finishSamples)
    private var lastScanEstimate: BoxEstimate?
    private var lastEstimateTime: TimeInterval = 0
    private var covered = [Bool](repeating: false, count: ScanSession.sectorCount)
    private var photoSectors: [Int] = []
    private var dbg = ScanDebugInfo()
    private var lastReasonTime: TimeInterval = -.infinity
    private var qSurface: SurfaceHint?
    private var qLockProgress = 0.0
    /// Debug-mode raw-frame log (frames.bin) and the per-frame marks it records.
    private var recorder: FrameRecorder?
    private var qRing = false, qEstimated = false, qLock = false
    // queue only, camera mode (SPEC §14): silhouettes since lock, support plane, hull surface of the last estimate.
    private var qCamera = false
    private var views: [Silhouette] = []
    private var lastViewCamera: SIMD3<Float>?
    private var camFloorY: Float?

    static let interval: TimeInterval = 0.2
    static let fuseFrames = 3
    static let minHighPoints = ScanFusion.minHighPoints
    static let seedJump: Float = 0.10
    static let stableSpread: Float = 0.05
    // walk-around (SPEC §9 B3-B6)
    static let lockDrift: Float = 0.05
    static let lockHold: TimeInterval = 1.0
    static let estimateInterval: TimeInterval = 0.5
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
    /// Auto-finish needs this fraction of wall and of top voxels seen head-on (<= 40°) at least once.
    /// Device logs: overhead-only walk-arounds 0 % walls / 100 % top; low walk-around 96 % walls / 9 % top.
    static let minHeadOn: Float = 0.5

    override init() {
        super.init()
        view.scene = SCNScene()
        view.scene.rootNode.addChildNode(wireframe)
        view.session.delegate = self
        view.delegate = overlay
    }

    func start() {
        let c = ARWorldTrackingConfiguration()
        if cameraMode {
            c.planeDetection = [.horizontal]   // support plane (Self.floorY); no depth, no mesh
        } else {
            c.planeDetection = []
            c.frameSemantics = ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) ? .smoothedSceneDepth : .sceneDepth
            // Debug raw-frame log records both; live fusion still prefers smoothed (`smoothedSceneDepth ?? sceneDepth`).
            if debug, ARWorldTrackingConfiguration.supportsFrameSemantics([.sceneDepth, .smoothedSceneDepth]) {
                c.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
            }
            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) { c.sceneReconstruction = .mesh }
        }
        let camera = cameraMode
        queue.async { self.qCamera = camera }
        view.session.run(c, options: [.resetTracking, .removeExistingAnchors])
        reset(status: camera ? Self.cameraAimHint : Self.aimHint)
    }

    /// Also drops an unfinished debug recording (scan cancelled).
    func pause() {
        view.session.pause()
        queue.async { self.recorder?.cancel(); self.recorder = nil }
    }

    /// Back to aim: clears seed lock, fused points, samples and coverage (重置 / tracking lost / 重新扫描).
    /// Debug recording: kept across aim-phase resets (tracking init resets every frame); a recording that
    /// already locked is discarded and a new one starts.
    func reset(status: String = ScanSession.aimHint) {
        let debug = debug
        queue.async {
            if self.recorder?.locked ?? true { self.recorder?.cancel(); self.recorder = debug ? FrameRecorder() : nil }
            self.qPhase = .aim
            self.ring.removeAll(); self.aggregator.reset(); self.lastSeed = nil; self.seedHistory.removeAll()
            self.lockedSeed = nil; self.fusion = nil; self.scanAgg.reset(); self.lastScanEstimate = nil
            self.covered = Array(repeating: false, count: Self.sectorCount); self.photoSectors.removeAll()
            self.dbg = ScanDebugInfo(); self.lastReasonTime = -.infinity
            self.qSurface = nil; self.qLockProgress = 0
            self.views.removeAll(); self.lastViewCamera = nil
            self.finish(nil, status == Self.aimHint && self.qCamera ? Self.cameraAimHint : status)
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
            if self.qCamera {
                let c = self.lockedSeed ?? .zero, floorY = self.camFloorY ?? c.y
                let r = self.views.isEmpty ? nil : SilhouetteHull.measure(self.views, floorY: floorY, center: SIMD2(c.x, c.z))
                var d = EstimateDebug(); d.planeY = floorY
                d.objectIndices = Array((r?.surface ?? []).indices)
                let cap = ScanCapture(points: r?.surface ?? [], seed: c, vertical: false, params: Params(), estimate: r?.estimate, debug: d,
                                      sectors: self.covered.filter { $0 }.count, voxels: self.views.count, dir: self.recorder?.finish())
                self.recorder = nil
                DispatchQueue.main.async { self.phase = .done; done(cap) }
                return
            }
            let locked = self.lockedSeed != nil
            let seed = self.lockedSeed ?? self.lastSeed ?? .zero
            let vertical = locked ? self.lockedVertical : self.lastVertical
            let params = locked ? self.scanParams : vertical ? Self.aimSideParams : Self.aimParams
            let t = self.fusion?.tagged()
            let pts = t?.points ?? self.ring.flatMap(\.points)
            let (e, d) = BoxMeasurer.estimateDebug(points: pts, seed: seed, params: params, incidence: t?.incidence)
            let cap = ScanCapture(points: pts, seed: seed, vertical: vertical, params: params, estimate: e, debug: d,
                                  sectors: self.covered.filter { $0 }.count, voxels: self.fusion?.cloud.count ?? 0,
                                  dir: self.recorder?.finish())
            self.recorder = nil
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
        if cameraMode {
            let tracking: UInt8 = switch frame.camera.trackingState { case .notAvailable: 0; case .limited: 1; case .normal: 2 }
            let snap = CameraSnapshot(image: frame.capturedImage, transform: frame.camera.transform, intrinsics: frame.camera.intrinsics,
                                      res: frame.camera.imageResolution, time: frame.timestamp, floorY: Self.floorY(frame.anchors),
                                      tracking: tracking, thermal: UInt8(ProcessInfo.processInfo.thermalState.rawValue))
            busy = true
            queue.async { self.processCamera(snap) }
            return
        }
        guard let depth = frame.smoothedSceneDepth ?? frame.sceneDepth,
              CVPixelBufferGetPixelFormatType(depth.depthMap) == kCVPixelFormatType_DepthFloat32,
              let d = copyPixels(depth.depthMap, Float.self) else { return }
        let conf = depth.confidenceMap.flatMap { copyPixels($0, UInt8.self) }.flatMap { $0.w == d.w && $0.h == d.h ? $0 : nil }
        var snap = Snapshot(depth: d.data, conf: conf?.data, w: d.w, h: d.h, transform: frame.camera.transform,
                            intrinsics: frame.camera.intrinsics, res: frame.camera.imageResolution, time: frame.timestamp,
                            debug: debug)
        if debug {
            // Raw-frame log: the other depth map too (live uses smoothed when present, so the other is raw).
            let live: DepthSource = frame.smoothedSceneDepth != nil ? .smoothed : .raw
            let other = (live == .smoothed ? frame.sceneDepth : nil)
                .flatMap { CVPixelBufferGetPixelFormatType($0.depthMap) == kCVPixelFormatType_DepthFloat32 ? $0 : nil }
            let od = other.flatMap { copyPixels($0.depthMap, Float.self) }.flatMap { $0.w == d.w && $0.h == d.h ? $0 : nil }
            let oc = od == nil ? nil : other?.confidenceMap.flatMap { copyPixels($0, UInt8.self) }.flatMap { $0.w == d.w && $0.h == d.h ? $0 : nil }
            let tracking: UInt8 = switch frame.camera.trackingState { case .notAvailable: 0; case .limited: 1; case .normal: 2 }
            snap.extra = .init(live: live, other: od?.data, otherConf: oc?.data, tracking: tracking,
                               thermal: UInt8(ProcessInfo.processInfo.thermalState.rawValue), image: frame.capturedImage)
        }
        busy = true
        queue.async { self.process(snap) }
    }

    // MARK: processing (queue)

    private struct Snapshot {
        var depth: [Float]; var conf: [UInt8]?; var w: Int; var h: Int
        var transform: simd_float4x4; var intrinsics: simd_float3x3; var res: CGSize; var time: TimeInterval
        var debug: Bool
        var extra: Extra?
        /// Debug raw-frame log only.
        /// `image`: camera frame (camera-only research, Phase 0); JPEG-encoded in `record`, then released.
        struct Extra { var live: DepthSource; var other: [Float]?; var otherConf: [UInt8]?; var tracking: UInt8; var thermal: UInt8; var image: CVPixelBuffer }
    }

    /// Queue only. Appends the processed frame to the debug recording with this frame's ring/estimate/lock marks.
    private func record(_ s: Snapshot, phase: Phase) {
        guard let x = s.extra, let recorder else { return }
        let smoothed = x.live == .smoothed
        var f = FrameSample(time: s.time, phase: phase == .scan ? 1 : 0, tracking: x.tracking, thermal: x.thermal,
                            transform: s.transform, intrinsics: s.intrinsics, res: SIMD2(Float(s.res.width), Float(s.res.height)),
                            w: s.w, h: s.h, raw: smoothed ? x.other : s.depth, rawConf: smoothed ? x.otherConf : s.conf,
                            smoothed: smoothed ? s.depth : nil, smoothedConf: smoothed ? s.conf : nil, live: x.live)
        f.ring = qRing; f.estimated = qEstimated; f.lock = qLock
        f.jpeg = jpeg(x.image)
        recorder.append(f)
    }

    /// Debug log camera frame: landscape as captured (matches intrinsics / imageResolution), 960 px wide
    /// (intrinsics scale by 960 / res.width).
    private func jpeg(_ image: CVPixelBuffer) -> Data? {
        let ci = CIImage(cvPixelBuffer: image)
        return ciContext.jpegRepresentation(of: ci.transformed(by: .init(scaleX: 960 / ci.extent.width, y: 960 / ci.extent.width)),
                                            colorSpace: CGColorSpaceCreateDeviceRGB(),
                                            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.8])
    }

    private func process(_ s: Snapshot) {
        // A frame enqueued just before finishCapture / auto-finish: drop it, but release `busy`.
        guard qPhase != .done else { DispatchQueue.main.async { self.busy = false }; return }
        let phase0 = qPhase
        qRing = false; qEstimated = false; qLock = false
        defer { record(s, phase: phase0) }
        // BoxMeasureKit.DepthCamera: intrinsics scaled to depth-map pixels, camera y/z flip.
        let cam = DepthCamera(width: s.w, height: s.h, intrinsics: s.intrinsics,
                              imageResolution: SIMD2(Float(s.res.width), Float(s.res.height)), transform: s.transform)
        func world(_ u: Int, _ v: Int) -> SIMD3<Float>? { cam.point(u, v, s.depth[v * s.w + u]) }
        func level(_ u: Int, _ v: Int) -> UInt8 { s.conf?[v * s.w + u] ?? 2 }  // ARConfidenceLevel raw: 0 low, 1 medium, 2 high

        // Per-pixel surface normal + incidence for head-on-aware fusion (VoxelCloud.headOnFiltered).
        let inc = surfaceNormals(depth: s.depth, camera: cam)
        // Camera position: without it fusion keeps no incidence stats and the box bias correction never fits.
        let camPos = SIMD3(s.transform.columns.3.x, s.transform.columns.3.y, s.transform.columns.3.z)
        // HUD: phone pitch (view direction elevation, negative = looking down) and incidence at the crosshair.
        dbg.pitch = asin(max(-1, min(1, -s.transform.columns.2.y))) * 180 / .pi
        let ci = inc[(s.h / 2) * s.w + s.w / 2].w
        dbg.aimIncidence = ci > 0 ? acos(min(1, ci)) * 180 / .pi : nil
        let high = unproject(depth: s.depth, confidence: s.conf, camera: cam, incidence: inc, minConfidence: 2)
        let medium = unproject(depth: s.depth, confidence: s.conf, camera: cam, incidence: inc, minConfidence: 1, maxConfidence: 1)
        dbg.high = high.points.count; dbg.medium = medium.points.count

        if qPhase == .scan, let seed = lockedSeed {   // ScanFusion applies the y crop
            return scanStep(s, points: high.points + medium.points, incidence: high.incidence + medium.incidence, camera: camPos, seed: seed)
        }
        let useHigh = high.points.count >= Self.minHighPoints
        let points = useHigh ? high.points : high.points + medium.points
        qSurface = nil; qLockProgress = 0  // every aim-phase miss below publishes "no surface"

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

        ring.append((points, useHigh ? high.incidence : high.incidence + medium.incidence, camPos))
        qRing = true
        if ring.count > Self.fuseFrames { ring.removeFirst(ring.count - Self.fuseFrames) }
        if let last = lastSeed, simd_length(SIMD2(seed.x - last.x, seed.z - last.z)) > Self.seedJump || vertical != lastVertical {
            aggregator.reset()  // don't mix top-seed and side-seed estimates in one median
        }
        lastSeed = seed; lastVertical = vertical

        guard let e = estimate(ring.flatMap(\.points), seed: seed, params: vertical ? Self.aimSideParams : Self.aimParams, s) else {
            seedHistory.removeAll()
            return finish(nil, dbg.failure.map(Self.text)
                          ?? (points.count < Self.minHighPoints ? "点云不足，靠近一点" : "未识别到箱体：对准箱顶或侧面"))
        }
        aggregator.add(e)

        // B4 seed lock: crosshair seed stayed within 5 cm and on the same face type (D1) for >= 1 s,
        // with an estimate every frame.
        seedHistory.append((s.time, seed, vertical))
        seedHistory.removeAll { s.time - $0.t > Self.lockHold + 0.5 }
        // UI only: time since the last entry that would block the lock, capped below 1 (an old blocking
        // entry can still be in the window after 1 s of consistency).
        let since = seedHistory.lastIndex { simd_length($0.p - seed) >= Self.lockDrift || $0.vertical != vertical }
            .map { $0 + 1 } ?? 0
        qSurface = vertical ? .side : .top
        qLockProgress = since < seedHistory.count ? min(0.95, (s.time - seedHistory[since].t) / Self.lockHold) : 0
        if let first = seedHistory.first, s.time - first.t >= Self.lockHold,
           seedHistory.allSatisfy({ simd_length($0.p - seed) < Self.lockDrift && $0.vertical == vertical }) {
            qPhase = .scan
            qLockProgress = 1
            lockedSeed = seed
            lockedVertical = vertical
            scanParams = Self.voxelParams
            scanParams.seedOnSide = vertical
            var f = ScanFusion(seed: seed, planeY: e.planeY, params: scanParams)
            for r in ring { f.insertAim(r.points, incidence: r.incidence, camera: r.camera) }
            fusion = f
            qLock = true
            recorder?.lock(time: s.time, seed: seed, planeY: e.planeY, side: vertical)
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
    /// cloud can be ~1M+ points, so never per attempt there). `dbg.failure` keeps the last known reason
    /// until the next success.
    /// `incidence`: fused per-point incidence stats (scan phase) -> box incidence-bias correction.
    private func estimate(_ pts: [SIMD3<Float>], seed: SIMD3<Float>, params: Params, _ s: Snapshot,
                          incidence: [SIMD2<Float>]? = nil) -> BoxEstimate? {
        let t0 = CACurrentMediaTime()
        let e: BoxEstimate?
        if s.debug {
            let (r, d) = BoxMeasurer.estimateDebug(points: pts, seed: seed, params: params, incidence: incidence)
            e = r
            dbg.planeY = (r?.planeY ?? d.planeY).map { $0 - seed.y }
            dbg.failure = r == nil ? d.failure : nil
        } else {
            e = BoxMeasurer.estimate(points: pts, seed: seed, params: params, incidence: incidence)
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

    private func scanStep(_ s: Snapshot, points: [SIMD3<Float>], incidence: [SIMD4<Float>], camera: SIMD3<Float>, seed: SIMD3<Float>) {
        fusion?.insert(points, incidence: incidence, camera: camera)
        dbg.vertical = lockedVertical
        dbg.voxels = fusion?.cloud.count ?? 0; dbg.voxelCap = fusion?.cloud.maxVoxels ?? 0
        let center = lastScanEstimate.map { $0.center + SIMD3(0, $0.height / 2, 0) } ?? seed
        // C1: shoot when a newly covered sector is >= 90° from every photographed one.
        if let sec = updateCoverage(s, center: center), photoSectors.count < Self.maxShots,
           photoSectors.allSatisfy({ d in let a = abs(d - sec); return min(a, Self.sectorCount - a) >= Self.shotSectorGap }) {
            photoSectors.append(sec)
            DispatchQueue.main.async { self.takeShot() }
        }
        let n = covered.filter { $0 }.count
        let remaining = max(0, Self.finishSectors - n)
        // Head-on coverage (last estimate): grazing-only walls / top read ~2 cm toward the camera.
        let headOnOK = (dbg.headOnWalls ?? 0) >= Self.minHeadOn && (dbg.headOnTop ?? 0) >= Self.minHeadOn
        let coverage = n <= 1 ? lockLabel + "，绕箱子走一圈" : remaining > 0 ? "还差 \(remaining) 个方向"
            : (dbg.headOnWalls ?? 1) < Self.minHeadOn ? "放低手机，正对侧面再绕半圈"
            : (dbg.headOnTop ?? 1) < Self.minHeadOn ? "抬高手机，俯拍箱顶" : "覆盖完成，尺寸收敛中…"
        // D7: last known failure (cleared on success), so the text doesn't flicker between estimates.
        var hint: String { dbg.failure.map(Self.text) ?? coverage }

        guard s.time - lastEstimateTime >= Self.estimateInterval, let fusion else { return finish(nil, hint, keepWireframe: true) }
        qEstimated = true
        let tagged = fusion.tagged()
        let est = estimate(tagged.points, seed: seed, params: scanParams, s, incidence: tagged.incidence)
        // Runs on `queue`; ARFrames arriving meanwhile are dropped (`busy`). A big box (~450k surface voxels)
        // costs ~250-400 ms, so space estimates >= 2x their cost to keep most frames for fusion.
        lastEstimateTime = s.time + max(0, 2 * dbg.millis / 1000 - Self.estimateInterval)
        guard let e = est else {
            return finish(nil, hint, keepWireframe: true)
        }
        scanAgg.add(e)
        lastScanEstimate = e
        // Narrow the insert crop to the estimate (keeps the voxel cap from filling with far floor/clutter).
        self.fusion?.update(e)
        let cov = headOnCoverage(tagged, e)
        dbg.headOnWalls = cov.walls; dbg.headOnTop = cov.top
        // B6 auto-finish. Needs head-on coverage of walls and top, unless the box incidence-bias correction covered
        // every face (then any phone height works); 完成 works regardless.
        let corrected = e.shape == .box && scanParams.incidenceBias > 0 && (e.surfaces?.allSatisfy(\.fitted) ?? false)
        if remaining == 0, headOnOK || corrected, scanAgg.samples.count >= Self.finishSamples, scanAgg.spread <= Self.finishSpread {
            qPhase = .done
            return finish(e, "完成", event: .done)
        }
        finish(e, hint)
    }

    /// B5: sector of the camera's azimuth around `center`, counted only at 0.3-2.5 m with the center in view.
    /// Returns the sector if it was newly covered by this frame.
    @discardableResult
    private func updateCoverage(_ s: Snapshot, center c: SIMD3<Float>) -> Int? {
        updateCoverage(s.transform, s.intrinsics, s.res, center: c)
    }
    @discardableResult
    private func updateCoverage(_ transform: simd_float4x4, _ K: simd_float3x3, _ res: CGSize, center c: SIMD3<Float>) -> Int? {
        let cam = transform.columns.3
        let dist = simd_length(SIMD2(cam.x - c.x, cam.z - c.z))
        guard dist >= 0.3, dist <= 2.5 else { return nil }
        let p = simd_inverse(transform) * SIMD4(c, 1)
        guard p.z < 0 else { return nil }
        let u = K[0][0] * p.x / -p.z + K[2][0], v = K[2][1] - K[1][1] * p.y / -p.z
        guard u >= 0, u < Float(res.width), v >= 0, v < Float(res.height) else { return nil }
        let i = Self.sector(transform, center: c)
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
        let med = agg.median()   // shape = majority vote (BoxAggregator)
        let sp = agg.spread, n = agg.samples.count, phase = qPhase, cov = covered
        let surface = qSurface, lockProgress = qLockProgress
        var info = dbg
        info.history = Array(agg.samples.suffix(5))
        DispatchQueue.main.async {
            self.busy = false
            self.debugInfo = info
            self.median = med; self.spread = sp; self.sampleCount = n; self.sectors = cov
            if self.aimSurface != surface { self.aimSurface = surface }
            if self.lockProgress != lockProgress { self.lockProgress = lockProgress }
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

// MARK: - camera-only mode (SPEC §14)

extension ScanSession {
    static let cameraAimHint = "对准物体，周围留出地面"
    /// Silhouettes bound the object only laterally: estimate once views span >= 180°.
    static let cameraMinSectors = 6
    /// Mask width (px); height follows the capture aspect (960 x 720 for 4:3).
    static let maskWidth = 960
    /// A new silhouette is kept only after the camera moved this far (bounds memory: 86 KB per view).
    static let viewSpacing: Float = 0.03

    fileprivate struct CameraSnapshot {
        var image: CVPixelBuffer
        var transform: simd_float4x4; var intrinsics: simd_float3x3; var res: CGSize; var time: TimeInterval
        var floorY: Float?
        var tracking: UInt8; var thermal: UInt8
    }

    /// Support plane height: lowest plane classified .floor, else the lowest horizontal plane >= 0.3 m² (a detected
    /// box top is higher, and usually smaller).
    fileprivate static func floorY(_ anchors: [ARAnchor]) -> Float? {
        let planes = anchors.compactMap { $0 as? ARPlaneAnchor }.filter { $0.alignment == .horizontal }
        let floors = planes.filter { $0.classification == .floor }
        let pick = floors.isEmpty ? planes.filter { $0.planeExtent.width * $0.planeExtent.height >= 0.3 } : floors
        return pick.map { ($0.transform * SIMD4($0.center, 1)).y }.min()
    }

    /// Queue only. Aim: Vision foreground instance under the crosshair -> floor anchor just inside its footprint;
    /// lock after it holds (lockDrift / lockHold). Scan: silhouette of the instance at the projected anchor per frame,
    /// visual hull (BoxMeasureKit.SilhouetteHull) every estimateInterval once >= cameraMinSectors are covered.
    fileprivate func processCamera(_ s: CameraSnapshot) {
        guard qPhase != .done else { DispatchQueue.main.async { self.busy = false }; return }
        let phase0 = qPhase
        qRing = false; qEstimated = false; qLock = false
        defer { recordCamera(s, phase: phase0) }
        if let y = s.floorY { camFloorY = y }
        let w = Self.maskWidth, h = Int((CGFloat(w) * s.res.height / s.res.width).rounded())
        let cam = DepthCamera(width: w, height: h, intrinsics: s.intrinsics,
                              imageResolution: SIMD2(Float(s.res.width), Float(s.res.height)), transform: s.transform)
        let camPos = SIMD3(s.transform.columns.3.x, s.transform.columns.3.y, s.transform.columns.3.z)
        dbg.pitch = asin(max(-1, min(1, -s.transform.columns.2.y))) * 180 / .pi
        guard let floorY = camFloorY else {
            qSurface = nil; qLockProgress = 0
            return finish(nil, "缓慢移动手机，扫一下地面")
        }
        dbg.planeY = floorY - camPos.y

        if qPhase == .aim {
            let t0 = CACurrentMediaTime()
            let mask = objectMask(s.image, at: SIMD2(Float(w) / 2, Float(h) / 2), w: w, h: h)
            dbg.millis = (CACurrentMediaTime() - t0) * 1000
            guard let mask, let anchor = Self.footprintAnchor(mask, cam, floorY: floorY) else {
                seedHistory.removeAll(); qSurface = nil; qLockProgress = 0
                return finish(nil, Self.cameraAimHint)
            }
            seedHistory.append((s.time, anchor, false))
            seedHistory.removeAll { s.time - $0.t > Self.lockHold + 0.5 }
            let since = seedHistory.lastIndex { simd_length($0.p - anchor) >= Self.lockDrift }.map { $0 + 1 } ?? 0
            qSurface = .top
            qLockProgress = since < seedHistory.count ? min(0.95, (s.time - seedHistory[since].t) / Self.lockHold) : 0
            guard let first = seedHistory.first, s.time - first.t >= Self.lockHold,
                  seedHistory.allSatisfy({ simd_length($0.p - anchor) < Self.lockDrift }) else {
                return finish(nil, "对准物体，保持 1 秒…")
            }
            qPhase = .scan; qLockProgress = 1; qLock = true
            lockedSeed = anchor; lockedVertical = false
            views = [Silhouette(mask: mask, width: w, height: h, intrinsics: s.intrinsics,
                                imageResolution: SIMD2(Float(s.res.width), Float(s.res.height)), transform: s.transform)]
            lastViewCamera = camPos
            recorder?.lock(time: s.time, seed: anchor, planeY: floorY, side: false)
            lastEstimateTime = s.time
            updateCoverage(s.transform, s.intrinsics, s.res, center: anchor)
            photoSectors = [Self.sector(s.transform, center: anchor)]
            return finish(nil, "已锁定，绕物体走一圈", event: .locked(anchor))
        }

        guard let anchor = lockedSeed else { return finish(nil, Self.cameraAimHint) }
        // The anchor lies inside the footprint, so it projects onto the object (or onto the object occluding it).
        if lastViewCamera.map({ simd_length(camPos - $0) >= Self.viewSpacing }) ?? true,
           let px = Self.project(anchor, cam), let mask = objectMask(s.image, at: px, w: w, h: h) {
            views.append(Silhouette(mask: mask, width: w, height: h, intrinsics: s.intrinsics,
                                    imageResolution: SIMD2(Float(s.res.width), Float(s.res.height)), transform: s.transform))
            lastViewCamera = camPos
            qRing = true
        }
        dbg.voxels = views.count
        let center = lastScanEstimate.map { $0.center + SIMD3(0, $0.height / 2, 0) } ?? anchor
        if let sec = updateCoverage(s.transform, s.intrinsics, s.res, center: center), photoSectors.count < Self.maxShots,
           photoSectors.allSatisfy({ d in let a = abs(d - sec); return min(a, Self.sectorCount - a) >= Self.shotSectorGap }) {
            photoSectors.append(sec)
            DispatchQueue.main.async { self.takeShot() }
        }
        let n = covered.filter { $0 }.count
        let remaining = max(0, Self.finishSectors - n)
        let hint = n <= 1 ? "已锁定，绕物体走一圈" : remaining > 0 ? "还差 \(remaining) 个方向" : "覆盖完成，尺寸收敛中…"
        guard n >= Self.cameraMinSectors, s.time - lastEstimateTime >= Self.estimateInterval else {
            return finish(nil, hint, keepWireframe: true)
        }
        qEstimated = true
        let t0 = CACurrentMediaTime()
        let r = SilhouetteHull.measure(views, floorY: floorY, center: SIMD2(anchor.x, anchor.z))
        dbg.millis = (CACurrentMediaTime() - t0) * 1000
        // Same spacing rule as the LiDAR path: keep most frames for silhouettes / coverage.
        lastEstimateTime = s.time + max(0, 2 * dbg.millis / 1000 - Self.estimateInterval)
        guard let e = r?.estimate else { return finish(nil, hint, keepWireframe: true) }
        scanAgg.add(e)
        lastScanEstimate = e
        if remaining == 0, scanAgg.samples.count >= Self.finishSamples, scanAgg.spread <= Self.finishSpread {
            qPhase = .done
            return finish(e, "完成", event: .done)
        }
        finish(e, hint)
    }

    /// Vision foreground instance at (or nearest to, within ~1/12 of the mask width) pixel `px` of the w x h
    /// downscaled frame, as a 0/1 mask. nil: no foreground instance there.
    private func objectMask(_ image: CVPixelBuffer, at px: SIMD2<Float>, w: Int, h: Int) -> [UInt8]? {
        let ci = CIImage(cvPixelBuffer: image)
        let k = CGFloat(w) / ci.extent.width
        let handler = VNImageRequestHandler(ciImage: ci.transformed(by: .init(scaleX: k, y: k)))
        let req = VNGenerateForegroundInstanceMaskRequest()
        guard (try? handler.perform([req])) != nil, let o = req.results?.first else { return nil }
        let im = o.instanceMask
        CVPixelBufferLockBaseAddress(im, .readOnly)
        let iw = CVPixelBufferGetWidth(im), ih = CVPixelBufferGetHeight(im), rb = CVPixelBufferGetBytesPerRow(im)
        let base = CVPixelBufferGetBaseAddress(im)!.assumingMemoryBound(to: UInt8.self)
        let cu = Int(px.x / Float(w) * Float(iw)), cv = Int(px.y / Float(h) * Float(ih)), r = max(4, iw / 12)
        var label = 0, best = Int.max
        for dv in -r...r { for du in -r...r {
            let u = cu + du, v = cv + dv
            guard u >= 0, u < iw, v >= 0, v < ih, base[v * rb + u] != 0, du * du + dv * dv < best else { continue }
            best = du * du + dv * dv; label = Int(base[v * rb + u])
        } }
        CVPixelBufferUnlockBaseAddress(im, .readOnly)
        guard label != 0, let m = try? o.generateScaledMaskForImage(forInstances: IndexSet(integer: label), from: handler) else { return nil }
        CVPixelBufferLockBaseAddress(m, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(m, .readOnly) }
        guard CVPixelBufferGetWidth(m) == w, CVPixelBufferGetHeight(m) == h,
              CVPixelBufferGetPixelFormatType(m) == kCVPixelFormatType_OneComponent32Float else { return nil }
        let mb = CVPixelBufferGetBytesPerRow(m) / 4
        let mp = CVPixelBufferGetBaseAddress(m)!.assumingMemoryBound(to: Float32.self)
        var out = [UInt8](repeating: 0, count: w * h)
        for v in 0..<h { for u in 0..<w where mp[v * mb + u] > 0.5 { out[v * w + u] = 1 } }
        return out
    }

    /// Floor point just inside the object's near footprint edge. Mask pixel rays hit the floor at the near bottom edge
    /// (the nearest hits) or behind the object: mean of the 2-10 % nearest hits, pushed 5 cm away from the camera.
    fileprivate static func footprintAnchor(_ mask: [UInt8], _ cam: DepthCamera, floorY: Float) -> SIMD3<Float>? {
        let t = cam.transform, o = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        var hits: [(d: Float, p: SIMD3<Float>)] = []
        for v in stride(from: 0, to: cam.height, by: 4) { for u in stride(from: 0, to: cam.width, by: 4) where mask[v * cam.width + u] != 0 {
            let d4 = t * SIMD4(cam.cameraPoint(u, v, 1), 0)
            guard d4.y < -1e-3 else { continue }
            let p = o + SIMD3(d4.x, d4.y, d4.z) * ((floorY - o.y) / d4.y)
            hits.append((simd_length(SIMD2(p.x - o.x, p.z - o.z)), p))
        } }
        guard hits.count >= 50 else { return nil }
        hits.sort { $0.d < $1.d }
        let sel = hits[(hits.count / 50)...(hits.count / 10)]
        var m = sel.reduce(SIMD3<Float>.zero) { $0 + $1.p } / Float(sel.count)
        let away = simd_normalize(SIMD2(m.x - o.x, m.z - o.z)) * 0.05
        m.x += away.x; m.z += away.y; m.y = floorY
        return m
    }

    /// Pixel of world point `p` in `cam` (DepthCamera conventions); nil behind the camera or outside the image.
    fileprivate static func project(_ p: SIMD3<Float>, _ cam: DepthCamera) -> SIMD2<Float>? {
        let q = simd_inverse(cam.transform) * SIMD4(p, 1)
        guard q.z < -0.05 else { return nil }
        let u = q.x * cam.fx / -q.z + cam.cx, v = -q.y * cam.fy / -q.z + cam.cy
        guard u >= 0, u < Float(cam.width), v >= 0, v < Float(cam.height) else { return nil }
        return SIMD2(u, v)
    }

    /// Debug log, camera mode: pose + JPEG only (no depth; frames.bin records are header-only, width = height = 0).
    private func recordCamera(_ s: CameraSnapshot, phase: Phase) {
        guard let recorder else { return }
        var f = FrameSample(time: s.time, phase: phase == .scan ? 1 : 0, tracking: s.tracking, thermal: s.thermal,
                            transform: s.transform, intrinsics: s.intrinsics, res: SIMD2(Float(s.res.width), Float(s.res.height)),
                            w: 0, h: 0, raw: nil, rawConf: nil, smoothed: nil, smoothedConf: nil, live: .smoothed)
        f.ring = qRing; f.estimated = qEstimated; f.lock = qLock
        f.jpeg = jpeg(s.image)
        recorder.append(f)
    }
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
