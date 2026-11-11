import AppKit
import Foundation

@MainActor
final class CastManager {
    static let shared = CastManager()
    weak var player: Player?
    var isCasting: Bool { false }
    func configure() {}
    func load(_ songs: [Song], startingAt: Int, position: Double, autoplay: Bool) {}
    func play() {}
    func pause() {}
    func seek(to seconds: Double) {}
}

/// Publishes the Mac player to the iPhone and handles commands relayed from the Watch.
@MainActor
final class PhoneSession {
    static let shared = PhoneSession()
    private weak var model: AppModel?
    private var endpoint: PlaybackEndpoint?
    private var artworkID: String?
    private var artworkData: Data?

    func attach(model: AppModel) {
        self.model = model
        endpoint = PlaybackEndpoint(player: model.player)
        model.player.onStateChange = { [weak self] in self?.push() }
        let nearby = NearbyPlayback.shared
        nearby.onChange = { [weak self] in self?.push() }
        nearby.handle = { [weak self] message in await self?.handle(message) ?? [:] }
        nearby.start()
    }

    func push() {
        guard NearbyPlayback.shared.connected, model != nil else { return }
        NearbyPlayback.shared.publish(state())
    }

    private func state() -> [String: Any] {
        guard let model else { return [:] }
        var state = model.playbackState()
        state[WatchKey.account] = model.playbackAccount
        if let song = model.player.current {
            if artworkID != song.id || artworkData == nil, let image = model.player.artwork {
                let thumbnail = NSImage(size: NSSize(width: 160, height: 160), flipped: false) { rect in
                    image.draw(in: rect)
                    return true
                }
                artworkData = thumbnail.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.6])
                artworkID = song.id
            }
            if artworkID == song.id { state[WatchKey.artwork] = artworkData }
        }
        return state
    }

    private func handle(_ message: [String: Any]) async -> [String: Any] {
        guard let model, let account = model.playbackAccount, message[WatchKey.account] as? String == account,
              let raw = message[WatchKey.command] as? String, let command = WatchCommand(rawValue: raw) else {
            return [WatchKey.success: false]
        }
        if let result = await endpoint?.handle(command, message) {
            var reply = result
            reply["state"] = state()
            push()
            return reply
        }
        model.handlePlaybackControl(command, index: message[WatchKey.index] as? Int)
        push()
        return state()
    }
}
