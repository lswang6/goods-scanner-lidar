import XCTest
import SwiftData
import simd
import BoxMeasureKit
@testable import GoodsScanner

@MainActor
final class GoodsScannerTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainer(for: Customer.self, InboundOrder.self, CargoItem.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 10) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    @discardableResult
    private func addOrder(_ at: Date) throws -> InboundOrder {
        let o = InboundOrder(orderNo: try InboundOrder.nextOrderNo(for: at, in: context), customer: nil, receivedAt: at)
        context.insert(o)
        try context.save()
        return o
    }

    func testOrderNoSequenceAndBackdating() throws {
        XCTAssertEqual(try addOrder(date(2026, 10, 1)).orderNo, "RK20261001-001")
        XCTAssertEqual(try addOrder(date(2026, 10, 1, 23)).orderNo, "RK20261001-002")
        // Back-dated: sequence comes from the receivedAt day, not today.
        XCTAssertEqual(try addOrder(date(2026, 9, 15)).orderNo, "RK20260915-001")
        XCTAssertEqual(try addOrder(date(2026, 9, 15, 0)).orderNo, "RK20260915-002")
        XCTAssertEqual(try addOrder(date(2026, 10, 1, 0)).orderNo, "RK20261001-003")
    }

    func testOrderNoNotReusedAfterDeletingEarlier() throws {
        let first = try addOrder(date(2026, 10, 1))
        try addOrder(date(2026, 10, 1))
        context.delete(first)
        try context.save()
        XCTAssertEqual(try addOrder(date(2026, 10, 1)).orderNo, "RK20261001-003")
    }

    func testOrderNoAfterEditingReceivedAtDoesNotOverwrite() throws {
        let first = try addOrder(date(2026, 10, 1))
        XCTAssertEqual(first.orderNo, "RK20261001-001")
        first.receivedAt = date(2026, 10, 2)   // date edited; orderNo stays
        try context.save()
        let second = try addOrder(date(2026, 10, 1))
        XCTAssertEqual(second.orderNo, "RK20261001-002")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<InboundOrder>()), 2)
        XCTAssertEqual(first.orderNo, "RK20261001-001")
        XCTAssertEqual(try addOrder(date(2026, 10, 2)).orderNo, "RK20261002-001")
    }

    func testNumberFormatting() {
        XCTAssertEqual(12345.67.kg, "12345.67")
        XCTAssertEqual(1_000_000.0.kg, "1000000")
        XCTAssertEqual(40.0.cm, "40")
        XCTAssertEqual(40.26.cm, "40.3")
        XCTAssertEqual(0.00012.fixed(4), "0.0001")
    }

    func testVolumes() throws {
        let item = CargoItem(name: "箱", lengthCm: 100, widthCm: 100, heightCm: 100, quantity: 2, weightKg: 5)
        XCTAssertEqual(item.unitVolumeM3, 1, accuracy: 1e-9)
        XCTAssertEqual(item.totalVolumeM3, 2, accuracy: 1e-9)
        let small = CargoItem(lengthCm: 40, widthCm: 30, heightCm: 20, quantity: 3)
        XCTAssertEqual(small.unitVolumeM3, 0.024, accuracy: 1e-9)
        XCTAssertEqual(small.totalVolumeM3.m3, "0.072")

        let o = try addOrder(date(2026, 10, 1))
        for i in [item, small] { context.insert(i); i.order = o }
        try context.save()
        XCTAssertEqual(o.totalPieces, 5)
        XCTAssertEqual(o.totalVolumeM3, 2.072, accuracy: 1e-9)
        XCTAssertEqual(o.totalWeightKg, 5, accuracy: 1e-9)
        XCTAssertEqual(Summary([o]).volumeM3, 2.072, accuracy: 1e-9)
    }

    func testCSVEscaping() {
        XCTAssertEqual(Exporter.csvField("plain"), "plain")
        XCTAssertEqual(Exporter.csvField("a,b"), "\"a,b\"")
        XCTAssertEqual(Exporter.csvField("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(Exporter.csvField("line1\nline2"), "\"line1\nline2\"")
        XCTAssertEqual(Exporter.csvField("cr\r"), "\"cr\r\"")
        XCTAssertEqual(Exporter.csvField("a\r\nb"), "\"a\r\nb\"")
        XCTAssertEqual(Exporter.csvField("=1+1"), "'=1+1")
        XCTAssertEqual(Exporter.csvField("@x"), "'@x")
        XCTAssertEqual(Exporter.csvField("-5,x"), "\"'-5,x\"")
        XCTAssertEqual(Exporter.csvField("001", text: true), "\"=\"\"001\"\"\"")
        XCTAssertEqual(Exporter.csvField("C001", text: true), "C001")
    }

    func testCSVBOMHeaderAndRow() throws {
        let c = Customer(code: "C1", name: "客户,甲", contact: "张\"三\"")
        context.insert(c)
        let o = try addOrder(date(2026, 10, 1))
        o.customer = c; o.note = "两行\n备注"
        let i = CargoItem(name: "箱子", lengthCm: 40, widthCm: 30, heightCm: 20, quantity: 2, photoFiles: ["a.jpg", "b.jpg"])
        context.insert(i); i.order = o
        try context.save()

        let data = Exporter.csv([o])
        XCTAssertEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF])
        let text = String(decoding: data.dropFirst(3), as: UTF8.self)
        let header = "Order No.,Received,Customer code,Customer name,Contact,Phone,Operator,Item,Length (cm),Width (cm),Height (cm),Quantity,"
            + "Unit volume (m³),Total volume (m³),Weight (kg),Measuring method,Photo files,Order note,Shape"
        XCTAssertTrue(text.hasPrefix(header + "\r\n"), text)
        XCTAssertEqual(Exporter.csvColumns.count, 19)
        XCTAssertTrue(text.contains("RK20261001-001,2026-10-01 10:00,C1,\"客户,甲\",\"张\"\"三\"\"\",,,箱子,40,30,20,2,0.024,0.048,,Manual,a.jpg;b.jpg,\"两行\n备注\",Box\r\n"), text)

        let cyl = CargoItem(name: "桶", lengthCm: 26, widthCm: 26, heightCm: 25.5, method: "lidar", shape: "cylinder")
        context.insert(cyl); cyl.order = o
        try context.save()
        let text2 = String(decoding: Exporter.csv([o]).dropFirst(3), as: UTF8.self)
        XCTAssertTrue(text2.contains(",桶,26,26,25.5,1,0.0172,0.0172,,LiDAR,,\"两行\n备注\",Cylinder\r\n"), text2)
        XCTAssertEqual(cyl.dimsText, "Ø26 × 25.5")
        XCTAssertEqual(CargoItem.dimsText(1000, 30, 20.04, shape: "box"), "1000 × 30 × 20")  // no grouping
        XCTAssertEqual(CargoItem().shape, "box")
        XCTAssertEqual(CargoItem.shapes.map(CargoItem.shapeLabel), ["Box", "Cylinder", "Irregular"])
    }

    func testCSVOrderWithoutItems() throws {
        let o = try addOrder(date(2026, 10, 1))
        let text = String(decoding: Exporter.csv([o]).dropFirst(3), as: UTF8.self)
        XCTAssertTrue(text.hasSuffix("\r\nRK20261001-001,2026-10-01 10:00,,,,,,,,,,,,,,,,,\r\n"), text)
    }

    func testPDFExportMultiPage() throws {
        let a = Customer(code: "C001", name: "甲公司"), b = Customer(code: "C002", name: "乙公司")
        [a, b].forEach { context.insert($0) }
        var orders: [InboundOrder] = []
        for (n, c) in [a, b, a, b].enumerated() {
            let o = try addOrder(date(2026, 10, 1 + n))
            o.customer = c
            orders.append(o)
        }
        // orders[3] stays empty; 30 item rows (~15 fit per page) force a second page.
        for k in 0..<30 {
            let i = CargoItem(name: "箱\(k)", lengthCm: 40, widthCm: 30, heightCm: 20, quantity: 2, weightKg: 5,
                              photoFiles: ["missing.jpg"], method: k.isMultiple(of: 2) ? "lidar" : "manual")
            context.insert(i); i.order = orders[k % 3]
        }
        try context.save()

        let url = try Exporter.writePDF(orders, scope: .range(from: date(2026, 10, 1), to: date(2026, 10, 31), customer: nil))
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.prefix(4), Data("%PDF".utf8))
        let pdf = try XCTUnwrap(CGPDFDocument(url as CFURL))
        XCTAssertGreaterThanOrEqual(pdf.numberOfPages, 2)

        // Single order: one page, named after the order.
        let one = try Exporter.writePDF([orders[0]], scope: .order(orders[0]))
        XCTAssertEqual(one.lastPathComponent, "Inbound order RK20261001-001.pdf")
        XCTAssertEqual(try XCTUnwrap(CGPDFDocument(one as CFURL)).numberOfPages, 1)
    }

    func testFileName() throws {
        let (f, t) = (date(2026, 10, 1), date(2026, 10, 31))
        XCTAssertEqual(Exporter.fileName(.range(from: f, to: t, customer: nil), ext: "csv"), "Inbound report 20261001-20261031.csv")
        XCTAssertEqual(Exporter.fileName(.range(from: f, to: t, customer: "A/B: \"Co\"\n"), ext: "pdf"),
                       "Inbound report 20261001-20261031 A_B_ _Co__.pdf")
        XCTAssertEqual(Exporter.fileName(.picked(count: 3, from: f, to: t), ext: "zip"), "Inbound report 20261001-20261031 3 orders.zip")
        let o = try addOrder(f)
        XCTAssertEqual(Exporter.fileName(.order(o), ext: "csv"), "Inbound order RK20261001-001.csv")
    }

    /// A hand-picked subset exports only those orders' rows, under a name that says how many.
    func testSelectedSubsetCSV() throws {
        let orders = try (1...3).map { try addOrder(date(2026, 10, $0)) }
        for o in orders {
            let i = CargoItem(name: "box", lengthCm: 10, widthCm: 10, heightCm: 10)
            context.insert(i); i.order = o
        }
        try context.save()
        let picked = [orders[0], orders[2]]
        let url = try Exporter.writeCSV(picked, scope: .picked(count: picked.count, from: date(2026, 10, 1), to: date(2026, 10, 3)))
        XCTAssertEqual(url.lastPathComponent, "Inbound report 20261001-20261003 2 orders.csv")
        let text = String(decoding: try Data(contentsOf: url).dropFirst(3), as: UTF8.self)
        let rows = text.split(separator: "\r\n").dropFirst()
        XCTAssertEqual(rows.map { String($0.prefix(14)) }, ["RK20261001-001", "RK20261003-001"])
    }

    func testSingleOrderCSV() throws {
        let o = try addOrder(date(2026, 10, 5))
        for n in ["a", "b"] { let i = CargoItem(name: n, lengthCm: 10, widthCm: 10, heightCm: 10); context.insert(i); i.order = o }
        try addOrder(date(2026, 10, 5))  // not exported
        try context.save()
        let url = try Exporter.writeCSV([o], scope: .order(o))
        XCTAssertEqual(url.lastPathComponent, "Inbound order RK20261005-001.csv")
        let rows = String(decoding: try Data(contentsOf: url).dropFirst(3), as: UTF8.self).split(separator: "\r\n").dropFirst()
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.hasPrefix("RK20261005-001,") })
    }

    /// PhotoAnnotator mapping with a synthetic camera at the origin in ARKit's landscape-right camera frame
    /// (x toward the home indicator, y up in landscape, looking down -z). Landscape 192x144 -> portrait 144x192.
    func testPhotoProjectionMapping() throws {
        let res = CGSize(width: 192, height: 144), size = CGSize(width: 144, height: 192)
        let K = simd_float3x3(SIMD3(150, 0, 0), SIMD3(0, 150, 0), SIMD3(95.5, 71.5, 1))
        let T = matrix_identity_float4x4
        func proj(_ p: SIMD3<Float>) -> CGPoint? {
            PhotoAnnotator.project(p, transform: T, intrinsics: K, imageResolution: res, imageSize: size)
        }
        // Optical axis -> portrait centre: (H-1-cy, cx) = (71.5, 95.5).
        let c = try XCTUnwrap(proj(SIMD3(0, 0, -1)))
        XCTAssertEqual(c.x, 71.5, accuracy: 0.01); XCTAssertEqual(c.y, 95.5, accuracy: 0.01)
        // Camera +x (toward home indicator) = portrait DOWN; camera +y = portrait RIGHT.
        let px = try XCTUnwrap(proj(SIMD3(0.1, 0, -1))), py = try XCTUnwrap(proj(SIMD3(0, 0.1, -1)))
        XCTAssertEqual(px.x, c.x, accuracy: 0.01); XCTAssertEqual(px.y, c.y + 15, accuracy: 0.01)
        XCTAssertEqual(py.x, c.x + 15, accuracy: 0.01); XCTAssertEqual(py.y, c.y, accuracy: 0.01)
        XCTAssertNil(proj(SIMD3(0, 0, 1)), "behind the camera")

        // Box 30x20x20 cm centred on the optical axis 1 m ahead: all corners inside, centre near image centre.
        let box = BoxEstimate(length: 0.3, width: 0.2, height: 0.2, center: SIMD3(0, -0.1, -1), yaw: 0.3, planeY: -0.1, pointCount: 1)
        let pts = PhotoAnnotator.corners(box).map(proj)
        for p in pts {
            let p = try XCTUnwrap(p)
            XCTAssertTrue(CGRect(origin: .zero, size: size).contains(p), "\(p)")
        }
        let mean = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1!.x / 8, y: $0.y + $1!.y / 8) }
        XCTAssertEqual(mean.x, size.width / 2, accuracy: 6); XCTAssertEqual(mean.y, size.height / 2, accuracy: 6)

        let photo = try XCTUnwrap(UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
            .image { _ in UIColor.gray.setFill(); UIRectFill(CGRect(origin: .zero, size: size)) }.cgImage)
        let out = PhotoAnnotator.annotate(image: photo, transform: T, intrinsics: K, imageResolution: res, box: box, labels: (30, 20, 20))
        XCTAssertEqual(out.size.width * out.scale, 144); XCTAssertEqual(out.size.height * out.scale, 192)

        // Cylinder Ø26 × 25.5 cm on the optical axis 1 m ahead: every sampled ring point lands inside the image,
        // rings are true circles of radius D/2 at the base and at +H.
        var cyl = BoxEstimate(length: 0.26, width: 0.26, height: 0.255, center: SIMD3(0, -0.1, -1), yaw: 0, planeY: -0.1, pointCount: 1)
        cyl.shape = .cylinder
        let rings = PhotoAnnotator.cylinderRings(cyl)
        XCTAssertEqual(rings.count, 2); XCTAssertEqual(rings[0].count, 48)
        for (k, ring) in rings.enumerated() {
            for p in ring {
                XCTAssertEqual(simd_length(SIMD2(p.x - cyl.center.x, p.z - cyl.center.z)), 0.13, accuracy: 1e-5)
                XCTAssertEqual(p.y, cyl.center.y + (k == 0 ? 0 : cyl.height), accuracy: 1e-6)
                let q = try XCTUnwrap(proj(p))
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(q), "\(q)")
            }
        }
        let outCyl = PhotoAnnotator.annotate(image: photo, transform: T, intrinsics: K, imageResolution: res, box: cyl, labels: (26, 26, 25.5))
        XCTAssertEqual(outCyl.size.width * outCyl.scale, 144)
    }
}
