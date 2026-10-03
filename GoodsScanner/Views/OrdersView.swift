import SwiftUI
import SwiftData

struct OrdersView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \InboundOrder.receivedAt, order: .reverse) private var orders: [InboundOrder]
    @State private var search = ""
    @State private var creating = false
    @State private var path: [InboundOrder] = []
    /// Set by the new-order form; pushed once the sheet has fully dismissed.
    @State private var created: InboundOrder?
    @State private var confirmDelete: InboundOrder?
    @State private var deleteError: String?

    private var groups: [(day: Date, orders: [InboundOrder])] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let list = q.isEmpty ? orders : orders.filter {
            $0.orderNo.localizedCaseInsensitiveContains(q)
                || ($0.customer?.name.localizedCaseInsensitiveContains(q) ?? false)
                || ($0.customer?.code.localizedCaseInsensitiveContains(q) ?? false)
        }
        let byDay = Dictionary(grouping: list) { Calendar.current.startOfDay(for: $0.receivedAt) }
        return byDay.keys.sorted(by: >).map { ($0, byDay[$0]!) }
    }

    var body: some View {
        let today = orders.filter { Calendar.current.isDateInToday($0.receivedAt) }
        NavigationStack(path: $path) {
            List {
                if search.isEmpty {
                    Section {
                        HStack(spacing: 8) {
                            StatCard(icon: "doc.text", value: "\(today.count)", unit: String(localized: "orders", comment: "Unit after an order count on a stat card; keep very short"), label: "Inbound Today")
                            StatCard(icon: "shippingbox", value: "\(today.reduce(0) { $0 + $1.totalPieces })", unit: String(localized: "pcs", comment: "Unit after a piece count; keep very short"), label: "Pieces Today")
                            StatCard(icon: "cube", value: today.reduce(0) { $0 + $1.totalVolumeM3 }.m3, unit: "m³", label: "Volume Today")
                        }
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    }
                }
                ForEach(groups, id: \.day) { g in
                    Section(g.day.formatted(.dateTime.year().month().day().weekday())) {
                        ForEach(g.orders) { o in
                            NavigationLink(value: o) { OrderRow(order: o) }
                                .swipeActions { Button("Delete", role: .destructive) { confirmDelete = o } }
                        }
                    }
                }
            }
            .listSectionSpacing(16)
            .overlay {
                if orders.isEmpty {
                    EmptyState(image: "EmptyOrders", title: "No inbound orders yet", message: "When goods arrive, create an inbound order, then scan or enter each item’s size.",
                               action: ("New Inbound", { creating = true }))
                }
            }
            .searchable(text: $search, prompt: "Order No. / Customer")
            .navigationTitle("Inbound Orders")
            .navigationDestination(for: InboundOrder.self) { o in OrderDetailView(order: o) { delete(o) } }
            .toolbar {
                Button { creating = true } label: { Label("New Inbound", systemImage: "plus").labelStyle(.titleAndIcon) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(.accent)
            }
            .sheet(isPresented: $creating, onDismiss: { if let o = created { created = nil; path = [o] } }) { OrderForm(order: nil) { created = $0 } }
            .confirmationDialog("Delete this inbound order with all its items and photos?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                                titleVisibility: .visible, presenting: confirmDelete) { o in
                Button("Delete", role: .destructive) { delete(o) }
            }
            .alert("Delete Failed", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(deleteError ?? "") }
        }
    }

    private func delete(_ o: InboundOrder) {
        do { try deleteOrder(o, in: context) } catch { deleteError = error.localizedDescription }
    }
}

private struct OrderRow: View {
    let order: InboundOrder
    private var time: String {
        order.receivedAt.formatted(.verbatim("\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
                                             timeZone: .current, calendar: .current))
    }
    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemName: "shippingbox.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text(order.orderNo).font(.headline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.8)
                // Time lives in the trailing column so the customer name gets the full width.
                Text(order.customer?.name ?? String(localized: "(No customer)"))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                NumText(value: order.totalVolumeM3.m3, unit: "m³", style: .headline)
                Text("\(order.totalPieces) pcs · \(time)")
                    .font(.num(.caption)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
        }
        .padding(.vertical, 2)
    }
}

struct OrderDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let order: InboundOrder
    /// Owned by OrdersView so a failure alert still shows after this view has popped.
    let onDelete: () -> Void
    @State private var editingOrder = false
    @State private var addingItem = false
    @State private var editingItem: CargoItem?
    @State private var viewing: PhotoSelection?
    @State private var confirmDelete = false
    @State private var error: String?
    @State private var share: ShareFile?
    @State private var exportError: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(order.orderNo).font(.num(.title2)).foregroundStyle(.brand)
                    Label(order.customer.map { String(localized: "\($0.name) (\($0.code))") } ?? String(localized: "(No customer)"), systemImage: "person.fill")
                    Label(order.receivedAt.formatted(date: .numeric, time: .shortened), systemImage: "clock")
                    if !order.operatorName.isEmpty { Label(order.operatorName, systemImage: "person.badge.key") }
                    if !order.note.isEmpty { Label(order.note, systemImage: "note.text") }
                }
                .font(.subheadline)
                .padding(.vertical, 4)
            }
            Section {
                HStack(spacing: 8) {
                    StatCard(icon: "shippingbox", value: "\(order.totalPieces)", unit: String(localized: "pcs", comment: "Unit after a piece count; keep very short"), label: "Pieces")
                    StatCard(icon: "cube", value: order.totalVolumeM3.m3, unit: "m³", label: "Total Volume")
                    StatCard(icon: "scalemass", value: order.totalWeightKg.kg, unit: "kg", label: "Total Weight")
                }
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
            Section("Items (\(order.items.count))") {
                ForEach(order.items.sorted { $0.createdAt < $1.createdAt }) { item in
                    ItemRow(item: item, onEdit: { editingItem = item },
                            onPhoto: { viewing = PhotoSelection(files: item.photoFiles, start: 0) })
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                do { try deleteItem(item, in: context) } catch { self.error = error.localizedDescription }
                            }
                        }
                }
                if order.items.isEmpty { Text("No items yet. Tap “Add Item” below.").foregroundStyle(.secondary) }
            }
            Section {
                Button("Delete Inbound Order", role: .destructive) { confirmDelete = true }
            }
        }
        .listSectionSpacing(16)
        .safeAreaInset(edge: .bottom) {
            Button { addingItem = true } label: { Label("Add Item", systemImage: "plus") }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.bar)
        }
        .navigationTitle(order.orderNo)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Button { export { try Exporter.writeCSV([order], scope: .order(order)) } } label: { Label("CSV", systemImage: "tablecells") }
                Button { export { try Exporter.writePDF([order], scope: .order(order)) } } label: { Label("PDF", systemImage: "doc.richtext") }
                Button { export { try Exporter.writePhotosZip([order], scope: .order(order)) } } label: { Label("Photos ZIP", systemImage: "photo.stack") }
                    .disabled(order.items.allSatisfy(\.photoFiles.isEmpty))
            } label: { Label("Export", systemImage: "square.and.arrow.up") }
            Button("Edit") { editingOrder = true }
        }
        .sheet(item: $share) { ActivityView(items: [$0.url]) }
        .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(exportError ?? "") }
        .sheet(isPresented: $editingOrder) { OrderForm(order: order) }
        .sheet(isPresented: $addingItem) { ItemEditView(order: order, item: nil) }
        .sheet(item: $editingItem) { ItemEditView(order: order, item: $0) }
        .fullScreenCover(item: $viewing) { PhotoViewer($0) }
        .confirmationDialog("Delete this inbound order with all its items and photos?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                // Pop first so this view never re-renders against a deleted model.
                dismiss()
                DispatchQueue.main.async { onDelete() }
            }
        }
        .alert("Delete Failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    /// One order is small, so this runs inline (no spinner, unlike ReportsView).
    private func export(_ make: () throws -> URL) {
        do { share = ShareFile(url: try make()) } catch { exportError = error.localizedDescription }
    }
}

/// Thumbnail and the rest of the row are sibling plain buttons so List hit-tests them separately:
/// the thumbnail opens the photo viewer, anywhere else edits the item.
private struct ItemRow: View {
    let item: CargoItem
    let onEdit: () -> Void
    let onPhoto: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            if let f = item.photoFiles.first {
                Button(action: onPhoto) { thumb(PhotoStore.thumbnail(f, side: 200)) }
                    .buttonStyle(.plain).accessibilityLabel("View photo")
            }
            Button(action: onEdit) {
                HStack(spacing: 12) {
                    if item.photoFiles.isEmpty { thumb(nil) }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(item.name.isEmpty ? String(localized: "(Unnamed)") : item.name).font(.headline).lineLimit(1)
                            if item.method != "manual" { Image(systemName: CargoItem.methodIcon(item.method)).font(.caption).foregroundStyle(.scanText) }
                        }
                        DimsBadge(l: item.lengthCm, w: item.widthCm, h: item.heightCm, shape: item.shape)
                        if let kg = item.weightKg { NumText(value: kg.kg, unit: "kg", style: .caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 2) {
                        NumText(value: item.totalVolumeM3.m3, unit: "m³", style: .headline)
                        Text("× \(item.quantity)").font(.num(.subheadline)).foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    private func thumb(_ img: UIImage?) -> some View {
        Group {
            if let img {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Image(systemName: "shippingbox.fill").font(.title2).foregroundStyle(.brand)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.brand.opacity(0.12))
            }
        }
        .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: Radius.tag, style: .continuous))
    }
}

struct OrderForm: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Customer.code) private var customers: [Customer]
    @AppStorage("defaultOperator") private var defaultOperator = ""
    let order: InboundOrder?
    /// Called after a NEW order is saved (not on edit).
    let onCreated: (InboundOrder) -> Void
    @State private var customer: Customer?
    @State private var receivedAt: Date
    @State private var operatorName: String?
    @State private var note: String
    @State private var error: String?

    init(order: InboundOrder?, onCreated: @escaping (InboundOrder) -> Void = { _ in }) {
        self.order = order
        self.onCreated = onCreated
        _customer = State(initialValue: order?.customer)
        _receivedAt = State(initialValue: order?.receivedAt ?? .now)
        _operatorName = State(initialValue: order?.operatorName)
        _note = State(initialValue: order?.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                if let order { LabeledContent("Order No.", value: order.orderNo) }
                Picker("Customer", selection: $customer) {
                    Text("Select").tag(Customer?.none)
                    ForEach(customers) { Text("\($0.name) (\($0.code))").tag(Optional($0)) }
                }
                DatePicker("Received At", selection: $receivedAt)
                TextField("Operator", text: Binding(get: { operatorName ?? defaultOperator }, set: { operatorName = $0 }))
                TextField("Note", text: $note, axis: .vertical)
                if customers.isEmpty { Text("Create a customer in the Customers tab first.").foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(order == nil ? "New Inbound Order" : "Edit Inbound Order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
        }
    }

    private func save() {
        guard let customer else { error = String(localized: "Please select a customer."); return }
        let op = (operatorName ?? defaultOperator).trimmingCharacters(in: .whitespaces)
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        var new: InboundOrder?
        if let order {
            // Order number is issued once at creation and never regenerated, even if receivedAt changes.
            order.customer = customer; order.receivedAt = receivedAt; order.operatorName = op; order.note = note
        } else {
            do {
                let no = try InboundOrder.nextOrderNo(for: receivedAt, in: context)
                new = InboundOrder(orderNo: no, customer: customer, receivedAt: receivedAt, operatorName: op, note: note)
                context.insert(new!)
            } catch { self.error = String(localized: "Couldn’t generate an order number: \(error.localizedDescription)"); return }
        }
        do { try context.save() } catch { context.rollback(); self.error = String(localized: "Save failed: \(error.localizedDescription)"); return }
        if let new { onCreated(new) }
        dismiss()
    }
}
