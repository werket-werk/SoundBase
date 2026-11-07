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
    private(set) var downloads: [String: Song] = [:]
    private(set) var inProgress: Set<String> = []
    let player = WatchPlayer()
    var path: [WatchRoute] = []

    @ObservationIgnored private var pending: [Song] = []
    @ObservationIgnored private var active = 0
    @ObservationIgnored private let dir: URL
    @ObservationIgnored private let credsKey = "watchCreds"

    init() {
        dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: dir.appendingPathComponent("index.json")),
           let list = try? JSONDecoder().decode([Song].self, from: data) {
            downloads = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        if let data = UserDefaults.standard.data(forKey: credsKey) { setCredentials(data) }
        player.urlProvider = { [weak self] song in self?.playbackURL(for: song) }
        player.artworkProvider = { [weak self] song in await self?.artwork(for: song) }
    }

    func setCredentials(_ data: Data) {
        guard let creds = try? JSONDecoder().decode(ServerCredentials.self, from: data) else { return }
        if client?.creds == creds { return }
        UserDefaults.standard.set(data, forKey: credsKey)
        client = SubsonicClient(creds: creds)
    }

    var downloadedSongs: [Song] {
        downloads.values.sorted { ($0.artist ?? "", $0.album ?? "", $0.track ?? 0) < ($1.artist ?? "", $1.album ?? "", $1.track ?? 0) }
    }

    func isDownloaded(_ id: String) -> Bool { downloads[id] != nil }

    func playbackURL(for song: Song) -> URL? {
        let local = fileURL(song.id)
        if downloads[song.id] != nil, FileManager.default.fileExists(atPath: local.path) { return local }
        return song.shouldTranscode(toKbps: Self.quality)
            ? client?.streamURL(song.id, maxBitRate: Self.quality, format: "aac")
            : client?.streamURL(song.id, maxBitRate: 0, format: "raw")
    }

    /// Watch downloads and streams use AAC 128 kbps (about 1 MB per minute) unless the
    /// original is already a small lossy file.
    func download(_ songs: [Song]) {
        for song in songs where downloads[song.id] == nil && !inProgress.contains(song.id) {
            inProgress.insert(song.id)
            pending.append(song)
        }
        pump()
    }

    func remove(_ id: String) {
        try? FileManager.default.removeItem(at: fileURL(id))
        downloads.removeValue(forKey: id)
        persist()
    }

    func removeAll() {
        for id in downloads.keys { try? FileManager.default.removeItem(at: fileURL(id)) }
        downloads = [:]
        persist()
    }

    var totalBytes: Int64 {
        downloads.keys.reduce(0) { total, id in
            let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL(id).path)
            return total + ((attrs?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    private func pump() {
        while active < 2, !pending.isEmpty {
            let song = pending.removeFirst()
            active += 1
            Task {
                await fetch(song)
                active -= 1
                pump()
            }
        }
    }

    private func fetch(_ song: Song) async {
        defer { inProgress.remove(song.id) }
        guard let client else { return }
        var stored = song
        let url: URL
        if song.shouldTranscode(toKbps: Self.quality) {
            url = client.streamURL(song.id, maxBitRate: Self.quality, format: "aac")
            stored.suffix = "aac"
            stored.bitRate = Self.quality
        } else {
            url = client.downloadURL(song.id)
        }
        guard let (tmp, response) = try? await URLSession.shared.download(from: url),
              (response as? HTTPURLResponse)?.statusCode ?? 200 < 300 else { return }
        let dest = fileURL(stored)
        try? FileManager.default.removeItem(at: dest)
        guard (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil else { return }
        downloads[song.id] = stored
        if let cover = song.coverArt, !FileManager.default.fileExists(atPath: coverURL(cover).path),
           let (data, _) = try? await URLSession.shared.data(from: client.coverURL(cover, size: 300)) {
            try? data.write(to: coverURL(cover))
        }
        persist()
    }

    static let quality = 128

    private func fileURL(_ id: String) -> URL {
        downloads[id].map(fileURL) ?? dir.appendingPathComponent("\(id).aac")
    }

    private func coverURL(_ id: String) -> URL { dir.appendingPathComponent("cover-\(id).jpg") }

    /// Album artwork for Now Playing: saved with downloads, otherwise fetched from the server.
    func artwork(for song: Song) async -> UIImage? {
        guard let cover = song.coverArt else { return nil }
        if let data = try? Data(contentsOf: coverURL(cover)) { return UIImage(data: data) }
        guard let client, let (data, _) = try? await URLSession.shared.data(from: client.coverURL(cover, size: 300)) else { return nil }
        return UIImage(data: data)
    }

    private func fileURL(_ song: Song) -> URL {
        dir.appendingPathComponent("\(song.id).\(song.suffix ?? "aac")")
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Array(downloads.values)) {
            try? data.write(to: dir.appendingPathComponent("index.json"), options: .atomic)
        }
    }
}

// MARK: - On-watch player (Bluetooth headphones / speaker)

@Observable @MainActor
final class WatchPlayer {
    private(set) var queue: [Song] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    var current: Song? { queue.indices.contains(index) ? queue[index] : nil }

    @ObservationIgnored var urlProvider: ((Song) -> URL?)?
    @ObservationIgnored var artworkProvider: ((Song) async -> UIImage?)?
    @ObservationIgnored private var artwork: (id: String, image: UIImage)?
    @ObservationIgnored private let av = AVQueuePlayer()
    @ObservationIgnored private var kvo: NSKeyValueObservation?

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        kvo = av.observe(\.timeControlStatus) { [weak self] _, _ in
            Task { @MainActor in self?.syncStatus() }
        }
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.av.play() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.av.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.toggle() }; return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.next() }; return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.previous() }; return .success }
    }

    /// Activating the session asks the user to pick Bluetooth headphones if none are connected.
    func play(_ songs: [Song], startAt: Int = 0, shuffled: Bool = false) {
        guard !songs.isEmpty else { return }
        AVAudioSession.sharedInstance().activate(options: []) { success, _ in
            guard success else { return }
            Task { @MainActor in
                if shuffled { self.queue = songs.shuffled(); self.index = 0 }
                else { self.queue = songs; self.index = min(startAt, songs.count - 1) }
                self.start()
            }
        }
    }

    func toggle() {
        if isPlaying { av.pause() } else if av.currentItem == nil { start() } else { av.play() }
    }

    func next() {
        guard index + 1 < queue.count else { av.pause(); return }
        index += 1
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

    private func start() {
        av.removeAllItems()
        guard let song = current, let url = urlProvider?(song) else { return }
        av.insert(AVPlayerItem(url: url), after: nil)
        av.play()
        updateNowPlaying()
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
    var accent = AccentTheme.from(UserDefaults.standard.string(forKey: AccentTheme.storageKey))

    @ObservationIgnored weak var store: WatchStore?

    var phoneIsPlayingSomething: Bool { title != "Not Playing" && !title.isEmpty }

    func start(store: WatchStore) {
        self.store = store
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func elapsed(at date: Date) -> Double {
        guard isPlaying else { return elapsedAt }
        return min(duration, elapsedAt + date.timeIntervalSince1970 - timestamp)
    }

    func send(_ command: WatchCommand, index: Int? = nil) {
        switch command {
        case .togglePlay: isPlaying.toggle()
        case .love: loved.toggle()
        default: break
        }
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else { return }
        var message: [String: Any] = [WatchKey.command: command.rawValue]
        if let index { message[WatchKey.index] = index }
        WCSession.default.sendMessage(message, replyHandler: { reply in
            Task { @MainActor in self.apply(reply) }
        }, errorHandler: nil)
    }

    func apply(_ ctx: [String: Any]) {
        if let creds = ctx[WatchKey.credentials] as? Data, !creds.isEmpty { store?.setCredentials(creds) }
        if let raw = ctx[WatchKey.accent] as? String, raw != accent.rawValue {
            accent = AccentTheme.from(raw)
            UserDefaults.standard.set(raw, forKey: AccentTheme.storageKey)
        }
        guard let t = ctx[WatchKey.title] as? String else { return }
        title = t
        artist = ctx[WatchKey.artist] as? String ?? ""
        isPlaying = ctx[WatchKey.isPlaying] as? Bool ?? false
        duration = ctx[WatchKey.duration] as? Double ?? 0
        elapsedAt = ctx[WatchKey.elapsed] as? Double ?? 0
        timestamp = ctx[WatchKey.timestamp] as? Double ?? Date().timeIntervalSince1970
        loved = ctx[WatchKey.loved] as? Bool ?? false
        upNext = ctx[WatchKey.upNext] as? [String] ?? []
        if let data = ctx[WatchKey.artwork] as? Data { artwork = UIImage(data: data) } else if t == "Not Playing" { artwork = nil }
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
        Task { @MainActor in self.reachable = reachable }
    }
}
