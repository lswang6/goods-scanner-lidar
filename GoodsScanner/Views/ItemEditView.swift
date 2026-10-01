import SwiftUI
import SwiftData
import PhotosUI
import ARKit
import BoxMeasureKit

/// What a LiDAR scan hands back to the item form. P2's `ScanView(onResult:)` produces this.
struct ScanResult {
    var lengthCm: Double
    var widthCm: Double
    var heightCm: Double
    var confidence: Double
    var photos: [UIImage]
}

extension ScanResult {
    /// BoxEstimate is in meters; the app stores cm (A7).
    init(_ e: BoxEstimate, confidence: Double, photos: [UIImage]) {
        self.init(lengthCm: Double(e.length * 100), widthCm: Double(e.width * 100), heightCm: Double(e.height * 100),
                  confidence: confidence, photos: photos)
    }
}

var lidarAvailable: Bool {
    #if targetEnvironment(simulator)
    return false
    #else
    return ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    #endif
}

struct ItemEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let order: InboundOrder
    let item: CargoItem?

    @State private var name: String
    @State private var length: Double?
    @State private var width: Double?
    @State private var height: Double?
    @State private var quantity: Int
    @State private var weight: String
    @State private var photos: [String]
    @State private var method: String
    @State private var confidence: Double?
    @State private var addedPhotos: Set<String> = []
    @State private var showCamera = false
    @State private var showScan = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var error: String?

    init(order: InboundOrder, item: CargoItem?) {
        self.order = order
        self.item = item
        _name = State(initialValue: item?.name ?? "")
        _length = State(initialValue: item?.lengthCm)
        _width = State(initialValue: item?.widthCm)
        _height = State(initialValue: item?.heightCm)
        _quantity = State(initialValue: item?.quantity ?? 1)
        _weight = State(initialValue: item?.weightKg.map(\.kg) ?? "")
        _photos = State(initialValue: item?.photoFiles ?? [])
        _method = State(initialValue: item?.method ?? "manual")
        _confidence = State(initialValue: item?.confidence)
    }

    private var unitVolume: Double { CargoItem.volumeM3(length ?? 0, width ?? 0, height ?? 0) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        Button { showScan = true } label: { Label("LiDAR 环绕扫描", systemImage: "viewfinder") }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(!lidarAvailable)
                        if !lidarAvailable { Text("本机无 LiDAR，请手动录入尺寸").font(.caption).foregroundStyle(.secondary) }
                    }
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                Section {
                    TextField("品名 / 备注", text: $name)
                }
                Section("尺寸 (cm)") {
                    HStack(spacing: 8) {
                        dimField("长", $length)
                        dimField("宽", $width)
                        dimField("高", $height)
                    }
                    Stepper(value: $quantity, in: 1...99_999) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("件数")
                            Text("\(quantity)").font(.num(.body))
                        }
                    }
                    HStack {
                        Text("重量 (kg)")
                        TextField("选填，本行合计", text: $weight).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .font(.num(.body))
                    }
                }
                Section("体积") {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("合计").font(.caption).foregroundStyle(.secondary)
                            NumText(value: (unitVolume * Double(quantity)).m3, unit: "m³", style: .largeTitle)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("单件").font(.caption).foregroundStyle(.secondary)
                            NumText(value: unitVolume.m3, unit: "m³", style: .headline)
                        }
                    }
                    LabeledContent("测量方式") {
                        // Text(Image) not Label: see SettingsView LiDAR row.
                        Text("\(Image(systemName: method == "lidar" ? "viewfinder" : "hand.point.up.left")) \(method == "lidar" ? "LiDAR" : "手动")")
                            .foregroundStyle(method == "lidar" ? Color.scanText : .secondary)
                    }
                    if let confidence { LabeledContent("置信度", value: confidence.formatted(.percent.precision(.fractionLength(0)))) }
                }
                Section("照片（\(photos.count)）") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(photos, id: \.self) { f in
                                ZStack(alignment: .topTrailing) {
                                    Group {
                                        if let img = PhotoStore.thumbnail(f, side: 240) { Image(uiImage: img).resizable().scaledToFill() }
                                        else { Color.gray.opacity(0.2) }
                                    }
                                    .frame(width: 88, height: 88).clipShape(RoundedRectangle(cornerRadius: Radius.tag, style: .continuous))
                                    Button { removePhoto(f) } label: {
                                        Image(systemName: "xmark.circle.fill").font(.title3).symbolRenderingMode(.palette).foregroundStyle(.white, .red)
                                    }
                                    .buttonStyle(.borderless).padding(2)
                                }
                            }
                            Group {
                                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                                    Button { showCamera = true } label: { addTile("拍照", "camera") }
                                } else {
                                    PhotosPicker(selection: $pickerItems, matching: .images) { addTile("相册", "photo") }
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(item == nil ? "添加货物" : "编辑货物")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: cancel) }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { if let img = $0 { addPhoto(img) } }.ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $showScan) {
                ScanView(onResult: { apply($0); showScan = false })
            }
            .onChange(of: pickerItems) { _, items in
                Task {
                    for i in items {
                        if let data = try? await i.loadTransferable(type: Data.self), let img = UIImage(data: data) { addPhoto(img) }
                    }
                    pickerItems = []
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private func dimField(_ label: String, _ value: Binding<Double?>) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("0", value: value, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.center)
                .font(.num(.title2))
                .frame(minHeight: 44)
                .background(Color.canvas, in: RoundedRectangle(cornerRadius: Radius.tag, style: .continuous))
        }
    }

    private func addTile(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.title2)
            Text(title).font(.caption)
        }
        .foregroundStyle(.accentText)
        .frame(width: 88, height: 88)
        .background(Color.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.tag, style: .continuous))
    }

    func apply(_ r: ScanResult) {
        length = r.lengthCm; width = r.widthCm; height = r.heightCm
        method = "lidar"; confidence = r.confidence
        r.photos.forEach(addPhoto)
    }

    private func addPhoto(_ img: UIImage) {
        guard let f = PhotoStore.save(img) else { error = "照片保存失败"; return }
        photos.append(f); addedPhotos.insert(f)
    }

    private func removePhoto(_ f: String) {
        photos.removeAll { $0 == f }
        // Photos added in this session are discarded immediately; pre-existing ones only on save.
        if addedPhotos.remove(f) != nil { PhotoStore.delete([f]) }
    }

    private func cancel() {
        PhotoStore.delete(Array(addedPhotos))
        dismiss()
    }

    private func save() {
        guard let l = length, let w = width, let h = height, l > 0, w > 0, h > 0 else { error = "长宽高必须大于 0"; return }
        let trimmedWeight = weight.trimmingCharacters(in: .whitespaces)
        let kg = trimmedWeight.isEmpty ? nil : Double(trimmedWeight.replacingOccurrences(of: ",", with: "."))
        if !trimmedWeight.isEmpty && (kg == nil || kg! < 0) { error = "重量格式不正确"; return }
        let target = item ?? CargoItem()
        let removed = Set(target.photoFiles).subtracting(photos)
        target.name = name.trimmingCharacters(in: .whitespacesAndNewlines); target.lengthCm = l; target.widthCm = w; target.heightCm = h
        target.quantity = quantity; target.weightKg = kg; target.photoFiles = photos
        target.method = method; target.confidence = confidence
        if item == nil { context.insert(target); target.order = order }
        // Removed photos are deleted only after a successful save; on failure keep files and stay open.
        do { try context.save() } catch { context.rollback(); self.error = "保存失败：\(error.localizedDescription)"; return }
        PhotoStore.delete(Array(removed))
        dismiss()
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.onImage(info[.originalImage] as? UIImage)
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
