import SwiftUI

struct SettingsView: View {
    @AppStorage("defaultOperator") private var defaultOperator = ""
    /// Per-edge offset (cm) subtracted from LiDAR results; applied by Scan/ (P2). Calibrate with a known box.
    @AppStorage("calibrationOffsetCm") private var calibrationOffsetCm = 0.0
    /// SPEC §11 D4/D5: scan diagnostics + point-cloud review + scan logs (read by Scan/ScanView).
    @AppStorage("debugMode") private var debugMode = false
    @State private var logCount = 0
    @State private var confirmClear = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        Image("AppIconImage").resizable().scaledToFit().frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("入库量方").font(.title2.weight(.bold)).foregroundStyle(.brand)
                            Text("版本 \(version)").font(.num(.footnote)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                Section("操作员") {
                    TextField("默认操作员姓名", text: $defaultOperator)
                }
                Section {
                    HStack {
                        Text("每边偏置 (cm)")
                        TextField("0", value: $calibrationOffsetCm, format: .number)
                            .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing).font(.num(.body))
                    }
                } header: { Text("测量校准") } footer: {
                    Text("用已知尺寸的纸箱扫描，若每边偏大 1cm 则填 1。正数表示扣减。")
                }
                Section {
                    Toggle("调试模式", isOn: $debugMode)
                    LabeledContent("已保存调试数据") { Text("\(logCount) 次").font(.num(.body)) }
                    Button("清空调试数据", role: .destructive) { confirmClear = true }
                        .disabled(logCount == 0)
                        .confirmationDialog("删除全部 \(logCount) 次扫描调试数据？", isPresented: $confirmClear, titleVisibility: .visible) {
                            Button("清空", role: .destructive) { ScanLogStore.clear(); logCount = ScanLogStore.count }
                        }
                } header: { Text("开发者") } footer: {
                    Text("开启后扫描页显示诊断信息，完成时可查看 3D 点云，并把每次扫描的点云和参数保存到「文件」App 的本 App 目录（ScanLogs），用于离线调参。")
                }
                Section {
                    // Text(Image) not Label: Label as LabeledContent content stretched the row (~225pt) on iOS 26.
                    LabeledContent("LiDAR") {
                        Text("\(Image(systemName: lidarAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")) \(lidarAvailable ? "可用" : "不可用（手动录入）")")
                            .foregroundStyle(lidarAvailable ? Color.scanText : Color.warnText)
                    }
                }
            }
            .navigationTitle("设置")
            .onAppear { logCount = ScanLogStore.count }
        }
    }
}
