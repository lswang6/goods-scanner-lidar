import Foundation
import SwiftData

@Model final class Customer {
    @Attribute(.unique) var code: String
    var name: String
    var contact: String
    var phone: String
    var address: String
    var note: String
    var createdAt: Date
    // .deny may be ignored by SwiftData; the UI checks `orders.isEmpty` before deleting (A6).
    @Relationship(deleteRule: .deny, inverse: \InboundOrder.customer) var orders: [InboundOrder] = []

    init(code: String, name: String, contact: String = "", phone: String = "", address: String = "", note: String = "", createdAt: Date = .now) {
        self.code = code; self.name = name; self.contact = contact; self.phone = phone
        self.address = address; self.note = note; self.createdAt = createdAt
    }
}

@Model final class InboundOrder {
    @Attribute(.unique) var orderNo: String
    var customer: Customer?
    var receivedAt: Date
    var operatorName: String
    var note: String
    @Relationship(deleteRule: .cascade, inverse: \CargoItem.order) var items: [CargoItem] = []

    init(orderNo: String, customer: Customer?, receivedAt: Date, operatorName: String = "", note: String = "") {
        self.orderNo = orderNo; self.customer = customer; self.receivedAt = receivedAt
        self.operatorName = operatorName; self.note = note
    }

    var totalPieces: Int { items.reduce(0) { $0 + $1.quantity } }
    var totalVolumeM3: Double { items.reduce(0) { $0 + $1.totalVolumeM3 } }
    var totalWeightKg: Double { items.reduce(0) { $0 + ($1.weightKg ?? 0) } }

    /// A8: RK + yyyyMMdd + "-" + 3-digit sequence within the day of `receivedAt`.
    /// Uses max existing suffix + 1 (not count) so deleting an earlier order never reissues a live number.
    /// Matches on the orderNo prefix, not the receivedAt range: receivedAt is editable after issue, and a reused
    /// number would make the `.unique` orderNo upsert (silently overwrite) the older order.
    static func nextOrderNo(for receivedAt: Date, in context: ModelContext) throws -> String {
        let prefix = "RK" + dayFormatter.string(from: receivedAt) + "-"
        let sameDay = try context.fetch(FetchDescriptor<InboundOrder>(predicate: #Predicate { $0.orderNo.starts(with: prefix) }))
        let maxSeq = sameDay.compactMap { Int($0.orderNo.dropFirst(prefix.count)) }.max() ?? 0
        return prefix + String(format: "%03d", maxSeq + 1)
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f
    }()
}

@Model final class CargoItem {
    var order: InboundOrder?
    var name: String
    var lengthCm: Double
    var widthCm: Double
    var heightCm: Double
    var quantity: Int
    var weightKg: Double?
    var photoFiles: [String]
    var method: String  // "lidar" | "manual"
    var confidence: Double?
    var createdAt: Date
    /// SPEC §13 E4: "box" | "cylinder" | "irregular" (cylinder: L = W = diameter). The default value lets
    /// SwiftData lightweight-migrate stores created before this attribute existed.
    var shape: String = "box"

    init(name: String = "", lengthCm: Double = 0, widthCm: Double = 0, heightCm: Double = 0, quantity: Int = 1,
         weightKg: Double? = nil, photoFiles: [String] = [], method: String = "manual", confidence: Double? = nil,
         shape: String = "box", createdAt: Date = .now) {
        self.name = name; self.lengthCm = lengthCm; self.widthCm = widthCm; self.heightCm = heightCm
        self.quantity = quantity; self.weightKg = weightKg; self.photoFiles = photoFiles
        self.method = method; self.confidence = confidence; self.shape = shape; self.createdAt = createdAt
    }

    var unitVolumeM3: Double { CargoItem.volumeM3(lengthCm, widthCm, heightCm) }
    var totalVolumeM3: Double { unitVolumeM3 * Double(quantity) }
    var methodLabel: String { method == "lidar" ? String(localized: "LiDAR") : String(localized: "Manual") }
    var shapeLabel: String { CargoItem.shapeLabel(shape) }
    /// "26 × 26 × 25.5" (box/irregular) or "Ø26 × 25.5" (cylinder), no unit.
    var dimsText: String { CargoItem.dimsText(lengthCm, widthCm, heightCm, shape: shape) }

    static let shapes = ["box", "cylinder", "irregular"]
    static func shapeLabel(_ s: String) -> String {
        s == "cylinder" ? String(localized: "Cylinder") : s == "irregular" ? String(localized: "Irregular") : String(localized: "Box")
    }
    static func shapeIcon(_ s: String) -> String { s == "cylinder" ? "cylinder" : s == "irregular" ? "scribble.variable" : "shippingbox" }
    /// Display text: numbers in the user's locale (0-1 decimals, no grouping). CSV uses `.cm` instead.
    static func dimsText(_ l: Double, _ w: Double, _ h: Double, shape: String) -> String {
        let f = { (v: Double) in v.formatted(.number.precision(.fractionLength(0...1)).grouping(.never)) }
        return shape == "cylinder" ? String(localized: "Ø\(f(l)) × \(f(h))") : String(localized: "\(f(l)) × \(f(w)) × \(f(h))")
    }

    static func volumeM3(_ l: Double, _ w: Double, _ h: Double) -> Double { l * w * h / 1_000_000 }
}

/// A6: snapshot photo names before the cascade clears items; remove files only once the delete is saved.
/// On failure the pending delete is rolled back so a later autosave can't commit it and orphan the files.
func deleteOrder(_ order: InboundOrder, in context: ModelContext) throws {
    let files = order.items.flatMap(\.photoFiles)
    context.delete(order)
    do { try context.save() } catch { context.rollback(); throw error }
    PhotoStore.delete(files)
}

func deleteItem(_ item: CargoItem, in context: ModelContext) throws {
    let files = item.photoFiles
    context.delete(item)
    do { try context.save() } catch { context.rollback(); throw error }
    PhotoStore.delete(files)
}

extension Double {
    var m3: String { String(format: "%.3f", self) }
    var cm: String { fixed(1) }
    var kg: String { fixed(2) }
    /// `digits` decimals, trailing zeros trimmed; String(format:) is locale-independent ("." decimal).
    func fixed(_ digits: Int) -> String {
        var s = String(format: "%.\(digits)f", self)
        if s.contains(".") { while s.hasSuffix("0") { s.removeLast() }; if s.hasSuffix(".") { s.removeLast() } }
        return s == "-0" ? "0" : s
    }
}
