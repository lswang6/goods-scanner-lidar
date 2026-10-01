import UIKit
import simd
import BoxMeasureKit

/// One camera photo kept during the walk-around (SPEC §10 C1/C2): portrait CGImage (capturedImage
/// `.oriented(.right)`) plus the pose/intrinsics of the SAME ARFrame, so the final box can be drawn on it.
struct CameraShot {
    let image: CGImage
    let transform: simd_float4x4
    let intrinsics: simd_float3x3
    let imageResolution: CGSize   // landscape capturedImage size the intrinsics refer to
}

/// Projects the measured box into a photo and draws wireframe + L/W/H labels (SPEC §10 C2).
enum PhotoAnnotator {
    /// World point -> portrait image pixel, nil if behind (or within 5 cm of) the camera.
    ///
    /// ARKit camera space: x right / y up / -z forward *in landscape-right* (home button right), i.e.
    /// +x runs along the long axis toward the home indicator. Landscape pixel: u = fx*x/(-z)+cx,
    /// v = fy*(-y)/(-z)+cy. The app is portrait (home indicator down): camera +x = screen DOWN,
    /// camera +y = screen RIGHT. `.oriented(.right)` rotates the W x H landscape buffer 90° clockwise to
    /// H x W portrait, so portrait (x', y') = (H - 1 - v, u): a point at camera +x lands lower in the
    /// photo, a point at camera +y lands further right, the principal point lands near the centre.
    /// Result is scaled to `imageSize` (portrait) in case it differs from `imageResolution` transposed.
    static func project(_ p: SIMD3<Float>, transform: simd_float4x4, intrinsics K: simd_float3x3,
                        imageResolution res: CGSize, imageSize: CGSize) -> CGPoint? {
        let c = simd_inverse(transform) * SIMD4(p, 1)
        guard -c.z > 0.05 else { return nil }
        let u = K[0][0] * c.x / -c.z + K[2][0]
        let v = K[1][1] * -c.y / -c.z + K[2][1]
        let xp = Float(res.height) - 1 - v, yp = u
        return CGPoint(x: CGFloat(xp) * imageSize.width / res.height, y: CGFloat(yp) * imageSize.height / res.width)
    }

    /// Corner i: bit0 = +length side, bit1 = top, bit2 = +width side.
    static func corners(_ b: BoxEstimate) -> [SIMD3<Float>] {
        let u = SIMD3<Float>(cos(b.yaw), 0, -sin(b.yaw)), v = SIMD3<Float>(sin(b.yaw), 0, cos(b.yaw))
        return (0..<8).map { i in
            b.center + u * (i & 1 == 0 ? -b.length / 2 : b.length / 2) + v * (i & 4 == 0 ? -b.width / 2 : b.width / 2)
                + SIMD3(0, i & 2 == 0 ? 0 : b.height, 0)
        }
    }

    /// `labels` are the delivered (post-calibration) cm values; geometry is the measured `box`.
    static func annotate(image: CGImage, transform: simd_float4x4, intrinsics: simd_float3x3, imageResolution: CGSize,
                         box: BoxEstimate, labels: (l: Double, w: Double, h: Double)) -> UIImage {
        let size = CGSize(width: image.width, height: image.height)
        let world = corners(box)
        let pts = world.map { project($0, transform: transform, intrinsics: intrinsics, imageResolution: imageResolution, imageSize: size) }
        let camPos = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        // 12 edges as corner pairs differing in one bit: 1 = length, 2 = height, 4 = width.
        var edges: [(a: Int, b: Int, bit: Int)] = []
        for i in 0..<8 { for bit in [1, 2, 4] where i & bit == 0 { edges.append((i, i | bit, bit)) } }
        let visible = edges.filter { pts[$0.a] != nil && pts[$0.b] != nil }
        /// Representative edge: length/width edges on the top face, any vertical edge; nearest the camera.
        func pick(_ bit: Int) -> (Int, Int)? {
            visible.filter { bit == 2 || ($0.a & 2 != 0) }.filter { $0.bit == bit }
                .min { simd_distance((world[$0.a] + world[$0.b]) / 2, camPos) < simd_distance((world[$1.a] + world[$1.b]) / 2, camPos) }
                .map { ($0.a, $0.b) }
        }

        let green = UIColor(.scan).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let w = size.width
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
            let g = ctx.cgContext
            // Top face fill (corners 2, 3, 7, 6 in order around the face).
            let top = [2, 3, 7, 6].compactMap { pts[$0] }
            if top.count == 4 {
                g.addLines(between: top); g.closePath()
                g.setFillColor(green.withAlphaComponent(0.18).cgColor); g.fillPath()
            }
            g.setStrokeColor(green.cgColor)
            g.setLineWidth(max(2, w * 4 / 1440))
            g.setLineCap(.round)
            for e in visible { g.move(to: pts[e.a]!); g.addLine(to: pts[e.b]!) }
            g.strokePath()

            let font = UIFont.systemFont(ofSize: w * 0.035, weight: .bold)
            for (bit, text) in [(1, String(format: "长 %.1f cm", labels.l)), (4, String(format: "宽 %.1f cm", labels.w)),
                                (2, String(format: "高 %.1f cm", labels.h))] {
                guard let (a, b) = pick(bit) else { continue }
                let m = CGPoint(x: (pts[a]!.x + pts[b]!.x) / 2, y: (pts[a]!.y + pts[b]!.y) / 2)
                capsule(text, font: font, center: m, in: size)
            }
            let vol = CargoItem.volumeM3(labels.l, labels.w, labels.h)
            let caption = String(format: "L×W×H %.1f×%.1f×%.1f cm · ", labels.l, labels.w, labels.h) + vol.m3 + " m³ · 按最大外形"
            let small = UIFont.systemFont(ofSize: w * 0.025, weight: .semibold)
            let cs = (caption as NSString).size(withAttributes: [.font: small])
            capsule(caption, font: small, center: CGPoint(x: w * 0.03 + cs.width / 2 + small.pointSize * 0.5,
                                                          y: size.height - w * 0.03 - cs.height / 2 - small.pointSize * 0.25), in: size)
        }
    }

    /// White bold text on a dark rounded capsule centred at `center`, clamped inside the image.
    private static func capsule(_ text: String, font: UIFont, center: CGPoint, in size: CGSize) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
        let ts = (text as NSString).size(withAttributes: attrs)
        let pad = CGSize(width: font.pointSize * 0.5, height: font.pointSize * 0.25)
        var r = CGRect(x: center.x - ts.width / 2 - pad.width, y: center.y - ts.height / 2 - pad.height,
                       width: ts.width + 2 * pad.width, height: ts.height + 2 * pad.height)
        r.origin.x = min(max(0, r.origin.x), size.width - r.width)
        r.origin.y = min(max(0, r.origin.y), size.height - r.height)
        UIColor.black.withAlphaComponent(0.6).setFill()
        UIBezierPath(roundedRect: r, cornerRadius: r.height / 2).fill()
        (text as NSString).draw(at: CGPoint(x: r.minX + pad.width, y: r.minY + pad.height), withAttributes: attrs)
    }
}
