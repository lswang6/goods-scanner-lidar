import simd

// FROZEN INTERFACE (docs/SPEC.md §4). Algorithm internals live in Estimate.swift.
// World space: meters, y up (gravity-aligned, as ARKit world tracking).

public struct BoxEstimate: Equatable, Sendable {
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

public struct Params: Sendable {
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
    public init() {}
}

public enum BoxMeasurer {
    /// `yaw` follows a right-handed rotation about +y: the length axis is (cos yaw, 0, -sin yaw),
    /// normalized to (-pi/2, pi/2].
    public static func estimate(points: [SIMD3<Float>], seed: SIMD3<Float>, params: Params = .init()) -> BoxEstimate? {
        estimateImpl(points: points, seed: seed, p: params)
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
