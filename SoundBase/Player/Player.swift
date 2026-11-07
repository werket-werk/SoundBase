import AVFoundation
import MediaPlayer
import Observation
import SwiftUI

enum RepeatMode: Int { case off, all, one }

/// Gapless queue player built on AVQueuePlayer. The app owns the full queue; AVQueuePlayer only
/// ever holds the current item plus one preloaded item so transitions are seamless.
@Observable @MainActor
final class Player {
    private(set) var queue: [Song] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var elapsed: Double = 0
    private(set) var duration: Double = 0
    private(set) var shuffle = false
    private(set) var repeatMode: RepeatMode = .off
    /// Queue index where Autoplay ("similar music") songs begin, if any.
    private(set) var autoplayStart: Int?
    private(set) var history: [Song] = []
    private(set) var artwork: UIImage?
    var autoplay = UserDefaults.standard.object(forKey: Pref.autoplay) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoplay, forKey: Pref.autoplay)
            if autoplay { Task { await fillAutoplayIfNeeded() } }
        }
    }

    var current: Song? { queue.indices.contains(index) ? queue[index] : nil }
    /// Upcoming songs the user queued (excludes Autoplay).
    var upNextRange: Range<Int> {
        let start = min(index + 1, queue.count)
        let end = max(start, min(autoplayStart ?? queue.count, queue.count))
        return start..<end
    }
    var autoplayRange: Range<Int> {
        let start = max(index + 1, min(autoplayStart ?? queue.count, queue.count))
        return start..<queue.count
    }

    @ObservationIgnored var client: SubsonicClient?
    @ObservationIgnored weak var downloads: DownloadManager?
    @ObservationIgnored var onStateChange: (() -> Void)?
    @ObservationIgnored var onLove: (() -> Void)?
    @ObservationIgnored var radioURLs: [String: URL] = [:]

    @ObservationIgnored private let avPlayer = AVQueuePlayer()
    @ObservationIgnored private var currentItem: AVPlayerItem?
    @ObservationIgnored private var preloadedItem: AVPlayerItem?
    @ObservationIgnored private var originalOrder: [Song] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var kvo: [NSKeyValueObservation] = []
    @ObservationIgnored private var scrobbled = false
    @ObservationIgnored private var fetchingAutoplay = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var lastNowPlayingPush: Double = 0

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        avPlayer.automaticallyWaitsToMinimizeStalling = true
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        kvo.append(avPlayer.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.currentItemChanged() }
        })
        kvo.append(avPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.syncStatus() }
        })
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated { self?.itemDidEnd(item) }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated {
                if type == .ended, options.contains(.shouldResume) { self?.resume() }
            }
        }
        configureRemoteCommands()
    }

    // MARK: - Queue control

    func play(_ songs: [Song], startAt: Int = 0, shuffled: Bool = false) {
        guard !songs.isEmpty else { return }
        originalOrder = songs
        shuffle = shuffled
        autoplayStart = nil
        if shuffled {
            var rest = songs
            let first = startAt > 0 ? rest.remove(at: min(startAt, rest.count - 1)) : nil
            rest.shuffle()
            queue = (first.map { [$0] } ?? []) + rest
            index = 0
        } else {
            queue = songs
            index = min(max(startAt, 0), songs.count - 1)
        }
        startCurrent()
    }

    func playRadio(_ station: RadioStation) {
        guard let url = URL(string: station.streamUrl) else { return }
        let id = "radio:\(station.id)"
        radioURLs[id] = url
        play([Song(id: id, title: station.name, artist: "Internet Radio")])
    }

    func playNext(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        if queue.isEmpty { play(songs); return }
        queue.insert(contentsOf: songs, at: index + 1)
        if let a = autoplayStart, a > index { autoplayStart = a + songs.count }
        originalOrder.append(contentsOf: songs)
        queueEdited()
    }

    func playLast(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        if queue.isEmpty { play(songs); return }
        let at = max(index + 1, min(autoplayStart ?? queue.count, queue.count))
        queue.insert(contentsOf: songs, at: at)
        if autoplayStart != nil { autoplayStart = at + songs.count }
        originalOrder.append(contentsOf: songs)
        queueEdited()
    }

    func jump(to newIndex: Int) {
        guard queue.indices.contains(newIndex) else { return }
        if let current { history.append(current) }
        index = newIndex
        if let a = autoplayStart, newIndex >= a { autoplayStart = newIndex }
        startCurrent()
    }

    func remove(at absoluteIndex: Int) {
        guard queue.indices.contains(absoluteIndex), absoluteIndex != index else { return }
        queue.remove(at: absoluteIndex)
        if absoluteIndex < index { index -= 1 }
        if let a = autoplayStart, absoluteIndex < a { autoplayStart = a - 1 }
        queueEdited()
    }

    func moveUpNext(from source: IndexSet, to destination: Int) {
        let range = upNextRange
        guard !range.isEmpty else { return }
        var slice = Array(queue[range])
        slice.move(fromOffsets: source, toOffset: destination)
        queue.replaceSubrange(range, with: slice)
        queueEdited()
    }

    func clearUpNext() {
        let range = upNextRange
        queue.removeSubrange(range)
        if let a = autoplayStart { autoplayStart = max(index + 1, a - range.count) }
        queueEdited()
    }

    func toggleShuffle() {
        shuffle.toggle()
        let range = upNextRange
        guard !range.isEmpty, let cur = current else { queueEdited(); return }
        if shuffle {
            queue.replaceSubrange(range, with: queue[range].shuffled())
        } else if let pos = originalOrder.firstIndex(where: { $0.id == cur.id }) {
            let upcomingIDs = Set(queue[range].map(\.id))
            let restored = originalOrder[(pos + 1)...].filter { upcomingIDs.contains($0.id) }.uniqued()
            let leftovers = queue[range].filter { s in !restored.contains(where: { $0.id == s.id }) }
            queue.replaceSubrange(range, with: restored + leftovers)
        }
        queueEdited()
    }

    func cycleRepeat() {
        repeatMode = switch repeatMode { case .off: .all; case .all: .one; case .one: .off }
        avPlayer.actionAtItemEnd = repeatMode == .one ? .none : .advance
        preloadNext()
        onStateChange?()
    }

    // MARK: - Transport

    func togglePlayPause() { isPlaying ? pause() : resume() }

    func pause() { avPlayer.pause() }

    func resume() {
        if currentItem == nil, current != nil { startCurrent(); return }
        try? AVAudioSession.sharedInstance().setActive(true)
        avPlayer.play()
    }

    func next() {
        guard !queue.isEmpty else { return }
        if let current { history.append(current) }
        if index + 1 < queue.count {
            index += 1
        } else if repeatMode == .all {
            index = 0
        } else {
            Task {
                await fillAutoplayIfNeeded(force: true)
                if index + 1 < queue.count { index += 1; startCurrent() }
            }
            return
        }
        startCurrent()
    }

    func previous() {
        if elapsed > 3 || index == 0 { seek(to: 0); return }
        index -= 1
        startCurrent()
    }

    func seek(to seconds: Double) {
        let t = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        avPlayer.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        elapsed = max(0, seconds)
        updateNowPlaying()
        onStateChange?()
    }

    func stop() {
        avPlayer.pause()
        avPlayer.removeAllItems()
        currentItem = nil
        preloadedItem = nil
        queue = []
        index = 0
        isPlaying = false
        elapsed = 0
        duration = 0
        artwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        onStateChange?()
    }

    // MARK: - Sync across devices

    func restoreQueue() async {
        guard queue.isEmpty, let client, let saved = try? await client.playQueue(),
              let entries = saved.entry, !entries.isEmpty, queue.isEmpty else { return }
        originalOrder = entries
        queue = entries
        index = entries.firstIndex { $0.id == saved.current } ?? 0
        startCurrent(autoPlay: false, at: Double(saved.position ?? 0) / 1000)
    }

    private func scheduleQueueSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let client else { return }
            let ids = queue.filter { !$0.isRadio }.prefix(500).map(\.id)
            guard !ids.isEmpty else { return }
            try? await client.savePlayQueue(ids: Array(ids), current: current?.id, positionMs: Int(elapsed * 1000))
        }
    }

    // MARK: - AVQueuePlayer plumbing

    private func startCurrent(autoPlay: Bool = true, at position: Double = 0) {
        guard let song = current else { stop(); return }
        avPlayer.removeAllItems()
        preloadedItem = nil
        let item = makeItem(song)
        currentItem = item
        avPlayer.insert(item, after: nil)
        if position > 0 { item.seek(to: CMTime(seconds: position, preferredTimescale: 600), completionHandler: nil) }
        elapsed = position
        duration = Double(song.duration ?? 0)
        scrobbled = false
        applyGain(song)
        preloadNext()
        if autoPlay {
            try? AVAudioSession.sharedInstance().setActive(true)
            avPlayer.play()
        }
        trackChanged(announce: autoPlay)
    }

    private func preloadNext() {
        if let p = preloadedItem { avPlayer.remove(p); preloadedItem = nil }
        guard repeatMode != .one, currentItem != nil else { return }
        let nextSong: Song?
        if queue.indices.contains(index + 1) { nextSong = queue[index + 1] }
        else if repeatMode == .all, !queue.isEmpty { nextSong = queue[0] }
        else { nextSong = nil }
        guard let nextSong, !nextSong.isRadio else { return }
        let item = makeItem(nextSong)
        if avPlayer.canInsert(item, after: currentItem) {
            avPlayer.insert(item, after: currentItem)
            preloadedItem = item
        }
    }

    private func queueEdited() {
        preloadNext()
        scheduleQueueSave()
        onStateChange?()
        Task { await fillAutoplayIfNeeded() }
    }

    private func makeItem(_ song: Song) -> AVPlayerItem {
        let url: URL
        if let radio = radioURLs[song.id] {
            url = radio
        } else if let local = downloads?.localURL(for: song.id) {
            url = local
        } else if let client {
            let defaults = UserDefaults.standard
            url = client.streamURL(song.id, maxBitRate: defaults.integer(forKey: Pref.maxBitRate),
                                   format: defaults.string(forKey: Pref.format) ?? "raw")
        } else {
            url = URL(string: "about:blank")!
        }
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        item.preferredForwardBufferDuration = 30
        return item
    }

    private func currentItemChanged() {
        let item = avPlayer.currentItem
        if let item, item === preloadedItem {
            if let current { history.append(current) }
            index = index + 1 < queue.count ? index + 1 : 0
            currentItem = item
            preloadedItem = nil
            elapsed = 0
            duration = Double(current?.duration ?? 0)
            scrobbled = false
            if let song = current { applyGain(song) }
            preloadNext()
            trackChanged(announce: true)
        } else if item == nil, currentItem != nil, repeatMode != .one {
            // Reached the end of the queue.
            currentItem = nil
            if autoplay {
                Task {
                    await fillAutoplayIfNeeded(force: true)
                    if index + 1 < queue.count { index += 1; startCurrent() }
                }
            } else {
                isPlaying = false
                onStateChange?()
            }
        }
    }

    private func itemDidEnd(_ item: AVPlayerItem?) {
        guard repeatMode == .one, let item, item === currentItem else { return }
        avPlayer.seek(to: .zero)
        avPlayer.play()
        scrobbled = false
        if let song = current { scrobble(song, submission: false) }
    }

    private func syncStatus() {
        isPlaying = avPlayer.timeControlStatus != .paused
        isBuffering = avPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate
        updateNowPlaying()
        onStateChange?()
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite, currentItem != nil else { return }
        elapsed = seconds
        if let d = avPlayer.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
        if !scrobbled, let song = current, !song.isRadio, duration > 30, elapsed >= min(duration / 2, 240) {
            scrobbled = true
            scrobble(song, submission: true)
        }
        if abs(seconds - lastNowPlayingPush) > 15 {
            lastNowPlayingPush = seconds
            updateNowPlaying()
            scheduleQueueSave()
        }
    }

    private func trackChanged(announce: Bool) {
        artwork = nil
        updateNowPlaying()
        scheduleQueueSave()
        onStateChange?()
        guard let song = current else { return }
        if announce, !song.isRadio { scrobble(song, submission: false) }
        if let cover = song.coverArt, let url = client?.coverURL(cover, size: 800) {
            let id = song.id
            Task {
                let image = await ImageLoader.shared.image(url)
                guard self.current?.id == id else { return }
                self.artwork = image
                self.updateNowPlaying()
                self.onStateChange?()
            }
        }
        Task { await fillAutoplayIfNeeded() }
    }

    // MARK: - Autoplay (endless similar music)

    func fillAutoplayIfNeeded(force: Bool = false) async {
        guard autoplay, repeatMode == .off, !fetchingAutoplay, let client, let seed = current, !seed.isRadio else { return }
        guard force || queue.count - index <= 3 else { return }
        fetchingAutoplay = true
        defer { fetchingAutoplay = false }
        var songs = (try? await client.similarSongs(seed.id, count: 30)) ?? []
        if songs.isEmpty, let artistId = seed.artistId {
            songs = (try? await client.similarSongs2(artistId: artistId, count: 30)) ?? []
        }
        if songs.isEmpty { songs = (try? await client.randomSongs(size: 30)) ?? [] }
        let existing = Set(queue.suffix(200).map(\.id))
        songs = songs.filter { !existing.contains($0.id) }.uniqued()
        guard !songs.isEmpty else { return }
        if autoplayStart == nil || autoplayStart! > queue.count { autoplayStart = queue.count }
        queue.append(contentsOf: songs)
        if preloadedItem == nil, currentItem != nil { preloadNext() }
        onStateChange?()
    }

    // MARK: - ReplayGain

    private func applyGain(_ song: Song) {
        let mode = UserDefaults.standard.integer(forKey: Pref.replayGain)
        guard mode != 0, let rg = song.replayGain else { avPlayer.volume = 1; return }
        let gain = mode == 2 ? (rg.albumGain ?? rg.trackGain) : (rg.trackGain ?? rg.albumGain)
        let peak = mode == 2 ? (rg.albumPeak ?? rg.trackPeak) : (rg.trackPeak ?? rg.albumPeak)
        guard let gain else { avPlayer.volume = 1; return }
        var factor = pow(10, gain / 20)
        if let peak, peak > 0 { factor = min(factor, 1 / peak) }
        avPlayer.volume = Float(min(1, max(0.05, factor)))
    }

    // MARK: - Scrobbling

    private func scrobble(_ song: Song, submission: Bool) {
        guard let client else { return }
        let time = Date()
        Task {
            do {
                try await client.scrobble(song.id, submission: submission, time: submission ? time : nil)
                if submission { await PendingScrobbles.flush(using: client) }
            } catch {
                if submission { PendingScrobbles.add(id: song.id, time: time) }
            }
        }
    }

    // MARK: - Lock screen / Control Center

    private func updateNowPlaying() {
        guard let song = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist ?? "",
            MPMediaItemPropertyAlbumTitle: song.album ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyIsLiveStream: song.isRadio,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = Self.mediaArtwork(artwork) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    /// Built outside the main actor: MediaPlayer calls the handler on a background thread.
    nonisolated private static func mediaArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        func handle(_ command: MPRemoteCommand, _ action: @escaping @MainActor (Player) -> Void) {
            command.isEnabled = true
            command.addTarget { [weak self] _ in
                guard let self else { return .commandFailed }
                MainActor.assumeIsolated { action(self) }
                return .success
            }
        }
        handle(center.playCommand) { $0.resume() }
        handle(center.pauseCommand) { $0.pause() }
        handle(center.togglePlayPauseCommand) { $0.togglePlayPause() }
        handle(center.nextTrackCommand) { $0.next() }
        handle(center.previousTrackCommand) { $0.previous() }
        handle(center.likeCommand) { $0.onLove?() }
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = e.positionTime
            MainActor.assumeIsolated { self.seek(to: position) }
            return .success
        }
    }
}
