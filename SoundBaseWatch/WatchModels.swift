import Foundation
import AVFoundation
import MediaPlayer
import Observation
import WatchConnectivity
import UIKit

// MARK: - Standalone store (works with no iPhone nearby)

@Observable @MainActor
final class WatchStore {
    private(set) var client: SubsonicClient?
    let downloads = DownloadManager()
    let player = WatchPlayer()
    var path: [WatchRoute] = []

    @ObservationIgnored private let credsKey = "watchCreds"

    init() {
        if let data = UserDefaults.standard.data(forKey: credsKey) {
            setCredentials(data)
        } else {
            let key = UserDefaults.standard.string(forKey: "watchDownloadLibrary")
            downloads.openOfflineLibrary(key.flatMap { $0.count == 64 && $0.allSatisfy(\.isHexDigit) ? $0 : nil })
        }
        player.urlProvider = { [weak self] song in self?.playbackURL(for: song) }
        player.artworkProvider = { [weak self] song in await self?.artwork(for: song) }
    }

    func setCredentials(_ data: Data) {
        if data.isEmpty {
            UserDefaults.standard.removeObject(forKey: credsKey)
            client = nil
            downloads.client = nil
            return
        }
        guard let creds = try? JSONDecoder().decode(ServerCredentials.self, from: data) else { return }
        if client?.creds == creds { return }
        let oldKey = UserDefaults.standard.string(forKey: "watchDownloadLibrary")
        if oldKey != creds.libraryKey { player.clear() }
        UserDefaults.standard.set(data, forKey: credsKey)
        UserDefaults.standard.set(creds.libraryKey, forKey: "watchDownloadLibrary")
        let client = SubsonicClient(creds: creds)
        self.client = client
        downloads.client = client
    }

    func playbackURL(for song: Song) -> URL? {
        if let local = downloads.localURL(for: song.id) { return local }
        let quality = DownloadManager.watchQuality
        return song.shouldTranscode(toKbps: quality)
            ? client?.streamURL(song.id, maxBitRate: quality, format: "aac")
            : client?.streamURL(song.id, maxBitRate: 0, format: "raw")
    }

    /// Album artwork for Now Playing: saved with downloads, otherwise fetched from the server.
    func artwork(for song: Song) async -> UIImage? {
        if let image = savedArtwork(for: song) { return image }
        guard let cover = song.coverArt else { return nil }
        guard let client, let (data, _) = try? await URLSession.shared.data(from: client.coverURL(cover, size: 300)) else { return nil }
        return UIImage(data: data)
    }

    func savedArtwork(for song: Song) -> UIImage? {
        guard let cover = song.coverArt, let data = try? Data(contentsOf: downloads.artworkURL(cover)) else { return nil }
        return UIImage(data: data)
    }

}

// MARK: - On-watch player (Bluetooth headphones / speaker)

@Observable @MainActor
final class WatchPlayer {
    private(set) var queue: [Song] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var error: String?
    var current: Song? { queue.indices.contains(index) ? queue[index] : nil }
    var elapsed: Double { av.currentTime().seconds.isFinite ? max(0, av.currentTime().seconds) : 0 }
    var currentArtwork: UIImage? { artwork?.id == current?.id ? artwork?.image : nil }
    var transferSnapshot: PlaybackTransfer? {
        guard current != nil else { return nil }
        return PlaybackTransfer(queue: queue, index: index, position: elapsed, playing: isPlaying)
    }

    @ObservationIgnored var urlProvider: ((Song) -> URL?)?
    @ObservationIgnored var artworkProvider: ((Song) async -> UIImage?)?
    private var artwork: (id: String, image: UIImage)?
    @ObservationIgnored private let av = AVQueuePlayer()
    @ObservationIgnored private var kvo: NSKeyValueObservation?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        kvo = av.observe(\.timeControlStatus) { [weak self] _, _ in
            Task { @MainActor in self?.syncStatus() }
        }
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
    }

    func prepare(_ transfer: PlaybackTransfer) async -> URL? {
        guard let song = transfer.song, let url = urlProvider?(song),
              (try? await AVURLAsset(url: url).load(.isPlayable)) == true else { return nil }
        if transfer.playing {
            guard (try? await AVAudioSession.sharedInstance().activate(options: [])) == true else { return nil }
        }
        return url
    }

    func receive(_ transfer: PlaybackTransfer, url: URL) {
        queue = transfer.queue
        index = transfer.index
        start(url: url, position: transfer.position, playing: transfer.playing)
    }

    func pause() { av.pause(); syncStatus() }

    private func resume() {
        guard let id = current?.id else { return }
        Task {
            let activated = (try? await AVAudioSession.sharedInstance().activate(options: [])) == true
            guard current?.id == id else { return }
            guard activated else {
                error = "Choose an audio output to play on Apple Watch."
                return
            }
            if av.currentItem == nil { start() } else { av.play() }
        }
    }

    func clear() {
        pause()
        av.removeAllItems()
        queue = []
        index = 0
        updateNowPlaying()
    }

    func toggle() {
        if isPlaying { pause() } else { resume() }
    }

    func next() {
        guard index + 1 < queue.count else { av.pause(); return }
        index += 1
        start()
    }

    func jump(to index: Int) {
        guard queue.indices.contains(index) else { return }
        self.index = index
        start()
    }

    func previous() {
        if av.currentTime().seconds > 3 || index == 0 { av.seek(to: .zero); return }
        index -= 1
        start()
    }

    private func advance() {
        if index + 1 < queue.count { index += 1; start() } else { isPlaying = false }
    }

    private func start(url preparedURL: URL? = nil, position: Double = 0, playing: Bool = true) {
        error = nil
        av.removeAllItems()
        guard let song = current, let url = preparedURL ?? urlProvider?(song) else {
            error = "This track is unavailable on Apple Watch."
            return
        }
        let item = AVPlayerItem(url: url)
        av.insert(item, after: nil)
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in
                guard let self, self.av.currentItem === item else { return }
                self.pause()
                self.error = "This track couldn’t play on Apple Watch."
            }
        }
        if position > 0 {
            av.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if playing { av.play() }
        syncStatus()
        let id = song.id
        Task {
            guard let image = await artworkProvider?(song), current?.id == id else { return }
            artwork = (id, image)
            updateNowPlaying()
        }
    }

    private func syncStatus() {
        isPlaying = av.timeControlStatus != .paused
        updateNowPlaying()
    }

    private func updateNowPlaying() {
        guard let song = current else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist ?? "",
            MPMediaItemPropertyAlbumTitle: song.album ?? "",
            MPMediaItemPropertyPlaybackDuration: Double(song.duration ?? 0),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: av.currentTime().seconds.isFinite ? av.currentTime().seconds : 0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let artwork, artwork.id == song.id { info[MPMediaItemPropertyArtwork] = Self.mediaArtwork(artwork.image) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Built outside the main actor: MediaPlayer may call the handler on a background thread.
    nonisolated private static func mediaArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}

// MARK: - iPhone remote link

@Observable @MainActor
final class WatchSession: NSObject, WCSessionDelegate {
    var title = "Not Playing"
    var artist = ""
    var isPlaying = false
    var duration: Double = 0
    var elapsedAt: Double = 0
    var timestamp: Double = 0
    var loved = false
    var artwork: UIImage?
    var upNext: [String] = []
    var reachable = false
    var songID: String?
    var reportedDevice: PlaybackDevice = .phone
    var remoteDevices: [PlaybackDevice] = [.phone]
    private(set) var switching = false
    private(set) var commandError: String?
    private(set) var localLoved = false
    private var selection: PlaybackDevice?
    var accent = AccentTheme.from(UserDefaults.standard.string(forKey: AccentTheme.storageKey))

    @ObservationIgnored weak var store: WatchStore?

    var phoneIsPlayingSomething: Bool { title != "Not Playing" && !title.isEmpty }
    var device: PlaybackDevice {
        if let selection { return selection }
        if store?.player.current != nil { return .watch }
        return phoneIsPlayingSomething ? reportedDevice : .watch
    }
    var availableDevices: [PlaybackDevice] { [.watch] + (reachable ? remoteDevices : []) }
    var currentSongID: String? { device == .watch ? store?.player.current?.id : songID }
    var playing: Bool { device == .watch ? store?.player.isPlaying == true : isPlaying }
    var currentTitle: String { device == .watch ? store?.player.current?.title ?? "Not Playing" : title }

    func play(_ songs: [Song], startAt index: Int = 0, shuffled: Bool = false) async {
        let queue = shuffled ? songs.shuffled() : songs
        let transfer = PlaybackTransfer(queue: queue, index: shuffled ? 0 : index, position: 0, playing: true)
        let target = availableDevices.contains(device) ? device : .watch
        await changePlayback(to: target, replacement: transfer)
    }

    func select(_ target: PlaybackDevice) async {
        guard target != device else { return }
        await changePlayback(to: target, replacement: nil)
    }

    func dismissError() { commandError = nil }

    private func changePlayback(to target: PlaybackDevice, replacement: PlaybackTransfer?) async {
        guard let player = store?.player, !switching, availableDevices.contains(target) else { return }
        switching = true
        commandError = nil
        defer { switching = false }
        let source = device
        let id = UUID().uuidString
        var existing: PlaybackTransfer?
        if source != target || replacement == nil {
            if source == .watch {
                existing = player.transferSnapshot
            } else if reachable, phoneIsPlayingSomething {
                existing = PlaybackTransfer.decode(await request(.snapshot, device: source)?[WatchKey.transfer])
                if existing == nil {
                    commandError = "This queue can’t move from \(source.name)."
                    return
                }
            }
        }
        guard let transfer = replacement ?? existing else {
            selection = target
            return
        }
        let preparedURL: URL?
        if target == .watch {
            preparedURL = await player.prepare(transfer)
            guard preparedURL != nil else {
                commandError = "Apple Watch couldn’t open this track or find an audio output."
                return
            }
        } else {
            preparedURL = nil
            guard let data = transfer.encoded,
                  await request(.prepare, device: target, fields: [WatchKey.transaction: id, WatchKey.transfer: data])?[WatchKey.success] as? Bool == true else {
                commandError = "Couldn’t prepare playback on \(target.name)."
                return
            }
        }

        var resume = transfer
        let moving = source != target && existing != nil
        if moving, let existing {
            if source == .watch {
                if replacement == nil, let latest = player.transferSnapshot { resume = latest }
                player.pause()
            } else {
                let reply = await request(.release, device: source, fields: [
                    WatchKey.transaction: id, WatchKey.songID: existing.song?.id ?? ""
                ])
                guard let latest = PlaybackTransfer.decode(reply?[WatchKey.transfer]) else {
                    _ = await request(.cancel, device: source, fields: [WatchKey.transaction: id])
                    if target != .watch { _ = await request(.cancel, device: target, fields: [WatchKey.transaction: id]) }
                    commandError = "Couldn’t pause \(source.name)."
                    return
                }
                if replacement == nil { resume = latest }
            }
        }

        if let preparedURL {
            player.receive(resume, url: preparedURL)
        } else {
            let fields: [String: Any] = [WatchKey.transaction: id, WatchKey.elapsed: resume.position,
                                         WatchKey.isPlaying: resume.playing]
            let reply = await request(.commit, device: target, fields: fields)
            let uncertain = reply == nil || reply?[WatchKey.uncertain] as? Bool == true
            let confirmation = uncertain ? await request(.committed, device: target, fields: fields) : reply
            guard confirmation?[WatchKey.success] as? Bool == true else {
                let unknown = confirmation == nil || confirmation?[WatchKey.uncertain] as? Bool == true
                if !unknown, moving, let existing {
                    if source == .watch, existing.playing { player.toggle() }
                    else if source != .watch {
                        _ = await request(.cancel, device: source, fields: [WatchKey.transaction: id])
                    }
                }
                commandError = unknown ? "Couldn’t confirm playback on \(target.name)." : "Couldn’t move playback to \(target.name)."
                return
            }
        }
        if moving {
            if source == .watch { player.clear() }
            else { _ = await request(.finish, device: source, fields: [WatchKey.transaction: id]) }
        }
        selection = target
        if target != .watch { send(.requestState) }
    }

    func control(_ command: WatchCommand, index: Int? = nil) {
        guard !switching else { return }
        if device != .watch {
            guard availableDevices.contains(device) else {
                commandError = "\(device.name) is unavailable."
                return
            }
            send(command, index: index)
            return
        }
        guard let player = store?.player else { return }
        switch command {
        case .togglePlay: player.toggle()
        case .previous: player.previous()
        case .next: player.next()
        case .jump: if let index { player.jump(to: player.index + 1 + index) }
        case .love:
            guard let client = store?.client, let id = player.current?.id else { return }
            Task {
                let newValue = !localLoved
                do {
                    try await client.setStar(id, kind: .song, on: newValue)
                    if player.current?.id == id { localLoved = newValue }
                } catch { commandError = "Couldn’t update Favourite." }
            }
        default: break
        }
    }

    func refreshLocalFavourite() async {
        localLoved = false
        guard let client = store?.client, let id = store?.player.current?.id,
              let songs = try? await client.starred().song, store?.player.current?.id == id else { return }
        localLoved = songs.contains { $0.id == id }
    }

    func start(store: WatchStore) {
        self.store = store
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func elapsed(at date: Date) -> Double {
        guard isPlaying else { return elapsedAt }
        return max(0, min(duration, elapsedAt + date.timeIntervalSince1970 - timestamp))
    }

    func send(_ command: WatchCommand, index: Int? = nil) {
        Task {
            var fields: [String: Any] = [:]
            if let index { fields[WatchKey.index] = index }
            guard let reply = await request(command, device: device, fields: fields),
                  reply[WatchKey.success] as? Bool != false else {
                if command != .requestState { commandError = "Couldn’t reach \(device.name)." }
                return
            }
            apply(reply)
        }
    }

    private func request(_ command: WatchCommand, device: PlaybackDevice,
                         fields: [String: Any] = [:]) async -> [String: Any]? {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return nil }
        var message = fields
        message[WatchKey.command] = command.rawValue
        if device != .watch { message[WatchKey.destination] = device.rawValue }
        return await withCheckedContinuation { continuation in
            session.sendMessage(message, replyHandler: { continuation.resume(returning: $0) },
                                errorHandler: { _ in continuation.resume(returning: nil) })
        }
    }

    func apply(_ ctx: [String: Any]) {
        let incoming = ctx[WatchKey.timestamp] as? Double ?? Date().timeIntervalSince1970
        guard incoming >= timestamp else { return }
        if let creds = ctx[WatchKey.credentials] as? Data { store?.setCredentials(creds) }
        if let raw = ctx[WatchKey.accent] as? String, raw != accent.rawValue {
            accent = AccentTheme.from(raw)
            UserDefaults.standard.set(raw, forKey: AccentTheme.storageKey)
        }
        guard let t = ctx[WatchKey.title] as? String else { return }
        let previouslyPlaying = isPlaying
        let priorDevice = reportedDevice
        title = t
        artist = ctx[WatchKey.artist] as? String ?? ""
        isPlaying = ctx[WatchKey.isPlaying] as? Bool ?? false
        duration = ctx[WatchKey.duration] as? Double ?? 0
        elapsedAt = ctx[WatchKey.elapsed] as? Double ?? 0
        timestamp = incoming
        songID = ctx[WatchKey.songID] as? String
        reportedDevice = (ctx[WatchKey.destination] as? String).flatMap(PlaybackDevice.init(rawValue:)) ?? .phone
        if let devices = ctx[WatchKey.devices] as? [String] {
            remoteDevices = devices.compactMap(PlaybackDevice.init(rawValue:))
        }
        if isPlaying, !switching, !previouslyPlaying || priorDevice != reportedDevice {
            if let player = store?.player, player.current != nil { player.clear() }
            selection = reportedDevice
        }
        loved = ctx[WatchKey.loved] as? Bool ?? false
        upNext = ctx[WatchKey.upNext] as? [String] ?? []
        artwork = (ctx[WatchKey.artwork] as? Data).flatMap(UIImage.init(data:))
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let ctx = session.receivedApplicationContext
        let reachable = session.isReachable
        Task { @MainActor in
            self.reachable = reachable
            self.apply(ctx)
            if reachable { self.send(.requestState) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.apply(applicationContext) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.apply(message) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.reachable = reachable
            if reachable { self.send(.requestState) }
        }
    }
}
