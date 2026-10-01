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
                Section("操作员") {
                    TextField("默认操作员姓名", text: $defaultOperator)
                }
                Section {
                    HStack {
                        Text("每边偏置 (cm)")
                        TextField("0", value: $calibrationOffsetCm, format: .number)
                            .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("LiDAR", value: lidarAvailable ? "可用" : "不可用（手动录入）")
                } header: { Text("测量校准") } footer: {
                    Text("用已知尺寸的纸箱扫描，若每边偏大 1cm 则填 1。正数表示扣减。")
                }
                Section("关于") {
                    LabeledContent("版本", value: version)
                }
            }
            .navigationTitle("设置")
        }
    }
}
