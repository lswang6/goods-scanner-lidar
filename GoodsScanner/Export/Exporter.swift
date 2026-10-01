import UIKit
import AVFoundation

struct Summary {
    var orders = 0, pieces = 0, volumeM3 = 0.0, weightKg = 0.0
    init(_ list: [InboundOrder]) {
        orders = list.count
        for o in list { pieces += o.totalPieces; volumeM3 += o.totalVolumeM3; weightKg += o.totalWeightKg }
    }
}

enum Exporter {
    static let csvColumns = ["入库单号", "入库时间", "客户代码", "客户名称", "联系人", "电话", "操作员", "品名", "长cm", "宽cm", "高cm",
                             "件数", "单件体积m³", "总体积m³", "重量kg", "测量方式", "照片文件", "入库备注"]

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// e.g. 入库报表_20261001-20261031.csv
    static func fileName(_ from: Date, _ to: Date, ext: String) -> String {
        "入库报表_\(InboundOrder.dayFormatter.string(from: from))-\(InboundOrder.dayFormatter.string(from: to)).\(ext)"
    }

    static func outputURL(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "Exports", directoryHint: .isDirectory)
        // Clear previous exports (the share sheet for them is already closed) so tmp doesn't grow.
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: name)
    }

    /// `[nil]` for an order without items so it still gets one (empty-item) row in CSV/PDF.
    static func sortedItems(_ o: InboundOrder) -> [CargoItem?] {
        o.items.isEmpty ? [nil] : o.items.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: CSV

    /// `text`: all-digit values (customer code, phone) are emitted as Excel `="001"` so Excel keeps leading zeros
    /// and doesn't turn 13800000001 into 1.38E+10. Other CSV readers will show the literal `="..."`.
    /// Other cells starting with = + - @ get a leading `'` (formula injection). Digits-only values can't trigger it.
    static func csvField(_ s: String, text: Bool = false) -> String {
        var v = s
        if text && !v.isEmpty && v.allSatisfy(\.isASCII) && v.allSatisfy(\.isNumber) {
            v = "=\"" + v + "\""
        } else if let f = v.unicodeScalars.first, "=+-@".unicodeScalars.contains(f) {
            v = "'" + v
        }
        // unicodeScalars, not Characters: "\r\n" is a single Character that equals neither "\r" nor "\n".
        return v.unicodeScalars.contains(where: { "\",\n\r".unicodeScalars.contains($0) })
            ? "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : v
    }

    /// UTF-8 with BOM so Excel opens Chinese correctly (A9). One row per cargo item.
    static func csv(_ orders: [InboundOrder]) -> Data {
        var lines = [csvColumns.map { csvField($0) }.joined(separator: ",")]
        for o in orders {
            let c = o.customer
            for i in sortedItems(o) {
                // Volumes at 4 decimals in CSV so small items aren't 0.000.
                let row: [String] = [o.orderNo, timeFormatter.string(from: o.receivedAt), c?.code ?? "", c?.name ?? "", c?.contact ?? "", c?.phone ?? "",
                           o.operatorName, i?.name ?? "", i?.lengthCm.cm ?? "", i?.widthCm.cm ?? "", i?.heightCm.cm ?? "", i.map { String($0.quantity) } ?? "",
                           i?.unitVolumeM3.fixed(4) ?? "", i?.totalVolumeM3.fixed(4) ?? "", i?.weightKg?.kg ?? "", i?.methodLabel ?? "",
                           i?.photoFiles.joined(separator: ";") ?? "", o.note]
                lines.append(row.enumerated().map { csvField($1, text: $0 == 2 || $0 == 5) }.joined(separator: ","))
            }
        }
        return Data("\u{FEFF}".utf8) + Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    static func writeCSV(_ orders: [InboundOrder], from: Date, to: Date) throws -> URL {
        let url = try outputURL(fileName(from, to, ext: "csv"))
        try csv(orders).write(to: url)
        return url
    }

    // MARK: PDF

    static func writePDF(_ orders: [InboundOrder], from: Date, to: Date, customerName: String?) throws -> URL {
        let url = try outputURL(fileName(from, to, ext: "pdf"))
        let page = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)  // A4 @72dpi
        let margin: CGFloat = 32, rowH: CGFloat = 44, thumb: CGFloat = 40
        let cols: [(String, CGFloat)] = [("单号", 84), ("客户", 72), ("品名", 76), ("尺寸cm", 80), ("件数", 36), ("体积m³", 50), ("重量kg", 44), ("方式", 36)]
        let small = [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 8)]
        let bold = [NSAttributedString.Key.font: UIFont.boldSystemFont(ofSize: 8)]
        let s = Summary(orders)
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd"

        try UIGraphicsPDFRenderer(bounds: page).writePDF(to: url) { ctx in
            var y: CGFloat = 0
            func header() {
                var x = margin
                for (t, w) in cols { (t as NSString).draw(in: CGRect(x: x, y: y, width: w, height: 12), withAttributes: bold); x += w }
                ("照片" as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: bold)
                y += 14
                UIColor.gray.setFill(); UIRectFill(CGRect(x: margin, y: y - 2, width: page.width - 2 * margin, height: 0.5))
            }
            ctx.beginPage(); y = margin
            ("入库报表" as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 20)])
            y += 30
            let info = "日期：\(df.string(from: from)) 至 \(df.string(from: to))    客户：\(customerName ?? "全部")\n"
                + "入库单 \(s.orders) 张 · 件数 \(s.pieces) · 总体积 \(s.volumeM3.m3) m³ · 总重量 \(s.weightKg.kg) kg"
            (info as NSString).draw(in: CGRect(x: margin, y: y, width: page.width - 2 * margin, height: 32),
                                    withAttributes: [.font: UIFont.systemFont(ofSize: 11)])
            y += 40
            header()
            for o in orders {
                for i in sortedItems(o) {
                    if y + rowH > page.height - margin { ctx.beginPage(); y = margin; header() }
                    let dims: String = i.map { "\($0.lengthCm.cm)×\($0.widthCm.cm)×\($0.heightCm.cm)" } ?? ""
                    let vals: [String] = [o.orderNo, o.customer?.name ?? "", i?.name ?? "", dims, i.map { String($0.quantity) } ?? "",
                                i?.totalVolumeM3.m3 ?? "", i?.weightKg?.kg ?? "", i?.methodLabel ?? ""]
                    var x = margin
                    for (v, (_, w)) in zip(vals, cols) {
                        (v as NSString).draw(in: CGRect(x: x, y: y + 2, width: w - 4, height: rowH - 4), withAttributes: small); x += w
                    }
                    if let f = i?.photoFiles.first, let img = PhotoStore.thumbnail(f, side: 300) {
                        let r = AVMakeRect(aspectRatio: img.size, insideRect: CGRect(x: x, y: y + 2, width: thumb, height: thumb))
                        img.draw(in: r)
                    }
                    y += rowH
                }
            }
        }
        return url
    }

    // MARK: ZIP

    /// Zips all item photos (one folder per order) using NSFileCoordinator(.forUploading) (A9).
    static func writePhotosZip(_ orders: [InboundOrder], from: Date, to: Date) throws -> URL {
        let fm = FileManager.default
        let base = (fileName(from, to, ext: "zip") as NSString).deletingPathExtension + "_照片"
        let staging = fm.temporaryDirectory.appending(path: "ZipStaging", directoryHint: .isDirectory).appending(path: base, directoryHint: .isDirectory)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var any = false
        for o in orders {
            let files = o.items.flatMap(\.photoFiles).filter { fm.fileExists(atPath: PhotoStore.url($0).path) }
            guard !files.isEmpty else { continue }
            let dir = staging.appending(path: o.orderNo, directoryHint: .isDirectory)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in files { try fm.copyItem(at: PhotoStore.url(f), to: dir.appending(path: f)) }
            any = true
        }
        guard any else { throw NSError(domain: "Exporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "所选范围内没有照片"]) }
        let dest = try outputURL(base + ".zip")
        var coordError: NSError?, copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: staging, options: .forUploading, error: &coordError) { zipURL in
            // The zip only exists for the duration of this block (SPEC §7).
            do { try fm.copyItem(at: zipURL, to: dest) } catch { copyError = error }
        }
        if let e = coordError ?? copyError { throw e }
        return dest
    }
}
