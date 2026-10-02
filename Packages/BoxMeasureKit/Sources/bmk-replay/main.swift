// bmk-replay <scanDir> [--set key=value ...] [--out colored.ply]   (SPEC §11 D6)
// Re-runs BoxMeasurer on a saved scan log with Params overrides; optional ASCII PLY colored by segmentation.
// bmk-replay --refuse <scanDir> [--source smoothed|raw] [--min-conf 1|2] [--max-incidence DEG]
//            [--depth-scale K] [--phase scan|all] [--set key=value ...]
// Re-fuses frames.bin (debug-mode raw frames) with the app's ScanFusion policy, then estimates with Params.fused.
import Foundation
import BoxMeasureKit

func die(_ msg: String) -> Never { FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(1) }

/// Params with `--set` overrides applied by key (JSON round trip).
func applying(_ sets: [(String, String)], to p: Params) throws -> Params {
    guard !sets.isEmpty else { return p }
    var dict = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
    for (k, v) in sets {
        guard dict[k] != nil else { die("unknown param \(k); available: \(dict.keys.sorted().joined(separator: ", "))") }
        // Int fields reject "30.0" in synthesized decoding, so keep integers integral.
        dict[k] = v == "true" ? true : v == "false" ? false : !v.contains(".") && Int(v) != nil ? Int(v)! as Any : Double(v) ?? die("bad value \(k)=\(v)")
    }
    return try JSONDecoder().decode(Params.self, from: JSONSerialization.data(withJSONObject: dict))
}

func need<T>(_ v: T?, _ msg: String) -> T { if let v { return v }; die(msg) }

func parseSet(_ v: String) -> (String, String) {
    let kv = v.split(separator: "=", maxSplits: 1).map(String.init)
    guard kv.count == 2 else { die("--set expects key=value, got \(v)") }
    return (kv[0], kv[1])
}

func show(_ e: BoxEstimate?) -> String {
    guard let e else { return "nil" }
    return String(format: "\(e.shape.rawValue)  L %.1f  W %.1f  H %.1f cm  planeY %.3f  yaw %.1f°  n=%d  center %.3f %.3f",
                  e.length * 100, e.width * 100, e.height * 100, e.planeY, e.yaw * 180 / .pi, e.pointCount, e.center.x, e.center.z)
}

var args = Array(CommandLine.arguments.dropFirst())

if args.first == "--refuse" {
    args.removeFirst()
    guard let dir = args.first, !dir.hasPrefix("-") else { die("--refuse needs <scanDir>") }
    args.removeFirst()
    var o = RefuseOptions(), sets: [(String, String)] = []
    while !args.isEmpty {
        let flag = args.removeFirst()
        guard !args.isEmpty else { die("\(flag) needs a value") }
        let v = args.removeFirst()
        switch flag {
        case "--source": o.source = need(DepthSource(rawValue: v), "--source smoothed|raw")
        case "--min-conf": o.minConfidence = need(UInt8(v).flatMap { (0...2).contains($0) ? $0 : nil }, "--min-conf 0|1|2")
        case "--max-incidence": o.maxIncidence = need(Float(v), "bad --max-incidence \(v)")
        case "--depth-scale": o.depthScale = need(Float(v), "bad --depth-scale \(v)")
        case "--phase": o.allPhases = need(["all": true, "scan": false][v], "--phase scan|all")
        case "--set", "--param": sets.append(parseSet(v))
        default: die("unknown flag \(flag)")
        }
    }
    let url = URL(fileURLWithPath: dir)
    let frames = try RawFrames(dir: url)
    let ix = frames.index
    var p = Params.fused
    p.seedOnSide = ix.seedOnSide ?? false
    p = try applying(sets, to: p)
    guard let seed = ix.lockSeed, let r = frames.refuse(params: p, options: o) else { die("no lock recorded in frames.json") }
    let pts = r.fusion.points()
    let (e, d) = BoxMeasurer.estimateDebug(points: pts, seed: seed, params: p)
    print("frames   \(dir)  \(ix.count) recorded (\(ix.width)x\(ix.height), live \(ix.liveSource.rawValue))  lock t=\(ix.lockTime ?? 0)  seed \(seed)  side \(p.seedOnSide)")
    if let saved = try? ScanLogIO.read(from: url) { print("saved    \(show(saved.log.estimate))  voxels \(saved.log.voxelCount)") }
    print("options  source \((o.source ?? ix.liveSource).rawValue)  min-conf \(o.minConfidence)  max-incidence \(o.maxIncidence.map { "\($0)°" } ?? "-")  depth-scale \(o.depthScale)  phase \(o.allPhases ? "all" : "scan")"
          + (sets.isEmpty ? "" : "  set \(sets.map { "\($0.0)=\($0.1)" }.joined(separator: " "))"))
    print("refuse   \(show(e))  failure \(d.failure?.rawValue ?? "-")")
    print("         voxels \(r.fusion.cloud.count)  points(minHits \(ScanFusion.minHits)) \(pts.count)  frames fused \(r.frames)  in-loop estimates \(r.estimates)")
    exit(0)
}

guard let dirArg = args.first, !dirArg.hasPrefix("-") else {
    die("usage: bmk-replay <scanDir> [--set key=value ...] [--out colored.ply]\n       bmk-replay --refuse <scanDir> [--source smoothed|raw] [--min-conf 1|2] [--max-incidence DEG] [--depth-scale K] [--phase scan|all] [--set key=value ...]")
}
args.removeFirst()
var sets: [(String, String)] = []
var out: String?
while !args.isEmpty {
    let flag = args.removeFirst()
    guard !args.isEmpty else { die("\(flag) needs a value") }
    let v = args.removeFirst()
    switch flag {
    case "--set", "--param": sets.append(parseSet(v))
    case "--out": out = v
    default: die("unknown flag \(flag)")
    }
}

let (points, log) = try ScanLogIO.read(from: URL(fileURLWithPath: dirArg))
let params = try applying(sets, to: log.params)

let (e, d) = BoxMeasurer.estimateDebug(points: points, seed: log.seed, params: params)
print("scan     \(dirArg)  \(points.count) pts  seed \(log.seed)  vertical \(log.seedVertical)  date \(log.date)")
print("saved    \(show(log.estimate))" + (log.failure.map { "  failure \($0.rawValue)" } ?? ""))
if let c = log.deliveredCm { print("delivered \(c.map { String(format: "%.1f", $0) }.joined(separator: " x ")) cm") }
print("replay   \(show(e))  failure \(d.failure?.rawValue ?? "-")")
print(String(format: "         planeY %@  object %d pts  plane %d pts  %.1f ms",
             d.planeY.map { String(format: "%.3f", $0) } ?? "-", d.objectIndices.count, d.planeIndices.count, d.millis))
if !sets.isEmpty { print("overrides \(sets.map { "\($0.0)=\($0.1)" }.joined(separator: " "))") }

if let out {
    var color = [String](repeating: "128 128 128", count: points.count)
    for i in d.planeIndices { color[i] = "0 0 255" }
    for i in d.objectIndices { color[i] = "0 255 0" }
    var s = "ply\nformat ascii 1.0\nelement vertex \(points.count)\nproperty float x\nproperty float y\nproperty float z\n"
        + "property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n"
    for (q, c) in zip(points, color) { s += "\(q.x) \(q.y) \(q.z) \(c)\n" }
    try s.write(toFile: out, atomically: true, encoding: .utf8)
    print("wrote    \(out)")
}
