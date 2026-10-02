import Foundation
import simd

// Depth unprojection shared by the app and bmk-replay, the scan-phase voxel crop policy, and the debug-mode
// raw-frame log (`<scanDir>/frames.bin` + `frames.json`) with its offline re-fusion.

// MARK: - Unprojection

/// Pinhole model of an ARKit depth map. `intrinsics` / `imageResolution` are ARCamera's (capturedImage,
/// landscape, same orientation as the depth map); they are scaled to depth-map pixels here.
public struct DepthCamera: Sendable {
    public let width: Int, height: Int
    public let fx: Float, fy: Float, cx: Float, cy: Float
    public let transform: simd_float4x4

    public init(width: Int, height: Int, intrinsics K: simd_float3x3, imageResolution res: SIMD2<Float>, transform: simd_float4x4) {
        // Origin is the center of the upper-left pixel, hence the +/-0.5.
        let sx = Float(width) / res.x, sy = Float(height) / res.y
        self.width = width; self.height = height
        fx = K[0][0] * sx; fy = K[1][1] * sy
        cx = (K[2][0] + 0.5) * sx - 0.5; cy = (K[2][1] + 0.5) * sy - 0.5
        self.transform = transform
    }

    /// Camera space: x right, y up, looking down -z; image v grows downward -> flip y and z.
    @inline(__always) public func cameraPoint(_ u: Int, _ v: Int, _ d: Float) -> SIMD3<Float> {
        SIMD3((Float(u) - cx) * d / fx, -(Float(v) - cy) * d / fy, -d)
    }

    /// World point of pixel (u, v) at depth `d`; nil for non-finite or non-positive depth.
    @inline(__always) public func point(_ u: Int, _ v: Int, _ d: Float) -> SIMD3<Float>? {
        guard d.isFinite, d > 0 else { return nil }
        let p = transform * SIMD4(cameraPoint(u, v, d), 1)
        return SIMD3(p.x, p.y, p.z)
    }
}

/// World points of every `stride`-th pixel whose confidence (ARConfidenceLevel raw: 0 low, 1 medium,
/// 2 high; nil map = all high) lies in minConfidence...maxConfidence. Row-major order.
public func unproject(depth: [Float], confidence: [UInt8]?, width: Int, height: Int, intrinsics: simd_float3x3,
                      imageResolution: SIMD2<Float>, transform: simd_float4x4, minConfidence: UInt8,
                      maxConfidence: UInt8 = .max, stride: Int = 1) -> [SIMD3<Float>] {
    let cam = DepthCamera(width: width, height: height, intrinsics: intrinsics, imageResolution: imageResolution, transform: transform)
    return unproject(depth: depth, confidence: confidence, camera: cam, minConfidence: minConfidence, maxConfidence: maxConfidence, stride: stride)
}

public func unproject(depth: [Float], confidence: [UInt8]?, camera cam: DepthCamera, minConfidence: UInt8,
                      maxConfidence: UInt8 = .max, stride: Int = 1) -> [SIMD3<Float>] {
    precondition(depth.count == cam.width * cam.height && (confidence == nil || confidence!.count == depth.count))
    var out: [SIMD3<Float>] = []
    out.reserveCapacity(depth.count / (stride * stride))
    for v in Swift.stride(from: 0, to: cam.height, by: stride) { for u in Swift.stride(from: 0, to: cam.width, by: stride) {
        let i = v * cam.width + u
        let c = confidence?[i] ?? 2
        guard c >= minConfidence, c <= maxConfidence, let p = cam.point(u, v, depth[i]) else { continue }
        out.append(p)
    } }
    return out
}

/// Depth multiplied by `k` (scale-error experiment).
public func scaledDepth(_ depth: [Float], by k: Float) -> [Float] { k == 1 ? depth : depth.map { $0 * k } }

/// Sets depth to NaN (=> skipped by `unproject`) where the local surface normal is more than `maxDegrees`
/// from the view ray. Normal = cross product of the central differences of the 3D neighbours; pixels on the
/// border or with an invalid neighbour are dropped too, so depth discontinuities (silhouettes) go as well.
public func dropGrazing(depth: inout [Float], camera cam: DepthCamera, maxDegrees: Float) {
    let src = depth, w = cam.width, h = cam.height
    let minCos = cos(maxDegrees * .pi / 180)
    @inline(__always) func p(_ u: Int, _ v: Int) -> SIMD3<Float>? {
        let d = src[v * w + u]
        return d.isFinite && d > 0 ? cam.cameraPoint(u, v, d) : nil
    }
    for v in 0..<h { for u in 0..<w {
        guard let c = p(u, v) else { continue }
        guard u > 0, v > 0, u < w - 1, v < h - 1, let l = p(u - 1, v), let r = p(u + 1, v), let t = p(u, v - 1), let b = p(u, v + 1)
        else { depth[v * w + u] = .nan; continue }
        let n = simd_cross(r - l, b - t)
        let len = simd_length(n) * simd_length(c)
        if !(len > 0) || abs(simd_dot(n, c)) < minCos * len { depth[v * w + u] = .nan }
    } }
}

// MARK: - Scan-phase fusion policy (ScanSession and refuse)

/// The app's walk-around voxel cloud plus its insert crop (SPEC §9 B3). At lock: radius 1.5 m around the
/// seed, upper crop seed.y + maxAboveSeed (top seed) / + maxBoxSize (side seed), floor cap at
/// lockPlaneY + abovePlane. After each fused estimate `update` narrows it to the footprint + 0.5 m and
/// planeY - 0.05 ... planeY + maxBoxSize.
public struct ScanFusion: Sendable {
    public static let initialRadius: Float = 1.5
    public static let cropMargin: Float = 0.5
    public static let minCropRadius: Float = 0.6
    public static let minHits = 2
    /// Aim phase: a frame with fewer high-confidence points uses high + medium.
    public static let minHighPoints = 2000

    public var cloud: VoxelCloud
    public private(set) var top: Float
    public private(set) var bottom: Float = -.infinity
    public let maxBoxSize: Float

    public init(seed: SIMD3<Float>, planeY: Float, params: Params) {
        top = seed.y + (params.seedOnSide ? params.maxBoxSize : params.maxAboveSeed)
        maxBoxSize = params.maxBoxSize
        cloud = VoxelCloud(center: seed, radius: Self.initialRadius, floorY: planeY + params.abovePlane)
    }

    /// Aim-phase frames fused at lock: upper crop only.
    public mutating func insertAim(_ pts: [SIMD3<Float>]) { cloud.insert(pts.filter { $0.y <= top }) }
    public mutating func insert(_ pts: [SIMD3<Float>]) { cloud.insert(pts.filter { $0.y <= top && $0.y >= bottom }) }

    /// ponytail: an early under-measured big box can crop its own far side until the estimate grows; cropMargin is the knob.
    public mutating func update(_ e: BoxEstimate) {
        cloud.center = e.center
        cloud.radius = max(Self.minCropRadius, (e.length * e.length + e.width * e.width).squareRoot() / 2 + Self.cropMargin)
        bottom = e.planeY - 0.05
        top = min(top, e.planeY + maxBoxSize)
    }

    public func points() -> [SIMD3<Float>] { cloud.centroids(minHits: Self.minHits) }
}

// MARK: - Raw frame log

public enum DepthSource: String, Codable, Sendable { case raw, smoothed }

/// One processed ARFrame. Depth in meters as Float16, confidence as ARConfidenceLevel raw values.
/// nil buffer = not delivered by ARKit for this frame.
public struct RawFrame: Sendable {
    public var timestamp: Double
    public var phase: UInt8          // 0 aim, 1 scan (phase when the frame was processed; lock frame = aim)
    public var tracking: UInt8       // 0 notAvailable, 1 limited, 2 normal
    public var thermal: UInt8        // ProcessInfo.ThermalState raw
    public var ring = false          // aim frame kept in the app's fuse ring (fused at lock if among the last fuseFrames)
    public var estimated = false     // app ran a fused estimate right after inserting this frame
    public var lock = false          // seed locked on this frame
    public var transform: simd_float4x4
    public var intrinsics: simd_float3x3
    public var imageResolution: SIMD2<Float>
    public var raw: [Float16]?, rawConf: [UInt8]?
    public var smoothed: [Float16]?, smoothedConf: [UInt8]?

    public init(timestamp: Double, phase: UInt8, tracking: UInt8, thermal: UInt8, transform: simd_float4x4,
                intrinsics: simd_float3x3, imageResolution: SIMD2<Float>,
                raw: [Float16]?, rawConf: [UInt8]?, smoothed: [Float16]?, smoothedConf: [UInt8]?) {
        self.timestamp = timestamp; self.phase = phase; self.tracking = tracking; self.thermal = thermal
        self.transform = transform; self.intrinsics = intrinsics; self.imageResolution = imageResolution
        self.raw = raw; self.rawConf = rawConf; self.smoothed = smoothed; self.smoothedConf = smoothedConf
    }

    public func depth(_ s: DepthSource) -> [Float]? { (s == .raw ? raw : smoothed)?.map(Float.init) }
    public func confidence(_ s: DepthSource) -> [UInt8]? { s == .raw ? rawConf : smoothedConf }
}

/// `frames.json`. Record layout (little-endian, fixed `recordBytes`, records back to back in frames.bin):
/// see `RawFramesIndex.layoutDescription`.
public struct RawFramesIndex: Codable, Sendable {
    public var version = 1
    public var width: Int, height: Int
    public var recordBytes: Int
    public var layout = RawFramesIndex.layoutDescription
    public var count = 0
    /// Depth the live fusion used (smoothed when the device delivers it).
    public var liveSource: DepthSource
    public var fuseFrames: Int
    public var lockTime: Double?
    public var lockSeed: SIMD3<Float>?
    /// Aim estimate planeY at lock (VoxelCloud floorY = this + abovePlane).
    public var lockPlaneY: Float?
    public var seedOnSide: Bool?

    public static let headerBytes = 120
    public static let layoutDescription = "f64 timestamp | u8 phase(0 aim,1 scan) | u8 tracking(0 notAvailable,1 limited,2 normal) | "
        + "u8 thermal | u8 flags(1 raw,2 smoothed,4 rawConf,8 smoothedConf,16 ring,32 estimated,64 lock) | "
        + "f32x16 transform (column-major) | f32x9 intrinsics (column-major) | f32x2 imageResolution | "
        + "f16[w*h] raw depth m | f16[w*h] smoothed depth m | u8[w*h] raw confidence | u8[w*h] smoothed confidence "
        + "(absent buffers are zero-filled, flag bit clear)"

    public init(width: Int, height: Int, liveSource: DepthSource, fuseFrames: Int) {
        self.width = width; self.height = height; self.liveSource = liveSource; self.fuseFrames = fuseFrames
        recordBytes = Self.headerBytes + width * height * 6
    }
}

/// Synchronous appender (the app calls it from its own serial queue).
public final class RawFramesWriter {
    public let dir: URL
    public var index: RawFramesIndex
    private let handle: FileHandle

    public init(dir: URL, index: RawFramesIndex) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("frames.bin")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: url)
        self.dir = dir; self.index = index
    }

    public func append(_ f: RawFrame) throws {
        let n = index.width * index.height
        for c in [f.raw?.count, f.smoothed?.count, f.rawConf?.count, f.smoothedConf?.count] where c != nil && c != n {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSLocalizedDescriptionKey: "buffer size \(c!) != \(n)"])
        }
        var d = Data(capacity: index.recordBytes)
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        put(f.timestamp.bitPattern.littleEndian)
        var flags: UInt8 = 0
        for (b, on) in [(f.raw != nil), f.smoothed != nil, f.rawConf != nil, f.smoothedConf != nil, f.ring, f.estimated, f.lock].enumerated() where on {
            flags |= 1 << b
        }
        d.append(contentsOf: [f.phase, f.tracking, f.thermal, flags])
        let m = f.transform, k = f.intrinsics
        for x in [m[0], m[1], m[2], m[3]].flatMap({ [$0.x, $0.y, $0.z, $0.w] }) + [k[0], k[1], k[2]].flatMap({ [$0.x, $0.y, $0.z] })
            + [f.imageResolution.x, f.imageResolution.y] { put(x.bitPattern.littleEndian) }
        for a in [f.raw, f.smoothed] {
            if let a { a.withUnsafeBytes { d.append(contentsOf: $0) } } else { d.append(Data(count: n * 2)) }  // host is little-endian
        }
        for a in [f.rawConf, f.smoothedConf] { d.append(contentsOf: a ?? [UInt8](repeating: 0, count: n)) }
        assert(d.count == index.recordBytes)
        try handle.write(contentsOf: d)
        index.count += 1
    }

    private var closed = false
    deinit { if !closed { try? handle.close() } }   // abandoned (cancelled) recording

    /// Writes frames.json and closes frames.bin.
    public func close() throws {
        closed = true
        try handle.close()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(index).write(to: dir.appendingPathComponent("frames.json"), options: .atomic)
    }
}

/// Memory-mapped reader of `<scanDir>/frames.bin` + `frames.json`.
public struct RawFrames {
    public let index: RawFramesIndex
    private let data: Data

    public init(dir: URL) throws {
        index = try JSONDecoder().decode(RawFramesIndex.self, from: Data(contentsOf: dir.appendingPathComponent("frames.json")))
        data = try Data(contentsOf: dir.appendingPathComponent("frames.bin"), options: .alwaysMapped)
        guard index.version == 1, index.recordBytes == RawFramesIndex.headerBytes + index.width * index.height * 6,
              data.count >= index.count * index.recordBytes else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "frames.bin: \(data.count) bytes, index says \(index.count) x \(index.recordBytes)"])
        }
    }

    public var count: Int { index.count }

    /// Header fields only (no depth decode).
    public func meta(_ i: Int) -> (timestamp: Double, phase: UInt8, flags: UInt8) {
        data.withUnsafeBytes { buf in
            let o = i * index.recordBytes
            return (Double(bitPattern: UInt64(littleEndian: buf.loadUnaligned(fromByteOffset: o, as: UInt64.self))), buf[o + 8], buf[o + 11])
        }
    }

    public subscript(i: Int) -> RawFrame {
        let n = index.width * index.height
        return data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> RawFrame in
            let o = i * index.recordBytes
            func f32(_ k: Int) -> Float { Float(bitPattern: UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: o + 12 + 4 * k, as: UInt32.self))) }
            let flags = buf[o + 11]
            let col = { (c: Int) in SIMD4(f32(4 * c), f32(4 * c + 1), f32(4 * c + 2), f32(4 * c + 3)) }
            let kc = { (c: Int) in SIMD3(f32(16 + 3 * c), f32(17 + 3 * c), f32(18 + 3 * c)) }
            func half(_ at: Int) -> [Float16] {
                (0..<n).map { Float16(bitPattern: UInt16(littleEndian: buf.loadUnaligned(fromByteOffset: at + 2 * $0, as: UInt16.self))) }
            }
            let base = o + RawFramesIndex.headerBytes
            var f = RawFrame(
                timestamp: Double(bitPattern: UInt64(littleEndian: buf.loadUnaligned(fromByteOffset: o, as: UInt64.self))),
                phase: buf[o + 8], tracking: buf[o + 9], thermal: buf[o + 10],
                transform: simd_float4x4(col(0), col(1), col(2), col(3)), intrinsics: simd_float3x3(kc(0), kc(1), kc(2)),
                imageResolution: SIMD2(f32(25), f32(26)),
                raw: flags & 1 != 0 ? half(base) : nil,
                rawConf: flags & 4 != 0 ? Array(buf[(base + 4 * n)..<(base + 5 * n)]) : nil,
                smoothed: flags & 2 != 0 ? half(base + 2 * n) : nil,
                smoothedConf: flags & 8 != 0 ? Array(buf[(base + 5 * n)..<(base + 6 * n)]) : nil)
            f.ring = flags & 16 != 0; f.estimated = flags & 32 != 0; f.lock = flags & 64 != 0
            return f
        }
    }
}

// MARK: - Offline re-fusion

public struct RefuseOptions: Sendable {
    public var source: DepthSource?          // nil = index.liveSource
    public var minConfidence: UInt8 = 1      // scan frames (the app fuses high + medium)
    public var maxIncidence: Float?          // degrees, `dropGrazing`
    public var depthScale: Float = 1
    /// false: what the app fused (the last `fuseFrames` ring frames up to the lock, then scan frames).
    /// true: every recorded frame, scan-phase rule.
    public var allPhases = false
    public init() {}
}

extension RawFrames {
    /// Re-runs the app's scan-phase fusion (ScanFusion; fused estimates + crop updates on the frames where the
    /// app ran them) with the given depth options. `params.seedOnSide` is the caller's (index.seedOnSide).
    /// Returns nil when the log has no lock.
    public func refuse(params: Params, options o: RefuseOptions = .init()) -> (fusion: ScanFusion, frames: Int, estimates: Int)? {
        guard let seed = index.lockSeed, let planeY = index.lockPlaneY, let lockTime = index.lockTime else { return nil }
        let src = o.source ?? index.liveSource
        func points(_ f: RawFrame, _ lo: UInt8, _ hi: UInt8 = .max) -> [SIMD3<Float>] {
            guard var d = f.depth(src) else { return [] }
            d = scaledDepth(d, by: o.depthScale)
            let cam = DepthCamera(width: index.width, height: index.height, intrinsics: f.intrinsics, imageResolution: f.imageResolution, transform: f.transform)
            if let deg = o.maxIncidence { dropGrazing(depth: &d, camera: cam, maxDegrees: deg) }
            return unproject(depth: d, confidence: f.confidence(src), camera: cam, minConfidence: lo, maxConfidence: hi)
        }
        func scanPoints(_ f: RawFrame) -> [SIMD3<Float>] {
            o.minConfidence >= 2 ? points(f, 2) : points(f, 2) + points(f, o.minConfidence, 1)
        }
        var fusion = ScanFusion(seed: seed, planeY: planeY, params: params)
        var frames = 0, estimates = 0
        if !o.allPhases {
            let ring = (0..<count).filter { let m = meta($0); return m.flags & 16 != 0 && m.timestamp <= lockTime }.suffix(index.fuseFrames)
            for i in ring {
                let f = self[i], high = points(f, 2)
                fusion.insertAim(high.count >= ScanFusion.minHighPoints || o.minConfidence >= 2 ? high : high + points(f, o.minConfidence, 1))
                frames += 1
            }
        }
        for i in 0..<count where o.allPhases || meta(i).phase == 1 {
            let f = self[i]
            fusion.insert(scanPoints(f)); frames += 1
            if f.estimated {
                estimates += 1
                if let e = BoxMeasurer.estimate(points: fusion.points(), seed: seed, params: params) { fusion.update(e) }
            }
        }
        return (fusion, frames, estimates)
    }
}
