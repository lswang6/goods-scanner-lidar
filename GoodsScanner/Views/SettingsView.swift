import SwiftUI

struct SettingsView: View {
    @AppStorage("defaultOperator") private var defaultOperator = ""
    /// Per-edge offset (cm) subtracted from LiDAR results; applied by Scan/ (P2). Calibrate with a known box.
    @AppStorage("calibrationOffsetCm") private var calibrationOffsetCm = 0.0

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
                    // Text(Image) not Label: Label as LabeledContent content stretched the row (~225pt) on iOS 26.
                    LabeledContent("LiDAR") {
                        Text("\(Image(systemName: lidarAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")) \(lidarAvailable ? "可用" : "不可用（手动录入）")")
                            .foregroundStyle(lidarAvailable ? Color.scanText : Color.warnText)
                    }
                }
            }
            .navigationTitle("设置")
        }
    }
}
