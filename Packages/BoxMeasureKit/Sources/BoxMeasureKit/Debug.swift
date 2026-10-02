import Foundation
import simd

// FROZEN INTERFACE (docs/SPEC.md §11). Additive debug / side-seed / scan-log API. Stubs until P11a fills them.


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
    public static func estimateDebug(points: [SIMD3<Float>], seed: SIMD3<Float>, params: Params = .init()) -> (BoxEstimate?, EstimateDebug) {
        (nil, EstimateDebug())
    }
}

/// True when the points around the aim point lie on a vertical surface (box side), false for a
/// horizontal one (box top). Input: unprojected points from a small window around the crosshair.
public func isVerticalSurface(_ pts: [SIMD3<Float>]) -> Bool { false }

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
    public static func write(points: [SIMD3<Float>], log: ScanLog, to dir: URL) throws {}
    public static func read(from dir: URL) throws -> (points: [SIMD3<Float>], log: ScanLog) {
        throw CocoaError(.featureUnsupported)
    }
}
