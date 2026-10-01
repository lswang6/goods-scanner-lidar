import ARKit
import SceneKit
import BoxMeasureKit

/// SPEC §9 B2: ARMeshAnchor -> translucent SCNGeometry; vertices inside the current box estimate
/// (+3 cm) green, the rest light blue.
/// Threading: ARSCNViewDelegate callbacks arrive on SceneKit's render thread. There we only memcpy the
/// anchor's MTLBuffers (they belong to ARKit and may be recycled) and hop to `queue`, which owns
/// `cache`, `lastBuild`, `focus` and `box` and builds geometry. `node.geometry` is assigned on main.
final class MeshOverlay: NSObject, ARSCNViewDelegate {
    private struct Mesh { var local: [Float]; var world: [SIMD3<Float>]; var faces: Data; var faceCount: Int; var bytesPerIndex: Int; weak var node: SCNNode? }

    private let queue = DispatchQueue(label: "GoodsScanner.mesh", qos: .utility)
    // queue only
    private var cache: [UUID: Mesh] = [:]
    private var lastBuild: [UUID: TimeInterval] = [:]
    private var focus: SIMD3<Float>?
    private var box: BoxEstimate?
    private var lastRecolor: TimeInterval = 0

    static let range: Float = 2.5
    static let rebuildInterval: TimeInterval = 0.3
    static let recolorInterval: TimeInterval = 1.0

    private let material: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor.white
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        m.transparency = 0.99   // puts it in SceneKit's transparent pass so vertex alpha is honoured
        return m
    }()

    /// Anchors farther than `range` (horizontal) from this point are not drawn: seed after lock, camera before.
    func setFocus(_ p: SIMD3<Float>) { queue.async { self.focus = p } }

    /// Recolor all cached meshes when the box moved/changed by > 2 cm (throttled to 1 s); nil clears.
    func setBox(_ e: BoxEstimate?) {
        queue.async {
            let changed: Bool
            switch (self.box, e) {
            case (nil, nil): changed = false
            case let (a?, b?):
                changed = max(simd_length(a.center - b.center), abs(a.length - b.length), abs(a.width - b.width),
                              abs(a.height - b.height)) > 0.02 || abs(a.yaw - b.yaw) > 0.05
            default: changed = true
            }
            let now = CACurrentMediaTime()
            guard changed, e == nil || now - self.lastRecolor >= Self.recolorInterval else { return }
            self.box = e; self.lastRecolor = now
            for (id, m) in self.cache { self.build(id, m) }
        }
    }

    // MARK: ARSCNViewDelegate (render thread)

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) { ingest(node, anchor) }
    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) { ingest(node, anchor) }
    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        let id = anchor.identifier
        queue.async { self.cache[id] = nil; self.lastBuild[id] = nil }
    }

    private func ingest(_ node: SCNNode, _ anchor: ARAnchor) {
        guard let a = anchor as? ARMeshAnchor else { return }
        let g = a.geometry, v = g.vertices, f = g.faces
        guard v.format == .float3, f.indexCountPerPrimitive == 3, v.count > 0, f.count > 0 else { return }
        // Copy now: the buffers are ARKit's and are only guaranteed valid during this callback.
        var local = [Float](repeating: 0, count: v.count * 3)
        let src = v.buffer.contents().advanced(by: v.offset)
        local.withUnsafeMutableBytes { dst in
            for i in 0..<v.count { dst.baseAddress!.advanced(by: i * 12).copyMemory(from: src.advanced(by: i * v.stride), byteCount: 12) }
        }
        let faces = Data(bytes: f.buffer.contents(), count: f.count * 3 * f.bytesPerIndex)
        let id = a.identifier, t = a.transform, faceCount = f.count, bpi = f.bytesPerIndex
        queue.async {
            let now = CACurrentMediaTime()
            guard let focus = self.focus,
                  simd_length(SIMD2(t.columns.3.x - focus.x, t.columns.3.z - focus.z)) <= Self.range,
                  now - (self.lastBuild[id] ?? 0) >= Self.rebuildInterval else { return }
            self.lastBuild[id] = now
            let world = (0..<local.count / 3).map { i -> SIMD3<Float> in
                let p = t * SIMD4(local[3 * i], local[3 * i + 1], local[3 * i + 2], 1)
                return SIMD3(p.x, p.y, p.z)
            }
            let m = Mesh(local: local, world: world, faces: faces, faceCount: faceCount, bytesPerIndex: bpi, node: node)
            self.cache[id] = m
            self.build(id, m)
        }
    }

    // MARK: queue

    private func build(_ id: UUID, _ m: Mesh) {
        guard let node = m.node else { cache[id] = nil; return }
        let n = m.world.count
        var colors = [SIMD4<Float>](repeating: SIMD4(0.55, 0.8, 1, 0.2), count: n)
        if let e = box {
            let u = SIMD3<Float>(cos(e.yaw), 0, -sin(e.yaw)), w = SIMD3<Float>(sin(e.yaw), 0, cos(e.yaw)), pad: Float = 0.03
            for i in 0..<n {
                let d = m.world[i] - e.center
                if abs(simd_dot(d, u)) <= e.length / 2 + pad, abs(simd_dot(d, w)) <= e.width / 2 + pad,
                   d.y >= -pad, d.y <= e.height + pad { colors[i] = SIMD4(0.1, 0.9, 0.2, 0.55) }
            }
        }
        let vsrc = m.local.withUnsafeBytes { SCNGeometrySource(data: Data($0), semantic: .vertex, vectorCount: n, usesFloatComponents: true,
                                                               componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12) }
        let csrc = colors.withUnsafeBytes { SCNGeometrySource(data: Data($0), semantic: .color, vectorCount: n, usesFloatComponents: true,
                                                              componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16) }
        let elem = SCNGeometryElement(data: m.faces, primitiveType: .triangles, primitiveCount: m.faceCount, bytesPerIndex: m.bytesPerIndex)
        let geo = SCNGeometry(sources: [vsrc, csrc], elements: [elem])
        geo.materials = [material]
        DispatchQueue.main.async { node.geometry = geo }
    }
}
