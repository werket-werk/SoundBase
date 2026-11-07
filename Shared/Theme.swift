import SwiftUI

/// Accent colours offered in Settings. Shared so the Watch can match the iPhone.
enum AccentTheme: String, CaseIterable, Identifiable {
    case pink, red, orange, amber, green, mint, teal, blue, indigo, purple, graphite

    static let storageKey = "accentTheme"
    static let fallback: AccentTheme = .pink

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    var hex: UInt32 {
        switch self {
        case .pink: 0xFA2D48
        case .red: 0xFF3B30
        case .orange: 0xFF9500
        case .amber: 0xE0A100
        case .green: 0x34C759
        case .mint: 0x00C7BE
        case .teal: 0x30B0C7
        case .blue: 0x007AFF
        case .indigo: 0x5856D6
        case .purple: 0xAF52DE
        case .graphite: 0x8E8E93
        }
    }

    var color: Color { Color(hex: hex) }

    static func from(_ raw: String?) -> AccentTheme { raw.flatMap(AccentTheme.init(rawValue:)) ?? fallback }
}

/// Light / Dark / follow the system.
enum AppearanceMode: Int, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appearanceMode"

    var id: Int { rawValue }
    var name: String { ["System", "Light", "Dark"][rawValue] }
    var colorScheme: ColorScheme? { [nil, .light, .dark][rawValue] }
}

/// How the full-screen player's background is drawn.
enum NowPlayingStyle: Int, CaseIterable, Identifiable {
    case blurredArtwork, artworkColours, black

    static let storageKey = "nowPlayingStyle"

    var id: Int { rawValue }
    var name: String { ["Blurred Artwork", "Artwork Colours", "Black"][rawValue] }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
