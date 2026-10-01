import XCTest
import SwiftData
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
        let header = "入库单号,入库时间,客户代码,客户名称,联系人,电话,操作员,品名,长cm,宽cm,高cm,件数,单件体积m³,总体积m³,重量kg,测量方式,照片文件,入库备注"
        XCTAssertTrue(text.hasPrefix(header + "\r\n"))
        XCTAssertEqual(Exporter.csvColumns.count, 18)
        XCTAssertTrue(text.contains("RK20261001-001,2026-10-01 10:00,C1,\"客户,甲\",\"张\"\"三\"\"\",,,箱子,40,30,20,2,0.024,0.048,,手动,a.jpg;b.jpg,\"两行\n备注\"\r\n"), text)
    }

    func testCSVOrderWithoutItems() throws {
        let o = try addOrder(date(2026, 10, 1))
        let text = String(decoding: Exporter.csv([o]).dropFirst(3), as: UTF8.self)
        XCTAssertTrue(text.hasSuffix("\r\nRK20261001-001,2026-10-01 10:00,,,,,,,,,,,,,,,,\r\n"), text)
    }

    func testFileName() {
        XCTAssertEqual(Exporter.fileName(date(2026, 10, 1), date(2026, 10, 31), ext: "csv"), "入库报表_20261001-20261031.csv")
    }
}
