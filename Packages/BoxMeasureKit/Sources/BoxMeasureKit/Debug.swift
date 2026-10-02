import Foundation
import simd

// FROZEN INTERFACE (docs/SPEC.md §11). Additive debug / side-seed / scan-log API.


/// Why `estimate` returned nil (first failing stage).
public enum EstimateFailure: String, Codable, Sendable {
    case noPlane        // no supporting horizontal surface found below the seed
    case noSeedCell     // seed's XZ column has no object points nearby
    case tooFewPoints   // connected component smaller than minBoxPoints
    case outOfRange     // a dimension <= 0 or > maxBoxSize
}

public struct EstimateDebug: Sendable {
    public var planeY: Float?
    public var failure: EstimateFailure?
    /// Indices into the input `points` that belong to the segmented object (connected component).
    public var objectIndices: [Int] = []
    /// Indices into the input `points` within +-binSize of planeY inside the search radius.
    public var planeIndices: [Int] = []
    public var millis: Double = 0
    public init() {}
}

extension BoxMeasurer {
    /// Same result as `estimate`, plus diagnostics. Slower (collects indices); use for debug UI / replay.
    public static func estimateDebug(points: [SIMD3<Float>], seed: SIMD3<Float>, params: Params = .init(),
                                     incidence: [SIMD2<Float>]? = nil) -> (BoxEstimate?, EstimateDebug) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        var (e, d) = estimateImpl(points: points, seed: seed, p: params, collect: true, incidence: incidence)
        d.millis = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        return (e, d)
    }
}

/// True when the points around the aim point lie on a vertical surface (box side), false for a
/// horizontal one (box top). Input: unprojected points from a small window around the crosshair.
/// Plane fit: normal = smallest-eigenvalue eigenvector of the covariance (closed-form symmetric 3x3).
/// Vertical <=> |normal.y| < cos 45 deg (surface tilted more than 45 deg from horizontal).
/// false on < 5 points, non-finite input, or no well-defined plane (collinear / isotropic blob).
public func isVerticalSurface(_ pts: [SIMD3<Float>]) -> Bool {
    guard let n = surfaceNormal(pts) else { return false }
    return abs(n.y) < (0.5 as Double).squareRoot()
}

/// Unit plane normal of `pts`, nil when degenerate. Double + centered covariance: 3 mm noise at 1 m
/// range would drown in Float E[xx] - E[x]^2 cancellation.
func surfaceNormal(_ pts: [SIMD3<Float>]) -> SIMD3<Double>? {
    guard pts.count >= 5, pts.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return nil }
    var mean = SIMD3<Double>.zero
    for q in pts { mean += SIMD3<Double>(q) }
    mean /= Double(pts.count)
    var c = simd_double3x3()
    for q in pts { let v = SIMD3<Double>(q) - mean; c += simd_double3x3(columns: (v * v.x, v * v.y, v * v.z)) }
    let tr = c[0][0] + c[1][1] + c[2][2]
    guard tr > 0 else { return nil }
    c = c * (1 / tr)   // normalized: eigenvalues sum to 1
    // Closed-form eigenvalues of a symmetric 3x3 (trigonometric method).
    let p1 = c[0][1] * c[0][1] + c[0][2] * c[0][2] + c[1][2] * c[1][2]
    let q = 1.0 / 3
    let p2 = (c[0][0] - q) * (c[0][0] - q) + (c[1][1] - q) * (c[1][1] - q) + (c[2][2] - q) * (c[2][2] - q) + 2 * p1
    let pp = (p2 / 6).squareRoot()
    guard pp > 1e-12 else { return nil }   // isotropic
    let b = (c - simd_double3x3(diagonal: SIMD3(repeating: q))) * (1 / pp)
    let phi = acos(min(1, max(-1, b.determinant / 2))) / 3
    let l1 = q + 2 * pp * cos(phi), l3 = q + 2 * pp * cos(phi + 2 * .pi / 3), l2 = 1 - l1 - l3
    // Plane needs two real spread directions and a clearly smaller third: reject lines and blobs.
    guard l2 > 0.02, l2 - l3 > 0.01 else { return nil }
    let m = c - simd_double3x3(diagonal: SIMD3(repeating: l3))
    let r0 = SIMD3(m[0][0], m[1][0], m[2][0]), r1 = SIMD3(m[0][1], m[1][1], m[2][1]), r2 = SIMD3(m[0][2], m[1][2], m[2][2])
    let n = [simd_cross(r0, r1), simd_cross(r0, r2), simd_cross(r1, r2)].max { simd_length_squared($0) < simd_length_squared($1) }!
    let len = simd_length(n)
    return len > 0 ? n / len : nil
}

/// One saved scan, for offline replay/tuning. On disk: `<dir>/scan.json` + `<dir>/points.ply`
/// (binary little-endian PLY, float x y z — opens in MeshLab / CloudCompare).
public struct ScanLog: Codable, Sendable {
    public var version = 1
    public var date: Date
    public var seed: SIMD3<Float>
    public var seedVertical: Bool
    public var params: Params
    public var estimate: BoxEstimate?
    public var failure: EstimateFailure?
    /// Delivered numbers after calibration offset, cm [L, W, H].
    public var deliveredCm: [Double]?
    public var coveredSectors: Int
    public var voxelCount: Int
    public var note: String = ""
    public init(date: Date, seed: SIMD3<Float>, seedVertical: Bool, params: Params, estimate: BoxEstimate?, failure: EstimateFailure?, deliveredCm: [Double]?, coveredSectors: Int, voxelCount: Int) {
        self.date = date; self.seed = seed; self.seedVertical = seedVertical; self.params = params
        self.estimate = estimate; self.failure = failure; self.deliveredCm = deliveredCm
        self.coveredSectors = coveredSectors; self.voxelCount = voxelCount
    }
}

public enum ScanLogIO {
    public static func write(points: [SIMD3<Float>], log: ScanLog, to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(log).write(to: dir.appendingPathComponent("scan.json"), options: .atomic)
        var ply = Data("ply\nformat binary_little_endian 1.0\nelement vertex \(points.count)\nproperty float x\nproperty float y\nproperty float z\nend_header\n".utf8)
        var raw = [UInt32]()
        raw.reserveCapacity(points.count * 3)
        for q in points { raw += [q.x.bitPattern.littleEndian, q.y.bitPattern.littleEndian, q.z.bitPattern.littleEndian] }
        raw.withUnsafeBytes { ply.append(contentsOf: $0) }
        try ply.write(to: dir.appendingPathComponent("points.ply"), options: .atomic)
    }

    public static func read(from dir: URL) throws -> (points: [SIMD3<Float>], log: ScanLog) {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        // Logs from older builds lack newer Params keys: fill them with today's defaults.
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("scan.json"))) as? [String: Any] ?? [:]
        if let saved = obj["params"] as? [String: Any],
           var params = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Params())) as? [String: Any] {
            params.merge(saved) { $1 }
            obj["params"] = params
        }
        let log = try dec.decode(ScanLog.self, from: JSONSerialization.data(withJSONObject: obj))
        let data = try Data(contentsOf: dir.appendingPathComponent("points.ply"))
        func bad(_ why: String) -> Error { CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "points.ply: \(why)"]) }
        guard let end = data.range(of: Data("end_header\n".utf8)) else { throw bad("no end_header") }
        let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self)
            .split(whereSeparator: \.isNewline).map { $0.split(separator: " ").map(String.init) }
            .filter { !$0.isEmpty && $0[0] != "comment" && $0[0] != "obj_info" }
        guard lines.first == ["ply"], lines.contains(["format", "binary_little_endian", "1.0"]) else { throw bad("not binary_little_endian PLY") }
        guard let v = lines.first(where: { $0.count == 3 && $0[0] == "element" && $0[1] == "vertex" }), let n = Int(v[2]), n >= 0
        else { throw bad("no vertex count") }
        let props = lines.filter { $0[0] == "property" }
        guard props == [["property", "float", "x"], ["property", "float", "y"], ["property", "float", "z"]] else { throw bad("expected float x y z only") }
        let body = data[end.upperBound...]
        guard body.count >= n * 12 else { throw bad("truncated: \(body.count) bytes for \(n) vertices") }
        let points = body.withUnsafeBytes { buf in
            (0..<n).map { i in
                let f = { (k: Int) in Float(bitPattern: UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: i * 12 + k * 4, as: UInt32.self))) }
                return SIMD3(f(0), f(1), f(2))
            }
        }
        return (points, log)
    }
}
