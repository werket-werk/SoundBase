import Foundation
import Observation
import WatchConnectivity
import UIKit

@Observable @MainActor
final class PhoneSession: NSObject, WCSessionDelegate {
    static let shared = PhoneSession()

    private weak var model: AppModel?
    private var endpoint: PlaybackEndpoint?
    private var lastArtworkSongID: String?
    private var artworkData: Data?
    private var macAccount: String?
    private var macState: [String: Any] = [:]
    private var remoteDevice: PlaybackDevice = .phone
    private var wasPhonePlaying = false
    private(set) var switchingDevices = false
    private(set) var deviceIssue: String?

    var macPlaybackTitle: String? {
        guard remoteDevice == .mac, macAvailable, macState[WatchKey.songID] != nil else { return nil }
        return macState[WatchKey.title] as? String
    }

    func attach(model: AppModel) {
        self.model = model
        endpoint = PlaybackEndpoint(player: model.player)
        model.player.onStateChange = { [weak self, weak model] in
            guard let self else { return }
            let phonePlaying = model?.player.isPlaying == true
            let started = phonePlaying && !self.wasPhonePlaying
            self.wasPhonePlaying = phonePlaying
            if started {
                self.remoteDevice = .phone
                if self.macAvailable, self.macState[WatchKey.isPlaying] as? Bool == true,
                   let account = model?.playbackAccount {
                    Task {
                        _ = await NearbyPlayback.shared.request([
                            WatchKey.command: WatchCommand.pause.rawValue, WatchKey.account: account
                        ])
                    }
                }
            }
            self.push()
        }
        let nearby = NearbyPlayback.shared
        nearby.onChange = { [weak self] in
            guard let self else { return }
            if !NearbyPlayback.shared.connected {
                self.macState = [:]
                self.macAccount = nil
            } else if let account = self.model?.playbackAccount {
                Task {
                    if let state = await NearbyPlayback.shared.request([
                        WatchKey.command: WatchCommand.requestState.rawValue, WatchKey.account: account
                    ]), state[WatchKey.title] != nil {
                        NearbyPlayback.shared.onState?(state)
                    }
                }
            }
            self.push()
        }
        nearby.onState = { [weak self, weak model] state in
            guard let self else { return }
            let started = state[WatchKey.isPlaying] as? Bool == true &&
                self.macState[WatchKey.isPlaying] as? Bool != true
            self.macAccount = state[WatchKey.account] as? String
            self.macState = state
            if self.macAvailable, started {
                model?.player.pause()
                self.remoteDevice = .mac
            }
            self.push()
        }
        nearby.start()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func push() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        let state = currentState()
        try? session.updateApplicationContext(state)
        if session.isReachable { session.sendMessage(state, replyHandler: nil, errorHandler: nil) }
    }

    var macAvailable: Bool {
        NearbyPlayback.shared.connected && macAccount != nil && macAccount == model?.playbackAccount
    }

    func movePlayback(to target: PlaybackDevice) async {
        guard !switchingDevices, macAvailable, let model, let account = model.playbackAccount else { return }
        let source: PlaybackDevice = macPlaybackTitle == nil ? .phone : .mac
        guard target != source, target == .phone || target == .mac else { return }
        switchingDevices = true
        deviceIssue = nil
        defer { switchingDevices = false }

        let id = UUID().uuidString
        func request(_ command: WatchCommand, on device: PlaybackDevice,
                     fields: [String: Any] = [:]) async -> [String: Any]? {
            var message = fields
            message[WatchKey.command] = command.rawValue
            message[WatchKey.account] = account
            if device == .phone { return await endpoint?.handle(command, message) }
            let reply = await NearbyPlayback.shared.request(message)
            if let state = reply?["state"] as? [String: Any] {
                macAccount = state[WatchKey.account] as? String
                macState = state
            }
            return reply
        }

        let snapshot = await request(.snapshot, on: source)
        guard let data = snapshot?[WatchKey.transfer] as? Data, let transfer = PlaybackTransfer.decode(data) else {
            deviceIssue = "This queue can’t move from \(source.name)."
            return
        }
        let transaction = [WatchKey.transaction: id]
        let prepared = await request(.prepare, on: target, fields: [
            WatchKey.transaction: id, WatchKey.transfer: data
        ])
        guard prepared?[WatchKey.success] as? Bool == true else {
            _ = await request(.cancel, on: target, fields: transaction)
            deviceIssue = "Couldn’t prepare playback on \(target.name)."
            return
        }
        let released = await request(.release, on: source, fields: [
            WatchKey.transaction: id, WatchKey.songID: transfer.song?.id ?? ""
        ])
        guard let latest = PlaybackTransfer.decode(released?[WatchKey.transfer]),
              latest.queue == transfer.queue, latest.index == transfer.index,
              latest.manualIndexes == transfer.manualIndexes, latest.autoplayStart == transfer.autoplayStart else {
            _ = await request(.cancel, on: source, fields: transaction)
            _ = await request(.cancel, on: target, fields: transaction)
            deviceIssue = "Couldn’t move playback. The queue may have changed."
            return
        }

        let committed = await request(.commit, on: target, fields: [
            WatchKey.transaction: id, WatchKey.elapsed: latest.position, WatchKey.isPlaying: latest.playing
        ])
        let confirmation = committed == nil ? await request(.committed, on: target, fields: transaction) : committed
        guard confirmation?[WatchKey.success] as? Bool == true else {
            if confirmation != nil {
                _ = await request(.cancel, on: target, fields: transaction)
                _ = await request(.cancel, on: source, fields: transaction)
            }
            deviceIssue = confirmation == nil
                ? "Couldn’t confirm playback on \(target.name)."
                : "Couldn’t move playback to \(target.name)."
            return
        }
        remoteDevice = target
        _ = await request(.finish, on: source, fields: transaction)
        push()
    }

    private func currentState(for target: PlaybackDevice? = nil) -> [String: Any] {
        let device = target ?? remoteDevice
        var state = device == .mac ? (macAvailable ? macState : [:]) : (model?.playbackState() ?? [:])
        if device == .phone, let player = model?.player, let song = player.current {
            if lastArtworkSongID != song.id || artworkData == nil {
                artworkData = player.artwork?.thumbnailJPEG(side: 160)
                lastArtworkSongID = artworkData == nil ? nil : song.id
            }
            state[WatchKey.artwork] = artworkData
        }
        state[WatchKey.title] = state[WatchKey.title] ?? "Not Playing"
        if device == .mac, let timestamp = state[WatchKey.timestamp] as? Double,
           state[WatchKey.isPlaying] as? Bool == true {
            let elapsed = state[WatchKey.elapsed] as? Double ?? 0
            let duration = state[WatchKey.duration] as? Double ?? elapsed
            state[WatchKey.elapsed] = min(duration, elapsed + max(0, Date().timeIntervalSince1970 - timestamp))
        }
        state[WatchKey.timestamp] = Date().timeIntervalSince1970
        state[WatchKey.destination] = device.rawValue
        state.removeValue(forKey: WatchKey.account)
        state[WatchKey.devices] = macAvailable ? ["phone", "mac"] : ["phone"]
        state[WatchKey.credentials] = model?.credentials.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        state[WatchKey.accent] = UserDefaults.standard.string(forKey: AccentTheme.storageKey) ?? AccentTheme.fallback.rawValue
        return state
    }

    private func handle(_ message: [String: Any]) async -> [String: Any] {
        guard let model, let raw = message[WatchKey.command] as? String, let command = WatchCommand(rawValue: raw) else {
            return [WatchKey.success: false]
        }
        let target = (message[WatchKey.destination] as? String).flatMap(PlaybackDevice.init(rawValue:))
        if target == .mac {
            guard macAvailable, let account = model.playbackAccount else {
                return [WatchKey.success: false, WatchKey.uncertain: true]
            }
            var outbound = message
            outbound[WatchKey.account] = account
            guard let response = await NearbyPlayback.shared.request(outbound) else {
                return [WatchKey.success: false, WatchKey.uncertain: true]
            }
            if let state = response["state"] as? [String: Any] { macState = state }
            if (command == .commit || command == .committed), response[WatchKey.success] as? Bool == true { remoteDevice = .mac }
            push()
            if response[WatchKey.title] != nil { return currentState(for: .mac) }
            return response
        }
        if let result = await endpoint?.handle(command, message) {
            if (command == .commit || command == .committed), result[WatchKey.success] as? Bool == true { remoteDevice = .phone }
            push()
            return result
        }
        model.handlePlaybackControl(command, index: message[WatchKey.index] as? Int)
        push()
        return currentState(for: target)
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.push() }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.push() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in _ = await self.handle(message) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in replyHandler(await self.handle(message)) }
    }
}
