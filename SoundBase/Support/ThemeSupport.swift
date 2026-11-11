import SwiftUI
import UIKit

enum AppIconSwitcher {
    static let matchKey = "iconMatchesAccent"

    static var matchesAccent: Bool {
        UserDefaults.standard.object(forKey: matchKey) as? Bool ?? true
    }

    /// Pink uses the primary icon; every other accent has an `AppIcon-<Name>` alternate.
    static func iconName(for accent: AccentTheme) -> String? {
        accent == .pink ? nil : "AppIcon-\(accent.name)"
    }

    @MainActor
    static func apply(_ accent: AccentTheme) {
        let app = UIApplication.shared
        guard app.supportsAlternateIcons else { return }
        let target = matchesAccent ? iconName(for: accent) : nil
        guard app.alternateIconName != target else { return }
        app.setAlternateIconName(target) { _ in }
    }
}
