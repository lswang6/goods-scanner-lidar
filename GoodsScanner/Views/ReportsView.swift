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
    /// nil = every order in the filter (also picks up new ones); reset whenever the filter changes.
    @State private var selectedIDs: Set<PersistentIdentifier>?
    @State private var share: ShareFile?
    @State private var error: String?
    @State private var errorTitle = ""
    @State private var exporting = false

    private var to: Date { pickedTo ?? .now }

    private var orders: [InboundOrder] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: from)
        let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: to))!
        return allOrders.filter { $0.receivedAt >= start && $0.receivedAt < end && (customerID == nil || $0.customer?.persistentModelID == customerID) }
    }

    var body: some View {
        let filtered = orders
        let list = selectedIDs.map { ids in filtered.filter { ids.contains($0.persistentModelID) } } ?? filtered
        let customerName = customers.first { $0.persistentModelID == customerID }?.name
        let scope: ExportScope = list.count == filtered.count ? .range(from: from, to: to, customer: customerName)
            : list.count == 1 ? .order(list[0]) : .picked(count: list.count, from: from, to: to)
        let total = Summary(list)
        let byCustomer = Dictionary(grouping: list) { $0.customer?.code ?? "" }.sorted { $0.key < $1.key }
        NavigationStack {
            Form {
                Section("Filter") {
                    DatePicker("Start Date", selection: $from, in: ...to, displayedComponents: .date)
                    DatePicker("End Date", selection: Binding(get: { to }, set: { pickedTo = $0 }), in: from..., displayedComponents: .date)
                    Picker("Customer", selection: $customerID) {
                        Text("All").tag(PersistentIdentifier?.none)
                        ForEach(customers) { Text("\($0.name) (\($0.code))").tag(Optional($0.persistentModelID)) }
                    }
                    NavigationLink {
                        OrderPicker(orders: filtered, selectedIDs: $selectedIDs)
                    } label: {
                        LabeledContent("Orders") {
                            Text(list.count < filtered.count ? "\(list.count) of \(filtered.count) selected" : "All (\(filtered.count))")
                        }
                    }
                    .disabled(filtered.isEmpty)
                }
                if filtered.isEmpty {
                    Section {
                        EmptyState(image: "EmptyReports", title: "No inbound records in this range", message: "Adjust the date or customer filter to see the summary and export.")
                            .frame(minHeight: 320)
                            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    }
                } else {
                    Section("Summary") {
                        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                            GridRow {
                                StatCard(icon: "doc.text", count: total.orders, phrase: String(localized: "\(total.orders) orders"), label: "Order Count")
                                StatCard(icon: "shippingbox", count: total.pieces, phrase: String(localized: "\(total.pieces) pcs"), label: "Pieces")
                            }
                            GridRow {
                                StatCard(icon: "cube", value: total.volumeM3.m3, unit: "m³", label: "Total Volume")
                                StatCard(icon: "scalemass", value: total.weightKg.kg, unit: "kg", label: "Total Weight")
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    }
                    Section("By Customer") {
                        ForEach(byCustomer, id: \.key) { code, os in
                            let s = Summary(os)
                            HStack(spacing: 12) {
                                IconTile(systemName: "person.fill", size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(os.first?.customer?.name ?? String(localized: "(No customer)")).font(.headline).lineLimit(1)
                                    Text([String(localized: "\(s.orders) orders"), String(localized: "\(s.pieces) pcs"), "\(s.weightKg.kg) kg"].joined(separator: " · "))
                                        .font(.num(.caption)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                NumText(value: s.volumeM3.m3, unit: "m³", style: .headline)
                            }
                        }
                    }
                    Section("Export") {
                        HStack(spacing: 8) {
                            exportButton("CSV Details", "tablecells") { try Exporter.writeCSV(list, scope: scope) }
                            exportButton("PDF Report", "doc.richtext") { try Exporter.writePDF(list, scope: scope) }
                            exportButton("Photos ZIP", "photo.stack") { try Exporter.writePhotosZip(list, scope: scope) }
                        }
                        .disabled(exporting || list.isEmpty)
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    }
                }
            }
            .listSectionSpacing(16)
            .overlay { if exporting { ProgressView("Exporting…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .navigationTitle("Reports")
            .onChange(of: from) { selectedIDs = nil }
            .onChange(of: pickedTo) { selectedIDs = nil }  // not `to`: it's re-evaluated (.now) every render
            .onChange(of: customerID) { selectedIDs = nil }
            .sheet(item: $share) { ActivityView(items: [$0.url]) }
            .alert(errorTitle, isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }

    private func exportButton(_ title: LocalizedStringKey, _ icon: String, make: @escaping () throws -> URL) -> some View {
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
                // code 1 = no photos
                errorTitle = e.domain == "Exporter" && e.code == 1 ? String(localized: "Nothing to export") : String(localized: "Export failed")
                self.error = e.localizedDescription
            }
            exporting = false
        }
    }
}

/// Multi-select of the orders in the current report filter.
private struct OrderPicker: View {
    let orders: [InboundOrder]
    @Binding var selectedIDs: Set<PersistentIdentifier>?

    var body: some View {
        List(orders) { o in
            let id = o.persistentModelID
            let on = selectedIDs?.contains(id) ?? true
            Button {
                var ids = selectedIDs ?? Set(orders.map(\.persistentModelID))
                if on { ids.remove(id) } else { ids.insert(id) }
                selectedIDs = ids.count == orders.count ? nil : ids
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundStyle(on ? Color.accent : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(o.orderNo).font(.headline.monospacedDigit())
                        Text("\(o.customer?.name ?? "—") · \(o.receivedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        NumText(value: o.totalVolumeM3.m3, unit: "m³", style: .headline)
                        Text("\(o.totalPieces) pcs").font(.num(.caption)).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(on ? .isSelected : [])
        }
        .navigationTitle("Select orders")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Button("Select all") { selectedIDs = nil }
                Button("Select none") { selectedIDs = [] }
            } label: { Label("Selection", systemImage: "checklist") }
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
