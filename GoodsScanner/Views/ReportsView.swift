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
    @State private var errorTitle = "导出失败"
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
                if list.isEmpty {
                    Section {
                        EmptyState(image: "EmptyReports", title: "所选范围无入库记录", message: "调整日期或客户筛选后再查看汇总与导出")
                            .frame(minHeight: 320)
                            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    }
                } else {
                    Section("汇总") {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                            StatCard(icon: "doc.text", value: "\(total.orders)", unit: "单", label: "入库单数")
                            StatCard(icon: "shippingbox", value: "\(total.pieces)", unit: "件", label: "件数")
                            StatCard(icon: "cube", value: total.volumeM3.m3, unit: "m³", label: "总体积")
                            StatCard(icon: "scalemass", value: total.weightKg.kg, unit: "kg", label: "总重量")
                        }
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    }
                    Section("按客户") {
                        ForEach(byCustomer, id: \.key) { code, os in
                            let s = Summary(os)
                            HStack(spacing: 12) {
                                IconTile(systemName: "person.fill", size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(os.first?.customer?.name ?? "（无客户）").font(.headline).lineLimit(1)
                                    Text("\(s.orders) 单 · \(s.pieces) 件 · \(s.weightKg.kg) kg")
                                        .font(.num(.caption)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                NumText(value: s.volumeM3.m3, unit: "m³", style: .headline)
                            }
                        }
                    }
                    Section("导出") {
                        HStack(spacing: 8) {
                            exportButton("CSV 明细", "tablecells") { try Exporter.writeCSV(list, from: from, to: to) }
                            exportButton("PDF 报表", "doc.richtext") { try Exporter.writePDF(list, from: from, to: to, customerName: customerName) }
                            exportButton("照片 ZIP", "photo.stack") { try Exporter.writePhotosZip(list, from: from, to: to) }
                        }
                        .disabled(exporting)
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    }
                }
            }
            .listSectionSpacing(16)
            .overlay { if exporting { ProgressView("正在导出…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .navigationTitle("报表")
            .sheet(item: $share) { ActivityView(items: [$0.url]) }
            .alert(errorTitle, isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }

    private func exportButton(_ title: String, _ icon: String, make: @escaping () throws -> URL) -> some View {
        Button { export(make) } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title2)
                Text(title).font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.accentText)
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
        }
        .buttonStyle(.borderless)
    }

    /// Runs on the main actor (SwiftData models stay on their thread); the short sleep lets the spinner paint first.
    /// ponytail: blocks the UI during big exports; move to Task.detached over value snapshots if that hurts.
    private func export(_ make: @escaping () throws -> URL) {
        exporting = true
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            do { share = ShareFile(url: try make()) } catch {
                let e = error as NSError
                errorTitle = e.domain == "Exporter" && e.code == 1 ? "无可导出内容" : "导出失败"  // code 1 = no photos
                self.error = e.localizedDescription
            }
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
