/// 调试模式 / 强制相机模式 / scan logs exist only in Debug builds. Release (App Store) builds hide their settings and
/// ignore any stored values, so a release user can never end up in a debug or forced-camera state.
enum DebugTools {
    #if DEBUG
    static let available = true
    #else
    static let available = false
    #endif
}
