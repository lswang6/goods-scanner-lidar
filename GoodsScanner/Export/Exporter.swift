import UIKit
import AVFoundation

struct Summary {
    var orders = 0, pieces = 0, volumeM3 = 0.0, weightKg = 0.0
    init(_ list: [InboundOrder]) {
        orders = list.count
        for o in list { pieces += o.totalPieces; volumeM3 += o.totalVolumeM3; weightKg += o.totalWeightKg }
    }
}

/// What an export covers; drives the file name and the PDF title/subtitle.
enum ExportScope {
    /// Every order in the date range (optionally one customer's).
    case range(from: Date, to: Date, customer: String?)
    /// A hand-picked subset of the orders in the range.
    case picked(count: Int, from: Date, to: Date)
    case order(InboundOrder)

    /// Localized file name without extension (not yet sanitized).
    var stem: String {
        func days(_ f: Date, _ t: Date) -> String {
            "\(InboundOrder.dayFormatter.string(from: f))-\(InboundOrder.dayFormatter.string(from: t))"
        }
        return switch self {
        case let .range(f, t, customer?): String(localized: "Inbound report \(days(f, t)) \(customer)")
        case let .range(f, t, nil): String(localized: "Inbound report \(days(f, t))")
        case let .picked(n, f, t): String(localized: "Inbound report \(days(f, t)) \(n) orders")
        case let .order(o): String(localized: "Inbound order \(o.orderNo)")
        }
    }

    var pdfTitle: String {
        if case let .order(o) = self { return String(localized: "Inbound order \(o.orderNo)") }
        return String(localized: "Inbound report")
    }

    /// Dates in the user's locale.
    var pdfSubtitle: String {
        let d = { (x: Date) in x.formatted(date: .abbreviated, time: .omitted) }
        return switch self {
        case let .range(f, t, customer):
            String(localized: "Date: \(d(f)) – \(d(t))    Customer: \(customer ?? String(localized: "All customers"))")
        case let .picked(n, f, t):
            String(localized: "Date: \(d(f)) – \(d(t))    \(n) selected orders")
        case let .order(o):
            String(localized: "Customer: \(o.customer?.name ?? "—")    Received: \(o.receivedAt.formatted(date: .abbreviated, time: .shortened))")
        }
    }
}

enum Exporter {
    /// Computed so the header follows the current language.
    static var csvColumns: [String] {
        [String(localized: "Order No."), String(localized: "Received"), String(localized: "Customer code"), String(localized: "Customer name"),
         String(localized: "Contact"), String(localized: "Phone"), String(localized: "Operator"), String(localized: "Item"),
         String(localized: "Length (cm)"), String(localized: "Width (cm)"), String(localized: "Height (cm)"), String(localized: "Quantity"),
         String(localized: "Unit volume (m³)"), String(localized: "Total volume (m³)"), String(localized: "Weight (kg)"),
         String(localized: "Measuring method"), String(localized: "Photo files"), String(localized: "Order note"),
         String(localized: "Shape")]  // Shape appended last (SPEC §13 E4)
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// e.g. "Inbound report 20261001-20261031.csv"; unsafe characters (customer names are user input) become "_".
    static func fileName(_ scope: ExportScope, ext: String) -> String {
        safeFileName(scope.stem) + "." + ext
    }

    static func safeFileName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        let cleaned = String(s.unicodeScalars.map { bad.contains($0) ? "_" : Character($0) })
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        return String(cleaned.prefix(100))  // stay well under the 255-byte name limit
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

    /// UTF-8 with BOM so Excel opens non-ASCII text correctly (A9). One row per cargo item.
    /// Header/labels are localized; numbers and times stay machine-readable ("." decimals, no grouping).
    static func csv(_ orders: [InboundOrder]) -> Data {
        var lines = [csvColumns.map { csvField($0) }.joined(separator: ",")]
        for o in orders {
            let c = o.customer
            for i in sortedItems(o) {
                // Volumes at 4 decimals in CSV so small items aren't 0.000.
                let row: [String] = [o.orderNo, timeFormatter.string(from: o.receivedAt), c?.code ?? "", c?.name ?? "", c?.contact ?? "", c?.phone ?? "",
                           o.operatorName, i?.name ?? "", i?.lengthCm.csvCm ?? "", i?.widthCm.csvCm ?? "", i?.heightCm.csvCm ?? "", i.map { String($0.quantity) } ?? "",
                           i?.unitVolumeM3.fixed(4) ?? "", i?.totalVolumeM3.fixed(4) ?? "", i?.weightKg?.csvKg ?? "", i?.methodLabel ?? "",
                           i?.photoFiles.joined(separator: ";") ?? "", o.note, i?.shapeLabel ?? ""]
                lines.append(row.enumerated().map { csvField($1, text: $0 == 2 || $0 == 5) }.joined(separator: ","))
            }
        }
        return Data("\u{FEFF}".utf8) + Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    static func writeCSV(_ orders: [InboundOrder], scope: ExportScope) throws -> URL {
        let url = try outputURL(fileName(scope, ext: "csv"))
        try csv(orders).write(to: url)
        return url
    }

    // MARK: PDF

    static func writePDF(_ orders: [InboundOrder], scope: ExportScope) throws -> URL {
        let url = try outputURL(fileName(scope, ext: "pdf"))
        let page = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)  // A4 @72dpi
        let margin: CGFloat = 32, minRowH: CGFloat = 44, thumb: CGFloat = 40, footerH: CGFloat = 16
        let cols: [(String, CGFloat)] = [
            (String(localized: "Order No."), 84), (String(localized: "Customer"), 72), (String(localized: "Item"), 76),
            (String(localized: "Size (cm)"), 80), (String(localized: "Qty"), 36), (String(localized: "Volume (m³)"), 50),
            (String(localized: "Weight (kg)"), 44), (String(localized: "Method"), 36)]
        let photoX = margin + cols.reduce(0) { $0 + $1.1 }, photoW = page.width - margin - photoX
        let contentW = page.width - 2 * margin
        let small: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 8)]
        let bold: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 8)]
        let s = Summary(orders)
        let num = { (v: Double, d: ClosedRange<Int>) in v.formatted(.number.precision(.fractionLength(d))) }

        /// Height `s` needs when word-wrapped to `w` (long German/Russian labels wrap instead of clipping).
        func height(_ s: String, _ a: [NSAttributedString.Key: Any], _ w: CGFloat) -> CGFloat {
            ceil((s as NSString).boundingRect(with: CGSize(width: w, height: .greatestFiniteMagnitude),
                                              options: [.usesLineFragmentOrigin], attributes: a, context: nil).height)
        }
        @discardableResult
        func draw(_ s: String, _ a: [NSAttributedString.Key: Any], x: CGFloat, y: CGFloat, w: CGFloat) -> CGFloat {
            let h = height(s, a, w)
            (s as NSString).draw(with: CGRect(x: x, y: y, width: w, height: h), options: [.usesLineFragmentOrigin], attributes: a, context: nil)
            return h
        }

        try UIGraphicsPDFRenderer(bounds: page).writePDF(to: url) { ctx in
            var y: CGFloat = 0, pageNo = 0
            let bottom = page.height - margin - footerH
            func newPage() {
                ctx.beginPage(); pageNo += 1; y = margin
                // ponytail: no "of N" total; that needs a layout pre-pass.
                let p = NSMutableParagraphStyle(); p.alignment = .right
                var a = small; a[.paragraphStyle] = p; a[.foregroundColor] = UIColor.gray
                draw(String(localized: "Page \(pageNo)"), a, x: margin, y: page.height - margin - 10, w: contentW)
            }
            func header() {
                var x = margin, h: CGFloat = 0
                for (t, w) in cols { h = max(h, draw(t, bold, x: x, y: y, w: w - 4)); x += w }
                h = max(h, draw(String(localized: "Photo"), bold, x: photoX, y: y, w: photoW))
                y += h + 2
                UIColor.gray.setFill(); UIRectFill(CGRect(x: margin, y: y, width: contentW, height: 0.5))
                y += 2
            }
            newPage()
            y += draw(scope.pdfTitle, [.font: UIFont.boldSystemFont(ofSize: 20)], x: margin, y: y, w: contentW) + 8
            let info = scope.pdfSubtitle + "\n"
                + String(localized: "Orders: \(s.orders) · Pieces: \(s.pieces) · Total volume: \(num(s.volumeM3, 3...3)) m³ · Total weight: \(num(s.weightKg, 0...2)) kg")
            y += draw(info, [.font: UIFont.systemFont(ofSize: 11)], x: margin, y: y, w: contentW) + 10
            header()
            for o in orders {
                for i in sortedItems(o) {
                    let dims: String = i?.dimsText.replacingOccurrences(of: " ", with: "") ?? ""
                    let vals: [String] = [o.orderNo, o.customer?.name ?? "", i?.name ?? "", dims, i.map { $0.quantity.formatted() } ?? "",
                                          i.map { num($0.totalVolumeM3, 3...3) } ?? "", i?.weightKg.map { num($0, 0...2) } ?? "", i?.methodLabel ?? ""]
                    let rowH = max(minRowH, zip(vals, cols).map { height($0, small, $1.1 - 4) + 4 }.max() ?? 0)
                    if y + rowH > bottom { newPage(); header() }
                    var x = margin
                    for (v, (_, w)) in zip(vals, cols) { draw(v, small, x: x, y: y + 2, w: w - 4); x += w }
                    if let f = i?.photoFiles.first, let img = PhotoStore.thumbnail(f, side: 300) {
                        img.draw(in: AVMakeRect(aspectRatio: img.size, insideRect: CGRect(x: photoX, y: y + 2, width: thumb, height: thumb)))
                    }
                    y += rowH
                }
            }
        }
        return url
    }

    // MARK: ZIP

    /// Zips all item photos (one folder per order) using NSFileCoordinator(.forUploading) (A9).
    /// Throws domain "Exporter" code 1 when there are no photos (ReportsView shows it as "nothing to export").
    static func writePhotosZip(_ orders: [InboundOrder], scope: ExportScope) throws -> URL {
        let fm = FileManager.default
        let base = safeFileName(String(localized: "\(scope.stem) photos"))
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
        guard any else {
            throw NSError(domain: "Exporter", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "The selected orders have no photos.")])
        }
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
