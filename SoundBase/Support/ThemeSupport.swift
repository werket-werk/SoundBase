import SwiftUI
import CoreImage
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

extension UIImage {
    /// Average colours of the top and bottom halves, used for the "Artwork Colours" player background.
    func edgeColors() -> [Color]? {
        guard let input = CIImage(image: self) else { return nil }
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        let extent = input.extent
        let halves = [
            CGRect(x: extent.minX, y: extent.midY, width: extent.width, height: extent.height / 2),
            CGRect(x: extent.minX, y: extent.minY, width: extent.width, height: extent.height / 2),
        ]
        var colors: [Color] = []
        for rect in halves {
            guard let filter = CIFilter(name: "CIAreaAverage",
                                        parameters: [kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: rect)]),
                  let output = filter.outputImage else { return nil }
            var px = [UInt8](repeating: 0, count: 4)
            context.render(output, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: nil)
            colors.append(Color(red: Double(px[0]) / 255, green: Double(px[1]) / 255, blue: Double(px[2]) / 255))
        }
        return colors
    }
}
