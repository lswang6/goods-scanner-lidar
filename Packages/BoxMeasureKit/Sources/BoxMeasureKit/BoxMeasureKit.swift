import simd

// FROZEN INTERFACE (docs/SPEC.md §4). Algorithm internals live in Estimate.swift.
// World space: meters, y up (gravity-aligned, as ARKit world tracking).

public struct BoxEstimate: Equatable, Sendable, Codable {
    public var length: Float   // meters, length >= width
    public var width: Float
    public var height: Float
    public var center: SIMD3<Float>  // footprint center on the support plane
    public var yaw: Float            // radians, rotation of `length` axis around +y
    public var planeY: Float
    public var pointCount: Int

    public init(length: Float, width: Float, height: Float, center: SIMD3<Float>, yaw: Float, planeY: Float, pointCount: Int) {
        self.length = length; self.width = width; self.height = height
        self.center = center; self.yaw = yaw; self.planeY = planeY; self.pointCount = pointCount
    }
}

public struct Params: Sendable, Codable {
    public var searchRadius: Float = 1.0
    public var maxSearchRadius: Float = 2.0
    public var binSize: Float = 0.01
    public var minPlanePoints: Int = 30
    public var minPlaneFraction: Float = 0.05
    public var planeGap: Float = 0.03        // support plane must be at least this far below seed
    public var abovePlane: Float = 0.015
    public var topSlab: Float = 0.02
    public var minTopSlabPoints: Int = 50
    public var gridCell: Float = 0.01
    public var minCellPoints: Int = 2
    public var heightPercentile: Float = 0.98
    public var maxBoxSize: Float = 2.5
    /// Fewer component points than this -> no estimate.
    public var minBoxPoints: Int = 20
    /// Seed cell empty -> look for the nearest occupied cell within this many cells (Chebyshev).
    public var seedCellSearch: Int = 3
    /// Top-slab cell needs this many slab-occupied 8-neighbours (isolated bleed cells drop out).
    public var slabNeighbours: Int = 4
    /// Footprint outlier rejection: trim this many extreme points per side, then drop points farther
    /// than `trimMargin` (m, ~ depth noise) outside the trimmed rectangle and refit.
    public var trimPoints: Int = 10
    public var trimMargin: Float = 0.005
    /// ...and at least this fraction of the points per side.
    public var trimFraction: Float = 0
    /// maxExtent footprint: a 1 cm cell counts only if its points occupy >= this many distinct `binSize`
    /// y-bins (capped at half the object's height in bins). 0 = off.
    public var columnBins: Int = 0
    /// > 0: after trimming, move each footprint edge to the densest 2.5 mm slab within this distance inside
    /// it (the wall's core, not its noise tail). 0 = off.
    public var wallBand: Float = 0
    /// SPEC §10 C4 "按最大外形": footprint = minAreaRect over the component's points at ALL heights
    /// (cells with >= slabNeighbours occupied neighbours, then the same trim/refit), height = highest
    /// supported y (see `heightSupport`). false = v2 top-slab footprint + `heightPercentile` height.
    public var maxExtent: Bool = true
    /// maxExtent only: admit points up to seed.y + this (parts taller than the aimed-at top). The
    /// top-slab mode keeps its fixed seed.y + 2.5 * topSlab cap.
    public var maxAboveSeed: Float = 0.5
    /// maxExtent height: a 1 cm y-bin counts as object top when its 3x3-cell XZ neighbourhood holds at
    /// least this many points in that bin plus the bin below.
    public var heightSupport: Int = 10
    /// SPEC §11: the seed lies on a vertical side face (not the top). Object points are admitted up to
    /// seed.y + maxBoxSize, and the footprint/height always use the max-extent path.
    public var seedOnSide: Bool = false
    public init() {}

    /// Walk-around (fused VoxelCloud) clouds: every side has walls, real surfaces are a ~5 mm-sigma shell.
    /// Footprint = vertically supported cells, 0.75 % trim per side (more cuts into a sparsely seen wall: synthetic 1 m box -2.3 cm at 1 %), no outward margin (device logs 2026-10-02:
    /// top-edge bleed shelves and glossy-floor noise inflated L/W by 7-11 cm). Single-view clouds keep the
    /// defaults: there the top is mostly unsupported by visible walls.
    public static let fused: Params = { var p = Params(); p.columnBins = 6; p.trimFraction = 0.0075; p.trimMargin = 0; p.wallBand = 0.02; return p }()
}

public enum BoxMeasurer {
    /// `yaw` follows a right-handed rotation about +y: the length axis is (cos yaw, 0, -sin yaw),
    /// normalized to (-pi/2, pi/2].
    public static func estimate(points: [SIMD3<Float>], seed: SIMD3<Float>, params: Params = .init()) -> BoxEstimate? {
        estimateImpl(points: points, seed: seed, p: params, collect: false).0
    }
}

public struct BoxAggregator: Sendable {
    public private(set) var samples: [BoxEstimate] = []
    public let capacity: Int
    public init(capacity: Int = 10) { self.capacity = capacity }
    public mutating func add(_ e: BoxEstimate) {
        samples.append(e)
        if samples.count > max(capacity, 1) { samples.removeFirst(samples.count - max(capacity, 1)) }
    }
    public mutating func reset() { samples.removeAll() }
    /// Per-dimension median of the retained samples.
    /// center / yaw / planeY / pointCount come from the latest sample.
    public func median() -> BoxEstimate? {
        guard var m = samples.last else { return nil }
        m.length = medianOf(samples.map(\.length))
        m.width = medianOf(samples.map(\.width))
        m.height = medianOf(samples.map(\.height))
        return m
    }
    /// Max over L/W/H of (max - min) / median among retained samples; 0 when < 2 samples.
    public var spread: Float {
        guard samples.count >= 2 else { return 0 }
        return [\BoxEstimate.length, \.width, \.height].map { kp -> Float in
            let v = samples.map { $0[keyPath: kp] }
            let med = medianOf(v)
            return med > 0 ? (v.max()! - v.min()!) / med : .infinity
        }.max()!
    }
}

/// Minimum-area enclosing rectangle (convex hull + rotating calipers).
/// `size.x >= size.y`; `angle` is the direction of the `size.x` side, radians.
/// `angle` is normalized to (-pi/2, pi/2]. Degenerate input: 0 points -> zero; 1 point -> that point,
/// zero size; collinear -> size.y == 0.
public func minAreaRect(_ pts: [SIMD2<Float>]) -> (center: SIMD2<Float>, size: SIMD2<Float>, angle: Float) {
    minAreaRectImpl(pts)
}
