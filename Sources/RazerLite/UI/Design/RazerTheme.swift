import SwiftUI
import RazerLiteCore

struct RazerTheme {
    let scheme: ColorScheme
    var isDark: Bool { scheme == .dark }
    static let green = Color(red: 0.42, green: 0.88, blue: 0.25)
    var accent: Color { isDark ? Self.green : Color(red: 0.17, green: 0.48, blue: 0.12) }
    var canvas: Color { isDark ? Color(white: 0.075) : Color(white: 0.965) }
    var sidebar: Color { isDark ? Color(white: 0.095) : Color(white: 0.945) }
    var surface: Color { isDark ? Color(white: 0.115) : .white }
    var elevated: Color { isDark ? Color(white: 0.15) : Color(white: 0.96) }
    var line: Color { Color.primary.opacity(isDark ? 0.075 : 0.065) }
    var selected: Color { accent.opacity(isDark ? 0.10 : 0.075) }
}

struct SurfaceCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(20)
            .background(RazerTheme(scheme: scheme).surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(RazerTheme(scheme: scheme).line) }
    }
}

struct SmallBadge: View {
    let title: String
    var color: Color = .secondary
    var dot = false

    var body: some View {
        HStack(spacing: 5) {
            if dot { Circle().fill(color).frame(width: 5, height: 5) }
            Text(title).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 5)
        .background(color.opacity(0.085), in: Capsule())
    }
}

enum DevicePage: String, CaseIterable {
    case overview, controls, buttons, profiles, information
    func title(for device: DeviceInfo) -> String {
        switch self {
        case .overview: "总览"
        case .controls: device.presentation.isKeyboard ? "灯光" : "性能"
        case .buttons: "按键"
        case .profiles: "档案"
        case .information: "设备信息"
        }
    }
}

struct DevicePresentation {
    let name: String
    let subtitle: String
    let icon: String
    let isKeyboard: Bool
}

extension DeviceInfo {
    // Presentation only. Protocol selection remains exclusively in the core adapter catalog.
    var presentation: DevicePresentation {
        if isVirtual {
            return DevicePresentation(name: "虚拟 HID", subtitle: "Razer DriverKit", icon: "cpu", isKeyboard: false)
        }
        if vendorID == 0x1532, productID == 0x02D2 {
            return DevicePresentation(name: "BlackWidow V4", subtitle: "Low-profile TKL · HyperSpeed", icon: "keyboard", isKeyboard: true)
        }
        if vendorID == 0x1532, productID == 0x00E6 {
            return DevicePresentation(name: "Viper V4 Pro", subtitle: "HyperSpeed", icon: "computermouse", isKeyboard: false)
        }
        let displayName = modelReference?.name ?? product
        return DevicePresentation(name: displayName.replacingOccurrences(of: "Razer ", with: ""),
                                  subtitle: "\(kind.title) · \(transport)", icon: kind.symbol, isKeyboard: kind == .keyboard)
    }
}
