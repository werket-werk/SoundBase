import Foundation

// The Mac app shares AppModel and Player with iOS. Google Cast and the Watch link are
// iPhone-only, so on macOS these stand-ins keep the shared code compiling unchanged.

@MainActor
final class CastManager {
    static let shared = CastManager()
    weak var player: Player?
    var isCasting: Bool { false }
    func configure() {}
    func load(_ songs: [Song], position: Double, autoplay: Bool) {}
    func play() {}
    func pause() {}
    func seek(to seconds: Double) {}
}

@MainActor
final class PhoneSession {
    static let shared = PhoneSession()
    func attach(model: AppModel) {}
    func push() {}
}
