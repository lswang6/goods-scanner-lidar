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
                            Text("\(c.orders.count) orders").font(.num(.caption)).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .tint(.primary)
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            if c.orders.isEmpty { context.delete(c); try? context.save() } else { blockedDelete = c }
                        }
                    }
                }
            }
            .overlay {
                if customers.isEmpty {
                    EmptyState(image: "EmptyCustomers", title: "No customers yet", message: "Add customers first so you can assign them to inbound orders.",
                               action: ("New Customer", { creating = true }))
                }
            }
            .searchable(text: $search, prompt: "Name / Code / Contact / Phone")
            .navigationTitle("Customers")
            .toolbar {
                Button { creating = true } label: { Label("New Customer", systemImage: "plus").labelStyle(.titleAndIcon) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(.accent)
            }
            .sheet(isPresented: $creating) { CustomerForm(customer: nil) }
            .sheet(item: $editing) { CustomerForm(customer: $0) }
            .alert("Cannot Delete", isPresented: Binding(get: { blockedDelete != nil }, set: { if !$0 { blockedDelete = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Customer “\(blockedDelete?.name ?? "")” has \(blockedDelete?.orders.count ?? 0) inbound orders. Delete them first.")
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
                    TextField("Customer Code (unique)", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    TextField("Customer Name", text: $name)
                }
                if let error { Text(error).foregroundStyle(.red) }
                Section {
                    TextField("Contact", text: $contact)
                    TextField("Phone", text: $phone).keyboardType(.phonePad)
                    TextField("Address", text: $address)
                    TextField("Note", text: $note, axis: .vertical)
                }
            }
            .navigationTitle(customer == nil ? "New Customer" : "Edit Customer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
        }
    }

    private func save() {
        func t(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        let c = t(code), n = t(name)
        guard !c.isEmpty, !n.isEmpty else { error = String(localized: "Customer code and name are required."); return }
        // Case-insensitive + trimmed: `.unique` would otherwise upsert (silently overwrite) on an exact clash,
        // and "c001"/"C001" would both be allowed. Customer counts are small, so compare in memory.
        guard let all = try? context.fetch(FetchDescriptor<Customer>()) else { error = String(localized: "Couldn’t load customers. Please try again."); return }
        if all.contains(where: { t($0.code).caseInsensitiveCompare(c) == .orderedSame && $0.persistentModelID != customer?.persistentModelID }) {
            error = String(localized: "Customer code “\(c)” already exists."); return
        }
        let target = customer ?? Customer(code: c, name: n)
        if customer == nil { context.insert(target) }
        target.code = c; target.name = n; target.contact = t(contact); target.phone = t(phone); target.address = t(address); target.note = t(note)
        do { try context.save() } catch { context.rollback(); self.error = String(localized: "Save failed: \(error.localizedDescription)"); return }
        dismiss()
    }
}
