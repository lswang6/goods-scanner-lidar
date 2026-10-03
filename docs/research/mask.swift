// usage: swift mask.swift seeds.txt  -> writes <image>.mask.pgm (255 = instance under seed), prints failures
import Vision
import CoreImage
import Foundation
let lines = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).split(separator: "\n")
var fails = 0
for l in lines {
    let f = l.split(separator: " "); let path = String(f[0]); let su = Double(f[1])!, sv = Double(f[2])!
    let h = VNImageRequestHandler(url: URL(fileURLWithPath: path))
    let r = VNGenerateForegroundInstanceMaskRequest()
    do { try h.perform([r]) } catch { print("ERR", path, error); fails += 1; continue }
    guard let o = r.results?.first else { print("NOFG", path); fails += 1; continue }
    let im = o.instanceMask; CVPixelBufferLockBaseAddress(im, .readOnly)
    let iw = CVPixelBufferGetWidth(im), ih = CVPixelBufferGetHeight(im), rb = CVPixelBufferGetBytesPerRow(im)
    let base = CVPixelBufferGetBaseAddress(im)!.assumingMemoryBound(to: UInt8.self)
    // instance under the seed; if background, nearest labelled pixel within 40 px (instance-mask pixels)
    let cu = Int(su / 960 * Double(iw)), cv = Int(sv / 720 * Double(ih))
    var label = 0, best = Int.max
    for dv in -40...40 { for du in -40...40 {
        let u = cu + du, v = cv + dv
        guard u >= 0, u < iw, v >= 0, v < ih else { continue }
        let lb = Int(base[v * rb + u]); let d2 = du * du + dv * dv
        if lb != 0 && d2 < best { best = d2; label = lb }
    } }
    CVPixelBufferUnlockBaseAddress(im, .readOnly)
    guard label != 0 else { print("MISS", path); fails += 1; continue }
    let m = try! o.generateScaledMaskForImage(forInstances: IndexSet(integer: label), from: h)
    CVPixelBufferLockBaseAddress(m, .readOnly)
    let w = CVPixelBufferGetWidth(m), hh = CVPixelBufferGetHeight(m), mb = CVPixelBufferGetBytesPerRow(m)
    let mp = CVPixelBufferGetBaseAddress(m)!.assumingMemoryBound(to: Float32.self)
    var out = Data("P5\n\(w) \(hh)\n255\n".utf8)
    for y in 0..<hh { for x in 0..<w { out.append(mp[y * mb / 4 + x] > 0.5 ? 255 : 0) } }
    CVPixelBufferUnlockBaseAddress(m, .readOnly)
    try! out.write(to: URL(fileURLWithPath: path + ".mask.pgm"))
}
print("done", lines.count, "fails", fails)
