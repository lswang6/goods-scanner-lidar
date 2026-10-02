// bmk-replay <scanDir> [--set key=value ...] [--out colored.ply]   (SPEC §11 D6)
// Re-runs BoxMeasurer on a saved scan log with Params overrides; optional ASCII PLY colored by segmentation.
import Foundation
import BoxMeasureKit

func die(_ msg: String) -> Never { FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(1) }

var args = Array(CommandLine.arguments.dropFirst())
guard let dirArg = args.first, !dirArg.hasPrefix("-") else {
    die("usage: bmk-replay <scanDir> [--set key=value ...] [--out colored.ply]")
}
args.removeFirst()
var sets: [(String, String)] = []
var out: String?
while !args.isEmpty {
    let flag = args.removeFirst()
    guard !args.isEmpty else { die("\(flag) needs a value") }
    let v = args.removeFirst()
    switch flag {
    case "--set", "--param":
        let kv = v.split(separator: "=", maxSplits: 1).map(String.init)
        guard kv.count == 2 else { die("--set expects key=value, got \(v)") }
        sets.append((kv[0], kv[1]))
    case "--out": out = v
    default: die("unknown flag \(flag)")
    }
}

let (points, log) = try ScanLogIO.read(from: URL(fileURLWithPath: dirArg))
var params = log.params
if !sets.isEmpty {
    var dict = try JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as! [String: Any]
    for (k, v) in sets {
        guard dict[k] != nil else { die("unknown param \(k); available: \(dict.keys.sorted().joined(separator: ", "))") }
        // Int fields reject "30.0" in synthesized decoding, so keep integers integral.
        dict[k] = v == "true" ? true : v == "false" ? false : !v.contains(".") && Int(v) != nil ? Int(v)! as Any : Double(v) ?? die("bad value \(k)=\(v)")
    }
    params = try JSONDecoder().decode(Params.self, from: JSONSerialization.data(withJSONObject: dict))
}

func show(_ e: BoxEstimate?) -> String {
    guard let e else { return "nil" }
    return String(format: "L %.1f  W %.1f  H %.1f cm  planeY %.3f  yaw %.1f°  n=%d",
                  e.length * 100, e.width * 100, e.height * 100, e.planeY, e.yaw * 180 / .pi, e.pointCount)
}

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
