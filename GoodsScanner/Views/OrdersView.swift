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
        NavigationStack(path: $path) {
            List {
                ForEach(groups, id: \.day) { g in
                    Section(g.day.formatted(.dateTime.year().month().day().weekday())) {
                        ForEach(g.orders) { o in
                            NavigationLink(value: o) { OrderRow(order: o) }
                                .swipeActions { Button("删除", role: .destructive) { confirmDelete = o } }
                        }
                    }
                }
            }
            .overlay { if orders.isEmpty { ContentUnavailableView("暂无入库单", systemImage: "shippingbox", description: Text("点右上角 + 新建入库单")) } }
            .searchable(text: $search, prompt: "单号 / 客户")
            .navigationTitle("入库单")
            .navigationDestination(for: InboundOrder.self) { o in OrderDetailView(order: o) { delete(o) } }
            .toolbar { Button { creating = true } label: { Image(systemName: "plus") } }
            .sheet(isPresented: $creating, onDismiss: { if let o = created { created = nil; path = [o] } }) { OrderForm(order: nil) { created = $0 } }
            .confirmationDialog("删除入库单及其全部货物和照片？", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                                titleVisibility: .visible, presenting: confirmDelete) { o in
                Button("删除", role: .destructive) { delete(o) }
            }
            .alert("删除失败", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(deleteError ?? "") }
        }
    }

    private func delete(_ o: InboundOrder) {
        do { try deleteOrder(o, in: context) } catch { deleteError = error.localizedDescription }
    }
}

private struct OrderRow: View {
    let order: InboundOrder
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(order.orderNo).font(.headline.monospacedDigit())
                Spacer()
                Text(order.receivedAt, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
            }
            Text(order.customer?.name ?? "（无客户）").font(.subheadline)
            Text("\(order.totalPieces) 件 · \(order.totalVolumeM3.m3) m³ · \(order.totalWeightKg.kg) kg")
                .font(.caption).foregroundStyle(.secondary)
        }
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
    @State private var confirmDelete = false
    @State private var error: String?

    var body: some View {
        List {
            Section("入库信息") {
                LabeledContent("单号", value: order.orderNo)
                LabeledContent("客户", value: order.customer.map { "\($0.name)（\($0.code)）" } ?? "—")
                LabeledContent("入库时间", value: order.receivedAt.formatted(date: .numeric, time: .shortened))
                LabeledContent("操作员", value: order.operatorName)
                if !order.note.isEmpty { LabeledContent("备注", value: order.note) }
            }
            Section("合计") {
                LabeledContent("件数", value: "\(order.totalPieces)")
                LabeledContent("总体积", value: "\(order.totalVolumeM3.m3) m³")
                LabeledContent("总重量", value: "\(order.totalWeightKg.kg) kg")
            }
            Section("货物（\(order.items.count)）") {
                ForEach(order.items.sorted { $0.createdAt < $1.createdAt }) { item in
                    Button { editingItem = item } label: { ItemRow(item: item) }.tint(.primary)
                        .swipeActions {
                            Button("删除", role: .destructive) {
                                do { try deleteItem(item, in: context) } catch { self.error = error.localizedDescription }
                            }
                        }
                }
                Button { addingItem = true } label: { Label("添加货物", systemImage: "plus") }
            }
            Section {
                Button("删除入库单", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(order.orderNo)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("编辑") { editingOrder = true } }
        .sheet(isPresented: $editingOrder) { OrderForm(order: order) }
        .sheet(isPresented: $addingItem) { ItemEditView(order: order, item: nil) }
        .sheet(item: $editingItem) { ItemEditView(order: order, item: $0) }
        .confirmationDialog("删除入库单及其全部货物和照片？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                // Pop first so this view never re-renders against a deleted model.
                dismiss()
                DispatchQueue.main.async { onDelete() }
            }
        }
        .alert("删除失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(error ?? "") }
    }
}

private struct ItemRow: View {
    let item: CargoItem
    var body: some View {
        HStack {
            if let f = item.photoFiles.first, let img = PhotoStore.thumbnail(f, side: 200) {
                Image(uiImage: img).resizable().scaledToFill().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name.isEmpty ? "（未命名）" : item.name).font(.headline)
                Text("\(item.lengthCm.cm)×\(item.widthCm.cm)×\(item.heightCm.cm) cm × \(item.quantity)")
                    .font(.caption)
                Text("\(item.totalVolumeM3.m3) m³ · \(item.weightKg.map { "\($0.kg) kg" } ?? "—") · \(item.methodLabel)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
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
                if let order { LabeledContent("单号", value: order.orderNo) }
                Picker("客户", selection: $customer) {
                    Text("请选择").tag(Customer?.none)
                    ForEach(customers) { Text("\($0.name)（\($0.code)）").tag(Optional($0)) }
                }
                DatePicker("入库时间", selection: $receivedAt)
                TextField("操作员", text: Binding(get: { operatorName ?? defaultOperator }, set: { operatorName = $0 }))
                TextField("备注", text: $note, axis: .vertical)
                if customers.isEmpty { Text("请先在「客户」页新建客户").foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(order == nil ? "新建入库单" : "编辑入库单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
            }
        }
    }

    private func save() {
        guard let customer else { error = "请选择客户"; return }
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
            } catch { self.error = "生成单号失败：\(error.localizedDescription)"; return }
        }
        do { try context.save() } catch { context.rollback(); self.error = "保存失败：\(error.localizedDescription)"; return }
        if let new { onCreated(new) }
        dismiss()
    }
}
