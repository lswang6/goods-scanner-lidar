import SwiftUI
import UIKit

// DESIGN.md §1: the single home for design tokens and shared components.

extension ShapeStyle where Self == Color {
    static var brand: Color { Color(light: 0x1F3A5F, dark: 0x8FB3E0) }
    /// Foreground on a `brand` fill (brand turns light in dark mode).
    static var onBrand: Color { Color(light: 0xFFFFFF, dark: 0x10233D) }
    static var accent: Color { Color(light: 0xFF7A1A, dark: 0xFF8F3D) }
    static var scan: Color { Color(light: 0x22C55E, dark: 0x34D399) }
    static var warn: Color { Color(light: 0xF59E0B, dark: 0xFBBF24) }
    /// Text/small-icon variants of scan/accent/warn: AA >= 4.5:1 on surface in light and dark.
    /// Keep the plain tokens for fills, strokes and the AR overlay.
    static var scanText: Color { Color(light: 0x15803D, dark: 0x34D399) }
    static var accentText: Color { Color(light: 0xC2410C, dark: 0xFF8F3D) }
    static var warnText: Color { Color(light: 0xB45309, dark: 0xFBBF24) }
    static var danger: Color { .red }
    static var surface: Color { Color(uiColor: .secondarySystemGroupedBackground) }
    static var canvas: Color { Color(uiColor: .systemGroupedBackground) }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        func ui(_ v: UInt32) -> UIColor {
            UIColor(red: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
    }
}

extension Font {
    /// All dimension / volume / weight numbers: rounded, semibold, monospaced digits.
    static func num(_ style: Font.TextStyle = .title2) -> Font {
        .system(style, design: .rounded).weight(.semibold).monospacedDigit()
    }
}

enum Radius {
    static let card: CGFloat = 16, button: CGFloat = 14, tag: CGFloat = 8
}

/// Number + smaller secondary unit, e.g. "1.234 m³".
struct NumText: View {
    let value: String
    let unit: String
    var style: Font.TextStyle = .title2
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value).font(.num(style))
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
        .lineLimit(1).minimumScaleFactor(0.6)
    }
}

/// Brand-tinted SF Symbol tile used as list-row leading icon.
struct IconTile: View {
    let systemName: String
    var size: CGFloat = 40
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.onBrand)
            .frame(width: size, height: size)
            .background(Color.brand, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
    }
}

struct StatCard: View {
    let icon: String
    let value: String
    let unit: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.brand)
                .frame(width: 28, height: 28)
                .background(Color.brand.opacity(0.15), in: Circle())
            NumText(value: value, unit: unit)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

/// `60 × 45 × 20 cm` capsule (`Ø26 × 25.5 cm` for cylinders), followed by the shape chip.
struct DimsBadge: View {
    let l: Double, w: Double, h: Double
    var shape = "box"
    var body: some View {
        HStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(CargoItem.dimsText(l, w, h, shape: shape)).font(.num(.subheadline))
                Text("cm").font(.caption2).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            ShapeChip(shape: shape)
        }
    }
}

/// SPEC §13 E4: 箱体 / 圆柱 / 异形 tag with its SF Symbol.
struct ShapeChip: View {
    let shape: String
    var body: some View {
        // Text(Image) not Label: see SettingsView LiDAR row.
        Text("\(Image(systemName: CargoItem.shapeIcon(shape))) \(CargoItem.shapeLabel(shape))")
            .font(.caption.weight(.semibold)).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(isEnabled ? Color.accent : Color.gray.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed) { _, pressed in pressed }
    }
}

/// Compact neutral companion to `PrimaryButtonStyle` (same height/shape, hugs its label).
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.primary)
            .padding(.horizontal, 20)
            .frame(minWidth: 44, minHeight: 52)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct EmptyState: View {
    let image: String
    let title: String
    let message: String
    var action: (label: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(image).resizable().scaledToFit().frame(maxWidth: 280, maxHeight: 180)  // assets range ~2.2:1 to ~0.9:1
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let action {
                Button(action.label, action: action.run).buttonStyle(PrimaryButtonStyle()).padding(.top, 12)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas)
    }
}
