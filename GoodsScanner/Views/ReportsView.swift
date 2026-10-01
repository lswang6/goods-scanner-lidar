import SwiftUI
import SwiftData

struct ReportsView: View {
    @Query(sort: \InboundOrder.receivedAt) private var allOrders: [InboundOrder]
    @Query(sort: \Customer.code) private var customers: [Customer]
    @State private var from = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
    @State private var to = Date.now
    @State private var customer: Customer?
    @State private var share: ShareFile?
    @State private var error: String?

    private var orders: [InboundOrder] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: from)
        let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: to))!
        return allOrders.filter { $0.receivedAt >= start && $0.receivedAt < end && (customer == nil || $0.customer == customer) }
    }

    var body: some View {
        let list = orders
        let total = Summary(list)
        let byCustomer = Dictionary(grouping: list) { $0.customer?.code ?? "" }.sorted { $0.key < $1.key }
        NavigationStack {
            Form {
                Section("筛选") {
                    DatePicker("开始日期", selection: $from, displayedComponents: .date)
                    DatePicker("结束日期", selection: $to, in: from..., displayedComponents: .date)
                    Picker("客户", selection: $customer) {
                        Text("全部").tag(Customer?.none)
                        ForEach(customers) { Text("\($0.name)（\($0.code)）").tag(Optional($0)) }
                    }
                }
                Section("汇总") {
                    LabeledContent("入库单数", value: "\(total.orders)")
                    LabeledContent("件数", value: "\(total.pieces)")
                    LabeledContent("总体积", value: "\(total.volumeM3.m3) m³")
                    LabeledContent("总重量", value: "\(total.weightKg.trimmed) kg")
                }
                if !byCustomer.isEmpty {
                    Section("按客户") {
                        ForEach(byCustomer, id: \.key) { code, os in
                            let s = Summary(os)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(os.first?.customer?.name ?? "（无客户）").font(.headline)
                                Text("\(s.orders) 单 · \(s.pieces) 件 · \(s.volumeM3.m3) m³ · \(s.weightKg.trimmed) kg")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("导出") {
                    Button { export { try Exporter.writeCSV(list, from: from, to: to) } } label: { Label("导出 CSV 明细", systemImage: "tablecells") }
                    Button { export { try Exporter.writePDF(list, from: from, to: to, customerName: customer?.name) } } label: { Label("导出 PDF 报表", systemImage: "doc.richtext") }
                    Button { export { try Exporter.writePhotosZip(list, from: from, to: to) } } label: { Label("导出照片 ZIP", systemImage: "photo.stack") }
                }
                .disabled(list.isEmpty)
            }
            .navigationTitle("报表")
            .sheet(item: $share) { ActivityView(items: [$0.url]) }
            .alert("导出失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }

    private func export(_ make: () throws -> URL) {
        do { share = ShareFile(url: try make()) } catch { self.error = error.localizedDescription }
    }
}

struct ShareFile: Identifiable {
    let url: URL
    var id: URL { url }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
