import SwiftUI

struct SettingsView: View {
    @AppStorage("defaultOperator") private var defaultOperator = ""
    /// Per-edge offset (cm) subtracted from LiDAR results; applied by Scan/ (P2). Calibrate with a known box.
    @AppStorage("calibrationOffsetCm") private var calibrationOffsetCm = 0.0
    /// SPEC §11 D4/D5: scan diagnostics + point-cloud review + scan logs (read by Scan/ScanView).
    @AppStorage("debugMode") private var debugMode = false
    /// SPEC §14: LiDAR devices scan with the camera-only pipeline (testing the non-LiDAR path).
    @AppStorage("forceCameraMode") private var forceCameraMode = false
    @State private var logCount = 0
    @State private var confirmClear = false
    @State private var showTutorial = false

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
                            Text("Cargo Measure").font(.title2.weight(.bold)).foregroundStyle(.brand)
                            Text("Version \(version)").font(.num(.footnote)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                Section("Operator") {
                    TextField("Default Operator Name", text: $defaultOperator)
                }
                Section {
                    HStack {
                        Text("Offset per Side (cm)")
                        TextField("0", value: $calibrationOffsetCm, format: .number)
                            .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing).font(.num(.body))
                    }
                } header: { Text("Measurement Calibration") } footer: {
                    Text("Scan a box of known size. If each side reads 1 cm too large, enter 1. Positive values are subtracted.")
                }
                if DebugTools.available { Section {
                    Toggle("Debug Mode", isOn: $debugMode)
                    if lidarAvailable { Toggle("Force Camera Mode", isOn: $forceCameraMode) }
                    LabeledContent("Saved Debug Data") { Text("\(logCount) scans").font(.num(.body)) }
                    Button("Clear Debug Data", role: .destructive) { confirmClear = true }
                        .disabled(logCount == 0)
                        .confirmationDialog("Delete debug data for all \(logCount) scans?", isPresented: $confirmClear, titleVisibility: .visible) {
                            Button("Clear", role: .destructive) { ScanLogStore.clear(); logCount = ScanLogStore.count }
                        }
                } header: { Text("Developer") } footer: {
                    Text("Shows diagnostics on the scan screen, lets you review the 3D point cloud when a scan finishes, and saves each scan’s point cloud and parameters to this app’s folder (ScanLogs) in the Files app for offline tuning. Force Camera Mode: measure from the camera image only, without LiDAR (to test the flow for devices without LiDAR).")
                } }
                Section {
                    // Text(Image) not Label: Label as LabeledContent content stretched the row (~225pt) on iOS 26.
                    LabeledContent("LiDAR") {
                        let icon = Image(systemName: lidarAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        Group {
                            if lidarAvailable { Text("\(icon) Available") }
                            else if cameraScanAvailable { Text("\(icon) Not available (camera measurement)") }
                            else { Text("\(icon) Not available (manual entry)") }
                        }
                            .foregroundStyle(lidarAvailable ? Color.scanText : Color.warnText)
                    }
                }
                Section("About") {
                    NavigationLink("Disclaimer") { DisclaimerView() }
                    Button("View tutorial") { showTutorial = true }
                }
            }
            .navigationTitle("Settings")
            .onAppear { logCount = ScanLogStore.count }
            .fullScreenCover(isPresented: $showTutorial) { OnboardingView(replay: true) }
        }
    }
}
