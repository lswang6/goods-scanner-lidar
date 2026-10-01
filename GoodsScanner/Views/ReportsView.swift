import SwiftUI
import SwiftData

struct ReportsView: View {
    @Query(sort: \InboundOrder.receivedAt) private var allOrders: [InboundOrder]
    @Query(sort: \Customer.code) private var customers: [Customer]
    @State private var from = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
    /// nil = "today" (re-evaluated each render) until the user picks an end date.
    @State private var pickedTo: Date?
    /// An ID, not the model: the customer may be deleted elsewhere while selected.
    @State private var customerID: PersistentIdentifier?
    @State private var share: ShareFile?
    @State private var error: String?
    @State private var exporting = false

    private var to: Date { pickedTo ?? .now }

    private var orders: [InboundOrder] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: from)
        let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: to))!
        return allOrders.filter { $0.receivedAt >= start && $0.receivedAt < end && (customerID == nil || $0.customer?.persistentModelID == customerID) }
    }

    var body: some View {
        let list = orders
        let customerName = customers.first { $0.persistentModelID == customerID }?.name
        let total = Summary(list)
        let byCustomer = Dictionary(grouping: list) { $0.customer?.code ?? "" }.sorted { $0.key < $1.key }
        NavigationStack {
            Form {
                Section("筛选") {
                    DatePicker("开始日期", selection: $from, in: ...to, displayedComponents: .date)
                    DatePicker("结束日期", selection: Binding(get: { to }, set: { pickedTo = $0 }), in: from..., displayedComponents: .date)
                    Picker("客户", selection: $customerID) {
                        Text("全部").tag(PersistentIdentifier?.none)
                        ForEach(customers) { Text("\($0.name)（\($0.code)）").tag(Optional($0.persistentModelID)) }
                    }
                }
                Section("汇总") {
                    LabeledContent("入库单数", value: "\(total.orders)")
                    LabeledContent("件数", value: "\(total.pieces)")
                    LabeledContent("总体积", value: "\(total.volumeM3.m3) m³")
                    LabeledContent("总重量", value: "\(total.weightKg.kg) kg")
                }
                if !byCustomer.isEmpty {
                    Section("按客户") {
                        ForEach(byCustomer, id: \.key) { code, os in
                            let s = Summary(os)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(os.first?.customer?.name ?? "（无客户）").font(.headline)
                                Text("\(s.orders) 单 · \(s.pieces) 件 · \(s.volumeM3.m3) m³ · \(s.weightKg.kg) kg")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("导出") {
                    Button { export { try Exporter.writeCSV(list, from: from, to: to) } } label: { Label("导出 CSV 明细", systemImage: "tablecells") }
                    Button { export { try Exporter.writePDF(list, from: from, to: to, customerName: customerName) } } label: { Label("导出 PDF 报表", systemImage: "doc.richtext") }
                    Button { export { try Exporter.writePhotosZip(list, from: from, to: to) } } label: { Label("导出照片 ZIP", systemImage: "photo.stack") }
                }
                .disabled(list.isEmpty || exporting)
            }
            .overlay { if exporting { ProgressView("正在导出…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .navigationTitle("报表")
            .sheet(item: $share) { ActivityView(items: [$0.url]) }
            .alert("导出失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }

    /// Runs on the main actor (SwiftData models stay on their thread); the short sleep lets the spinner paint first.
    /// ponytail: blocks the UI during big exports; move to Task.detached over value snapshots if that hurts.
    private func export(_ make: @escaping () throws -> URL) {
        exporting = true
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            do { share = ShareFile(url: try make()) } catch { self.error = error.localizedDescription }
            exporting = false
        }
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
