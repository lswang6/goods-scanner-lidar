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
                            StatCard(icon: "doc.text", value: "\(today.count)", unit: "单", label: "今日入库")
                            StatCard(icon: "shippingbox", value: "\(today.reduce(0) { $0 + $1.totalPieces })", unit: "件", label: "今日件数")
                            StatCard(icon: "cube", value: today.reduce(0) { $0 + $1.totalVolumeM3 }.m3, unit: "m³", label: "今日体积")
                        }
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    }
                }
                ForEach(groups, id: \.day) { g in
                    Section(g.day.formatted(.dateTime.year().month().day().weekday())) {
                        ForEach(g.orders) { o in
                            NavigationLink(value: o) { OrderRow(order: o) }
                                .swipeActions { Button("删除", role: .destructive) { confirmDelete = o } }
                        }
                    }
                }
            }
            .listSectionSpacing(16)
            .overlay {
                if orders.isEmpty {
                    EmptyState(image: "EmptyOrders", title: "暂无入库单", message: "货物到仓后新建入库单，逐件扫描或录入尺寸",
                               action: ("新建入库", { creating = true }))
                }
            }
            .searchable(text: $search, prompt: "单号 / 客户")
            .navigationTitle("入库单")
            .navigationDestination(for: InboundOrder.self) { o in OrderDetailView(order: o) { delete(o) } }
            .toolbar {
                Button { creating = true } label: { Label("新建入库", systemImage: "plus").labelStyle(.titleAndIcon) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(.accent)
            }
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
        HStack(spacing: 12) {
            IconTile(systemName: "shippingbox.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text(order.orderNo).font(.headline.monospacedDigit())
                // Time lives in the trailing column so the customer name gets the full width.
                Text(order.customer?.name ?? "（无客户）")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                NumText(value: order.totalVolumeM3.m3, unit: "m³", style: .headline)
                Text("\(order.totalPieces) 件 · " + order.receivedAt.formatted(.verbatim(
                    "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
                    timeZone: .current, calendar: .current)))
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

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(order.orderNo).font(.num(.title2)).foregroundStyle(.brand)
                    Label(order.customer.map { "\($0.name)（\($0.code)）" } ?? "（无客户）", systemImage: "person.fill")
                    Label(order.receivedAt.formatted(date: .numeric, time: .shortened), systemImage: "clock")
                    if !order.operatorName.isEmpty { Label(order.operatorName, systemImage: "person.badge.key") }
                    if !order.note.isEmpty { Label(order.note, systemImage: "note.text") }
                }
                .font(.subheadline)
                .padding(.vertical, 4)
            }
            Section {
                HStack(spacing: 8) {
                    StatCard(icon: "shippingbox", value: "\(order.totalPieces)", unit: "件", label: "件数")
                    StatCard(icon: "cube", value: order.totalVolumeM3.m3, unit: "m³", label: "总体积")
                    StatCard(icon: "scalemass", value: order.totalWeightKg.kg, unit: "kg", label: "总重量")
                }
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
            Section("货物（\(order.items.count)）") {
                ForEach(order.items.sorted { $0.createdAt < $1.createdAt }) { item in
                    ItemRow(item: item, onEdit: { editingItem = item },
                            onPhoto: { viewing = PhotoSelection(files: item.photoFiles, start: 0) })
                        .swipeActions {
                            Button("删除", role: .destructive) {
                                do { try deleteItem(item, in: context) } catch { self.error = error.localizedDescription }
                            }
                        }
                }
                if order.items.isEmpty { Text("还没有货物，点下方「添加货物」").foregroundStyle(.secondary) }
            }
            Section {
                Button("删除入库单", role: .destructive) { confirmDelete = true }
            }
        }
        .listSectionSpacing(16)
        .safeAreaInset(edge: .bottom) {
            Button { addingItem = true } label: { Label("添加货物", systemImage: "plus") }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.bar)
        }
        .navigationTitle(order.orderNo)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("编辑") { editingOrder = true } }
        .sheet(isPresented: $editingOrder) { OrderForm(order: order) }
        .sheet(isPresented: $addingItem) { ItemEditView(order: order, item: nil) }
        .sheet(item: $editingItem) { ItemEditView(order: order, item: $0) }
        .fullScreenCover(item: $viewing) { PhotoViewer($0) }
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
                    .buttonStyle(.plain).accessibilityLabel("查看照片")
            }
            Button(action: onEdit) {
                HStack(spacing: 12) {
                    if item.photoFiles.isEmpty { thumb(nil) }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(item.name.isEmpty ? "（未命名）" : item.name).font(.headline).lineLimit(1)
                            if item.method == "lidar" { Image(systemName: "viewfinder").font(.caption).foregroundStyle(.scanText) }
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
