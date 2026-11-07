import Foundation
import WatchConnectivity
import UIKit

/// Bridges the player to the Watch companion: pushes now-playing state, receives remote commands.
@MainActor
final class PhoneSession: NSObject, WCSessionDelegate {
    static let shared = PhoneSession()

    private weak var model: AppModel?
    private var lastArtworkSongID: String?
    private var artworkData: Data?

    func attach(model: AppModel) {
        self.model = model
        model.player.onStateChange = { [weak self] in self?.push() }
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func push() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        var state = currentState()
        state[WatchKey.accent] = UserDefaults.standard.string(forKey: AccentTheme.storageKey) ?? AccentTheme.fallback.rawValue
        try? session.updateApplicationContext(state)
        if session.isReachable { session.sendMessage(state, replyHandler: nil, errorHandler: nil) }
    }

    private func currentState() -> [String: Any] {
        guard let model else { return [:] }
        let player = model.player
        // The Watch uses the same salted token so it can stream and download on its own.
        let creds = model.credentials.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        guard let song = player.current else {
            return [WatchKey.title: "Not Playing", WatchKey.isPlaying: false,
                    WatchKey.timestamp: Date().timeIntervalSince1970, WatchKey.credentials: creds]
        }
        if lastArtworkSongID != song.id || artworkData == nil {
            artworkData = player.artwork?.thumbnailJPEG(side: 160)
            lastArtworkSongID = artworkData == nil ? nil : song.id
        }
        var state: [String: Any] = [
            WatchKey.credentials: creds,
            WatchKey.title: song.title,
            WatchKey.artist: song.artist ?? "",
            WatchKey.album: song.album ?? "",
            WatchKey.isPlaying: player.isPlaying,
            WatchKey.duration: player.duration,
            WatchKey.elapsed: player.elapsed,
            WatchKey.timestamp: Date().timeIntervalSince1970,
            WatchKey.loved: model.isLoved(song.id),
            WatchKey.upNext: player.queue.dropFirst(player.index + 1).prefix(12).map { "\($0.title) — \($0.artist ?? "")" },
        ]
        if let artworkData { state[WatchKey.artwork] = artworkData }
        return state
    }

    private func handle(_ command: String, index: Int?) {
        guard let model, let cmd = WatchCommand(rawValue: command) else { return }
        let player = model.player
        switch cmd {
        case .togglePlay: player.togglePlayPause()
        case .next: player.next()
        case .previous: player.previous()
        case .love: model.toggleLoveCurrent()
        case .requestState: break
        case .shuffleFavourites: Task { await model.playFavouritesMix() }
        case .shuffleAll: Task { await model.playDiscoveryMix() }
        case .jump: if let index { player.jump(to: player.index + 1 + index) }
        }
        push()
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.push() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let cmd = message[WatchKey.command] as? String ?? ""
        let index = message[WatchKey.index] as? Int
        Task { @MainActor in self.handle(cmd, index: index) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let cmd = message[WatchKey.command] as? String ?? ""
        let index = message[WatchKey.index] as? Int
        Task { @MainActor in
            self.handle(cmd, index: index)
            replyHandler(self.currentState())
        }
    }
}
