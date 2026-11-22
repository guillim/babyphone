import SwiftUI

/// The name shown to the user. It comes from the bundle so that renaming the app is one build setting.
enum AppInfo {
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? ""
}

/// Colours and type of the app. One dark theme, made for a bedroom at night.
enum Theme {
    static let background = Color(hex: 0x0F1524)
    /// The baby unit sits in a dark room all night, so its screen is nearly black.
    static let babyBackground = Color(hex: 0x070A12)
    static let card = Color(hex: 0x182038)
    static let border = Color(hex: 0x2A3350)
    static let text = Color(hex: 0xF4F1EA)
    static let secondaryText = Color(hex: 0xA9B1C6)
    static let accent = Color(hex: 0xF2B66D)
    static let onAccent = Color(hex: 0x1A1408)
    static let status = Color(hex: 0x6FD3B8)
    static let alert = Color(hex: 0xF28B7D)
    static let nightLight = Color(hex: 0xFFB35C)

    static let cornerRadius: CGFloat = 16
    /// Smallest size of anything the user taps.
    static let minimumTouchTarget: CGFloat = 44

    static func heading(_ style: Font.TextStyle) -> Font {
        .system(style, design: .rounded).weight(.heavy)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
