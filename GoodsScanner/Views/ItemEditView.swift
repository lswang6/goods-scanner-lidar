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
    var shape = "box"  // CargoItem.shape values
    var method = "lidar"  // CargoItem.method: "lidar" | "camera"
}

extension ScanResult {
    /// BoxEstimate is in meters; the app stores cm (A7).
    /// Cylinder: width = length = diameter (a median over mixed-shape samples may not keep them equal).
    init(_ e: BoxEstimate, confidence: Double, photos: [UIImage]) {
        self.init(lengthCm: Double(e.length * 100), widthCm: Double((e.shape == .cylinder ? e.length : e.width) * 100),
                  heightCm: Double(e.height * 100),
                  confidence: confidence, photos: photos, shape: e.shape.rawValue)
    }
}

var lidarAvailable: Bool {
    #if targetEnvironment(simulator)
    return false
    #else
    return ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    #endif
}

/// SPEC §14 camera-only scan: any world-tracking device. Used without LiDAR, or with 设置 → 强制相机模式.
var cameraScanAvailable: Bool {
    #if targetEnvironment(simulator)
    return false
    #else
    return ARWorldTrackingConfiguration.isSupported
    #endif
}

/// Debug launch argument `-scanGuidanceDemo` (add `-lidar` for the LiDAR cycle): without AR (simulator), the scan
/// button opens ScanGuidanceDemo so every guidance stage can be screenshotted. Always false in Release.
var scanGuidanceDemo: Bool {
    #if DEBUG
    return CommandLine.arguments.contains("-scanGuidanceDemo")
    #else
    return false
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
    @State private var shape: String
    @State private var addedPhotos: Set<String> = []
    @State private var showCamera = false
    @State private var showScan = false
    @AppStorage("forceCameraMode") private var storedForceCamera = false
    /// Release builds ignore the stored debug switch (same rule as ScanView).
    private var forceCamera: Bool { storedForceCamera && DebugTools.available }
    @State private var viewing: PhotoSelection?
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
        _weight = State(initialValue: item?.weightKg.map(\.kgText) ?? "")
        _photos = State(initialValue: item?.photoFiles ?? [])
        _method = State(initialValue: item?.method ?? "manual")
        _confidence = State(initialValue: item?.confidence)
        _shape = State(initialValue: item?.shape ?? "box")
    }

    private var isCylinder: Bool { shape == "cylinder" }
    /// Bounding-box volume (E4); a cylinder's width is its diameter.
    private var unitVolume: Double { CargoItem.volumeM3(length ?? 0, (isCylinder ? length : width) ?? 0, height ?? 0) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        let camera = !lidarAvailable || forceCamera
                        Button { showScan = true } label: {
                            Label(camera ? "Camera walk-around scan" : "LiDAR walk-around scan", systemImage: camera ? "camera.viewfinder" : "viewfinder")
                        }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(!cameraScanAvailable && !scanGuidanceDemo)
                        if !cameraScanAvailable { Text("AR scanning isn't supported on this device. Enter the size by hand.").font(.caption).foregroundStyle(.secondary) }
                        else if camera { Text("Camera measurement, about ±3 cm").font(.caption).foregroundStyle(.secondary) }
                    }
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                Section {
                    TextField("Name / note", text: $name)
                }
                Section("Size (cm)") {
                    Picker("Shape", selection: $shape) {
                        ForEach(CargoItem.shapes, id: \.self) { Text(CargoItem.shapeLabel($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    HStack(spacing: 8) {
                        if isCylinder {
                            dimField("Diameter", $length)  // width follows length on save (L = W = diameter)
                        } else {
                            dimField("Length", $length)
                            dimField("Width", $width)
                        }
                        dimField("Height", $height)
                    }
                    Stepper(value: $quantity, in: 1...99_999) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("Quantity")
                            Text("\(quantity)").font(.num(.body))
                        }
                    }
                    HStack {
                        Text("Weight (kg)")
                        TextField("Optional, total for this line", text: $weight).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .font(.num(.body))
                    }
                }
                Section("Volume") {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Total").font(.caption).foregroundStyle(.secondary)
                            NumText(value: (unitVolume * Double(quantity)).m3Text, unit: "m³", style: .largeTitle)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Per item").font(.caption).foregroundStyle(.secondary)
                            NumText(value: unitVolume.m3Text, unit: "m³", style: .headline)
                        }
                    }
                    LabeledContent("Method") {
                        // Text(Image) not Label: see SettingsView LiDAR row.
                        Text("\(Image(systemName: CargoItem.methodIcon(method))) \(CargoItem.methodLabel(method))")
                            .foregroundStyle(method == "manual" ? .secondary : Color.scanText)
                    }
                    if let confidence { LabeledContent("Confidence", value: confidence.formatted(.percent.precision(.fractionLength(0)))) }
                }
                Section("Photos (\(photos.count))") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(photos, id: \.self) { f in
                                ZStack(alignment: .topTrailing) {
                                    // Pending (unsaved) photos are already on disk, so the viewer reads them like saved ones.
                                    Button { viewing = PhotoSelection(files: photos, start: photos.firstIndex(of: f) ?? 0) } label: {
                                        Group {
                                            if let img = PhotoStore.thumbnail(f, side: 240) { Image(uiImage: img).resizable().scaledToFill() }
                                            else { Color.gray.opacity(0.2) }
                                        }
                                        .frame(width: 88, height: 88).clipShape(RoundedRectangle(cornerRadius: Radius.tag, style: .continuous))
                                    }
                                    .buttonStyle(.borderless).accessibilityLabel("View photo")
                                    Button { removePhoto(f) } label: {
                                        Image(systemName: "xmark.circle.fill").font(.body).symbolRenderingMode(.palette).foregroundStyle(.white, .red)
                                    }
                                    .buttonStyle(.borderless).padding(4).accessibilityLabel("Delete photo")
                                }
                            }
                            Group {
                                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                                    Button { showCamera = true } label: { addTile("Take Photo", "camera") }
                                } else {
                                    PhotosPicker(selection: $pickerItems, matching: .images) { addTile("Library", "photo") }
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(item == nil ? "Add Item" : "Edit Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { if let img = $0 { addPhoto(img) } }.ignoresSafeArea()
            }
            .fullScreenCover(item: $viewing) { PhotoViewer($0) }
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

    private func dimField(_ label: LocalizedStringKey, _ value: Binding<Double?>) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("0", value: value, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.center)
                .font(.num(.title2))
                .frame(minHeight: 44)
                .background(Color.canvas, in: RoundedRectangle(cornerRadius: Radius.tag, style: .continuous))
        }
    }

    private func addTile(_ title: LocalizedStringKey, _ icon: String) -> some View {
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
        method = r.method; confidence = r.confidence; shape = r.shape
        r.photos.forEach(addPhoto)
    }

    private func addPhoto(_ img: UIImage) {
        guard let f = PhotoStore.save(img) else { error = String(localized: "Couldn't save the photo"); return }
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
        guard let l = length, let w = isCylinder ? length : width, let h = height, l > 0, w > 0, h > 0 else {
            error = isCylinder ? String(localized: "Diameter and height must be greater than 0")
                : String(localized: "Length, width and height must be greater than 0"); return
        }
        let trimmedWeight = weight.trimmingCharacters(in: .whitespaces)
        let kg = trimmedWeight.isEmpty ? nil : Double(trimmedWeight.replacingOccurrences(of: ",", with: "."))
        if !trimmedWeight.isEmpty && (kg == nil || kg! < 0) { error = String(localized: "Invalid weight"); return }
        let target = item ?? CargoItem()
        let removed = Set(target.photoFiles).subtracting(photos)
        target.name = name.trimmingCharacters(in: .whitespacesAndNewlines); target.lengthCm = l; target.widthCm = w; target.heightCm = h
        target.quantity = quantity; target.weightKg = kg; target.photoFiles = photos
        target.method = method; target.confidence = confidence; target.shape = shape
        if item == nil { context.insert(target); target.order = order }
        // Removed photos are deleted only after a successful save; on failure keep files and stay open.
        do { try context.save() } catch { context.rollback(); self.error = String(localized: "Save failed: \(error.localizedDescription)"); return }
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
