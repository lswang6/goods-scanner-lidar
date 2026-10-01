import SwiftUI
import SwiftData

struct CustomersView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Customer.code) private var customers: [Customer]
    @State private var search = ""
    @State private var editing: Customer?
    @State private var creating = false
    @State private var blockedDelete: Customer?

    private var filtered: [Customer] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return customers }
        return customers.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.code.localizedCaseInsensitiveContains(q)
            || $0.contact.localizedCaseInsensitiveContains(q) || $0.phone.contains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered) { c in
                    Button { editing = c } label: {
                        HStack(spacing: 12) {
                            Text(c.name.prefix(1))
                                .font(.headline).foregroundStyle(.onBrand)
                                .frame(width: 44, height: 44)
                                .background(Color.brand, in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(c.name).font(.headline).lineLimit(1)
                                    Text(c.code).font(.caption.monospaced().weight(.semibold)).foregroundStyle(.brand)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.tag, style: .continuous))
                                }
                                let sub = [c.contact, c.phone].filter { !$0.isEmpty }.joined(separator: " · ")
                                if !sub.isEmpty { Text(sub).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            Spacer(minLength: 0)
                            Text("\(c.orders.count) 单").font(.num(.caption)).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .tint(.primary)
                    .swipeActions {
                        Button("删除", role: .destructive) {
                            if c.orders.isEmpty { context.delete(c); try? context.save() } else { blockedDelete = c }
                        }
                    }
                }
            }
            .overlay {
                if customers.isEmpty {
                    EmptyState(image: "EmptyCustomers", title: "暂无客户", message: "先建客户档案，入库单才能选择客户",
                               action: ("新建客户", { creating = true }))
                }
            }
            .searchable(text: $search, prompt: "名称 / 代码 / 联系人 / 电话")
            .navigationTitle("客户")
            .toolbar {
                Button { creating = true } label: { Label("新建客户", systemImage: "plus").labelStyle(.titleAndIcon) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(.accent)
            }
            .sheet(isPresented: $creating) { CustomerForm(customer: nil) }
            .sheet(item: $editing) { CustomerForm(customer: $0) }
            .alert("无法删除", isPresented: Binding(get: { blockedDelete != nil }, set: { if !$0 { blockedDelete = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text("客户「\(blockedDelete?.name ?? "")」有 \(blockedDelete?.orders.count ?? 0) 张入库单，请先删除入库单。")
            }
        }
    }
}

struct CustomerForm: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let customer: Customer?
    @State private var code = ""
    @State private var name = ""
    @State private var contact = ""
    @State private var phone = ""
    @State private var address = ""
    @State private var note = ""
    @State private var error: String?

    init(customer: Customer?) {
        self.customer = customer
        _code = State(initialValue: customer?.code ?? "")
        _name = State(initialValue: customer?.name ?? "")
        _contact = State(initialValue: customer?.contact ?? "")
        _phone = State(initialValue: customer?.phone ?? "")
        _address = State(initialValue: customer?.address ?? "")
        _note = State(initialValue: customer?.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("客户代码（唯一）", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    TextField("客户名称", text: $name)
                }
                if let error { Text(error).foregroundStyle(.red) }
                Section {
                    TextField("联系人", text: $contact)
                    TextField("电话", text: $phone).keyboardType(.phonePad)
                    TextField("地址", text: $address)
                    TextField("备注", text: $note, axis: .vertical)
                }
            }
            .navigationTitle(customer == nil ? "新建客户" : "编辑客户")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
            }
        }
    }

    private func save() {
        func t(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let c = t(code), n = t(name)
        guard !c.isEmpty, !n.isEmpty else { error = "客户代码和名称必填"; return }
        // Case-insensitive + trimmed: `.unique` would otherwise upsert (silently overwrite) on an exact clash,
        // and "c001"/"C001" would both be allowed. Customer counts are small, so compare in memory.
        guard let all = try? context.fetch(FetchDescriptor<Customer>()) else { error = "读取客户失败，请重试"; return }
        if all.contains(where: { t($0.code).caseInsensitiveCompare(c) == .orderedSame && $0.persistentModelID != customer?.persistentModelID }) {
            error = "客户代码「\(c)」已存在"; return
        }
        let target = customer ?? Customer(code: c, name: n)
        if customer == nil { context.insert(target) }
        target.code = c; target.name = n; target.contact = t(contact); target.phone = t(phone); target.address = t(address); target.note = t(note)
        do { try context.save() } catch { context.rollback(); self.error = "保存失败：\(error.localizedDescription)"; return }
        dismiss()
    }
}
