import AVFoundation
import MediaPlayer
import Observation
import SwiftUI

enum RepeatMode: Int, CaseIterable {
    case off, all, one

    var title: String {
        switch self {
        case .off: "Repeat Off"
        case .all: "Repeat All"
        case .one: "Repeat One"
        }
    }

    var icon: String { self == .one ? "repeat.1" : "repeat" }
}

struct ListeningHistoryEntry: Codable, Identifiable {
    let id: UUID
    let song: Song
    let playedAt: Date
}

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
    private(set) var listeningHistory: [ListeningHistoryEntry] = []
    private(set) var playbackIssue: String?
    private var queueFinished = false
    private(set) var artwork: PlatformImage?
    var autoplay = UserDefaults.standard.object(forKey: Pref.autoplay) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoplay, forKey: Pref.autoplay)
            if autoplay { Task { await fillAutoplayIfNeeded() } }
        }
    }

    var current: Song? { queue.indices.contains(index) ? queue[index] : nil }
    private var manualIndexes = IndexSet()

    var manualRange: Range<Int> {
        let start = min(index + 1, queue.count)
        var end = start
        while end < queue.count, manualIndexes.contains(end) { end += 1 }
        return start..<end
    }

    var sourceRange: Range<Int> {
        let start = manualRange.upperBound
        return start..<max(start, min(autoplayStart ?? queue.count, queue.count))
    }

    var autoplayRange: Range<Int> {
        let start = max(min(index + 1, queue.count), min(autoplayStart ?? queue.count, queue.count))
        return start..<queue.count
    }

    private struct SavedQueueSections: Codable {
        let ids: [String]
        let manualIndexes: IndexSet
        let autoplayStart: Int?
        let currentIndex: Int?
        let position: Int?
        var finished: Bool? = nil
        var previousPosition: Int? = nil
    }

    @ObservationIgnored var queueAccount: String? {
        didSet {
            guard queueAccount != oldValue else { return }
            lastServerPosition = nil
            listeningHistory = []
            if let queueAccount, let data = UserDefaults.standard.data(forKey: "listeningHistory.\(queueAccount)") {
                listeningHistory = (try? JSONDecoder().decode([ListeningHistoryEntry].self, from: data)) ?? []
            }
        }
    }
    @ObservationIgnored var client: SubsonicClient?
    @ObservationIgnored weak var downloads: DownloadManager?
    @ObservationIgnored var onStateChange: (() -> Void)?
    @ObservationIgnored var onLove: (() -> Void)?
    @ObservationIgnored var radioURLs: [String: URL] = [:]
    @ObservationIgnored weak var cast: CastManager?
    var isCasting: Bool { cast?.isCasting == true }

    @ObservationIgnored private let avPlayer = AVQueuePlayer()
    @ObservationIgnored private var currentItem: AVPlayerItem?
    @ObservationIgnored private var itemStatus: NSKeyValueObservation?
    @ObservationIgnored private var stallTask: Task<Void, Never>?
    @ObservationIgnored private var recordedCurrent = false
    @ObservationIgnored private var retryPosition: Double = 0
    @ObservationIgnored private var preloadedItem: AVPlayerItem?
    @ObservationIgnored private var originalOrder: [Song] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var kvo: [NSKeyValueObservation] = []
    @ObservationIgnored private var scrobbled = false
    @ObservationIgnored private var fetchingAutoplay = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var queueWriteTask: Task<Void, Never>?
    @ObservationIgnored private var queueWriteRevision = 0
    @ObservationIgnored private var lastServerPosition: Int?
    @ObservationIgnored private var lastNowPlayingPush: Double = 0

    init() {
        #if os(iOS)
        _ = StreamingConnection.shared
        #endif
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        #endif
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
        NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification,
                                               object: nil, queue: .main) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            MainActor.assumeIsolated { self?.itemFailed(item) }
        }
        #if os(iOS)
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated {
                if type == .ended, options.contains(.shouldResume) { self?.resume() }
            }
        }
        #endif
        configureRemoteCommands()
    }

    // MARK: - Queue control

    func play(_ songs: [Song], startAt: Int = 0, shuffled: Bool = false, autoPlay: Bool = true) {
        guard !songs.isEmpty else { return }
        originalOrder = songs
        manualIndexes = []
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
        startCurrent(autoPlay: autoPlay)
    }

    func playRadio(_ station: RadioStation) -> Bool {
        guard let url = URL(string: station.streamUrl), let scheme = url.scheme,
              ["http", "https"].contains(scheme.lowercased()), url.host != nil else { return false }
        let id = "radio:\(station.id)"
        radioURLs[id] = url
        play([Song(id: id, title: station.name, artist: "Internet Radio")])
        return true
    }

    func playNext(_ songs: [Song]) {
        insertManual(songs, at: manualRange.lowerBound)
    }

    func addToQueue(_ songs: [Song]) {
        insertManual(songs, at: manualRange.upperBound)
    }

    private func insertManual(_ songs: [Song], at position: Int) {
        guard !songs.isEmpty else { return }
        if queue.isEmpty {
            play(songs, autoPlay: false)
            manualIndexes = IndexSet(integersIn: 0..<songs.count)
            scheduleQueueSave()
            return
        }
        queue.insert(contentsOf: songs, at: position)
        manualIndexes.shift(startingAt: position, by: songs.count)
        manualIndexes.insert(integersIn: position..<(position + songs.count))
        if let start = autoplayStart, position <= start || index >= start {
            autoplayStart = max(index + 1, start) + songs.count
        }
        queueEdited()
    }

    func jump(to newIndex: Int) {
        guard queue.indices.contains(newIndex) else { return }
        index = newIndex
        prioritizeManualUpcoming()
        startCurrent()
    }

    private func prioritizeManualUpcoming() {
        let start = min(index + 1, queue.count)
        let positions = manualIndexes.intersection(IndexSet(integersIn: start..<queue.count))
        guard !positions.isEmpty else { return }
        let queued = positions.map { queue[$0] }
        let source = (start..<queue.count).filter { !positions.contains($0) }.map { queue[$0] }
        queue.replaceSubrange(start..<queue.count, with: queued + source)
        manualIndexes.subtract(positions)
        manualIndexes.insert(integersIn: start..<(start + queued.count))
        if let boundary = autoplayStart {
            let movedAhead = positions.filter { $0 >= boundary }.count
            autoplayStart = max(start, boundary) + movedAhead
        }
    }

    private var repeatStartIndex: Int {
        queue.indices.first { !manualIndexes.contains($0) } ?? 0
    }

    private func wrapRepeatQueue() {
        if manualIndexes.count < queue.count {
            for offset in manualIndexes.reversed() { queue.remove(at: offset) }
            manualIndexes = []
        }
        index = 0
    }

    func remove(at absoluteIndex: Int) {
        guard queue.indices.contains(absoluteIndex), absoluteIndex != index else { return }
        queue.remove(at: absoluteIndex)
        manualIndexes.remove(absoluteIndex)
        manualIndexes.shift(startingAt: absoluteIndex + 1, by: -1)
        if absoluteIndex < index { index -= 1 }
        if let a = autoplayStart, absoluteIndex < a { autoplayStart = a - 1 }
        queueEdited()
    }

    func moveUpcoming(in range: Range<Int>, from source: IndexSet, to destination: Int) {
        guard !range.isEmpty, range == manualRange || range == sourceRange,
              source.allSatisfy({ $0 < range.count }), (0...range.count).contains(destination) else { return }
        var slice = Array(queue[range])
        slice.move(fromOffsets: source, toOffset: destination)
        queue.replaceSubrange(range, with: slice)
        queueEdited()
    }

    func clearManualQueue() {
        let range = manualRange
        guard !range.isEmpty else { return }
        queue.removeSubrange(range)
        manualIndexes.remove(integersIn: range)
        manualIndexes.shift(startingAt: range.upperBound, by: -range.count)
        if let start = autoplayStart, start >= range.upperBound { autoplayStart = start - range.count }
        queueEdited()
    }

    func toggleShuffle() {
        shuffle.toggle()
        let range = sourceRange
        let positions = range.filter { !manualIndexes.contains($0) }
        let songs = positions.map { queue[$0] }
        let reordered: [Song]
        if shuffle {
            reordered = songs.shuffled()
        } else {
            var ranks: [String: Int] = [:]
            for (index, song) in originalOrder.enumerated() where ranks[song.id] == nil {
                ranks[song.id] = index
            }
            reordered = songs.enumerated().sorted {
                (ranks[$0.element.id] ?? Int.max, $0.offset) < (ranks[$1.element.id] ?? Int.max, $1.offset)
            }.map(\.element)
        }
        for (position, song) in zip(positions, reordered) { queue[position] = song }
        queueEdited()
    }

    func cycleRepeat() {
        setRepeatMode(RepeatMode(rawValue: (repeatMode.rawValue + 1) % RepeatMode.allCases.count) ?? .off)
    }

    func setRepeatMode(_ mode: RepeatMode) {
        guard mode != repeatMode else { return }
        repeatMode = mode
        avPlayer.actionAtItemEnd = mode == .one ? .none : .advance
        if mode != .off, let start = autoplayStart {
            queue.removeSubrange(max(index + 1, start)..<queue.count)
            autoplayStart = nil
        }
        queueEdited()
    }

    // MARK: - Transport

    func togglePlayPause() { isPlaying ? pause() : resume() }

    func pause() {
        if let cast, cast.isCasting { cast.pause() }
        else { avPlayer.pause() }
        scheduleQueueSave(immediately: true)
    }

    func resume() {
        guard current != nil else { return }
        if queueFinished { startCurrent(); return }
        if playbackIssue != nil { retryPlayback(); return }
        if let cast, cast.isCasting {
            if current != nil, cast.isCasting, !isPlaying { cast.play() }
            return
        }
        if currentItem == nil, current != nil { startCurrent(); return }
        activateSession()
        avPlayer.play()
    }

    func next() {
        guard !queue.isEmpty else { return }
        if index + 1 < queue.count {
            index += 1
        } else if repeatMode == .all {
            wrapRepeatQueue()
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
        prioritizeManualUpcoming()
        startCurrent()
    }

    func seek(to seconds: Double) {
        if let cast, cast.isCasting {
            cast.seek(to: max(0, seconds))
        } else {
            let t = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
            avPlayer.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        elapsed = max(0, seconds)
        if playbackIssue != nil { retryPosition = elapsed }
        if !isPlaying { scheduleQueueSave(immediately: true) }
        updateNowPlaying()
        onStateChange?()
    }

    func stop(clearSavedQueue: Bool = true) {
        saveTask?.cancel()
        if clearSavedQueue, current != nil, let client {
            if let queueAccount {
                UserDefaults.standard.set(UUID().uuidString, forKey: "queueStopped.\(queueAccount)")
                UserDefaults.standard.removeObject(forKey: "queueSections.\(queueAccount)")
            }
            writeQueue(using: client, ids: [], currentID: nil, position: 0)
        }
        cast?.pause()
        queueFinished = false
        playbackIssue = nil
        stallTask?.cancel()
        stallTask = nil
        itemStatus = nil
        avPlayer.pause()
        avPlayer.removeAllItems()
        currentItem = nil
        preloadedItem = nil
        queue = []
        originalOrder = []
        manualIndexes = []
        autoplayStart = nil
        index = 0
        isPlaying = false
        isBuffering = false
        elapsed = 0
        duration = 0
        artwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        onStateChange?()
    }

    // MARK: - Sync across devices

    var transferSnapshot: PlaybackTransfer? {
        guard current != nil, !isCasting, !queue.contains(where: \.isRadio) else { return nil }
        return PlaybackTransfer(queue: queue, index: index, position: max(0, elapsed),
                                playing: avPlayer.timeControlStatus != .paused, manualIndexes: manualIndexes, autoplayStart: autoplayStart)
    }

    func canReceive(_ transfer: PlaybackTransfer) async -> Bool {
        guard !isCasting, let song = transfer.song, let url = playbackURL(for: song) else { return false }
        return (try? await AVURLAsset(url: url).load(.isPlayable)) == true
    }

    func receive(_ transfer: PlaybackTransfer) {
        originalOrder = transfer.queue
        queue = transfer.queue
        index = transfer.index
        manualIndexes = (transfer.manualIndexes ?? []).intersection(IndexSet(integersIn: queue.indices))
        autoplayStart = transfer.autoplayStart.flatMap { queue.indices.contains($0) ? $0 : nil }
        shuffle = false
        startCurrent(autoPlay: transfer.playing, at: transfer.position)
    }

    func releaseForTransfer() {
        stop(clearSavedQueue: false)
    }

    private var restoreBlocked: Bool {
        guard let queueAccount else { return false }
        return UserDefaults.standard.string(forKey: "queueStopped.\(queueAccount)") != nil
    }

    func restoreQueue() async {
        guard queue.isEmpty, !restoreBlocked, let client, let saved = try? await client.playQueue(),
              let entries = saved.entry, !entries.isEmpty, queue.isEmpty, !restoreBlocked,
              self.client === client else { return }
        originalOrder = entries
        queue = entries
        index = entries.firstIndex { $0.id == saved.current } ?? 0
        lastServerPosition = saved.position ?? 0
        var position = lastServerPosition ?? 0
        var finished = false
        if let queueAccount, let data = UserDefaults.standard.data(forKey: "queueSections.\(queueAccount)"),
           let sections = try? JSONDecoder().decode(SavedQueueSections.self, from: data),
           sections.ids == entries.map(\.id) {
            manualIndexes = sections.manualIndexes.intersection(IndexSet(integersIn: entries.indices))
            autoplayStart = sections.autoplayStart.flatMap { entries.indices.contains($0) ? $0 : nil }
            if let currentIndex = sections.currentIndex, entries.indices.contains(currentIndex),
               entries[currentIndex].id == saved.current,
               sections.position == position || sections.previousPosition == position {
                index = currentIndex
                position = sections.position ?? position
                finished = sections.finished == true
            }
        }
        prioritizeManualUpcoming()
        startCurrent(autoPlay: false, at: Double(position) / 1000, finished: finished)
    }

    private func scheduleQueueSave(immediately: Bool = false) {
        saveTask?.cancel()
        if immediately { saveQueue() }
        else {
            saveTask = Task {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                saveQueue()
            }
        }
    }

    private func saveQueue() {
        guard let client, let current, !current.isRadio else { return }
        let savedPositions = queue.indices.filter { !queue[$0].isRadio }.prefix(500)
        let ids = savedPositions.map { queue[$0].id }
        let position = queueFinished ? 0 : Int(max(0, elapsed) * 1000)
        if let queueAccount {
            let manual = IndexSet(savedPositions.enumerated().compactMap {
                manualIndexes.contains($0.element) ? $0.offset : nil
            })
            let start = autoplayStart.flatMap { savedPositions.firstIndex(of: $0) }
                .map { savedPositions.distance(from: savedPositions.startIndex, to: $0) }
            let currentIndex = savedPositions.firstIndex(of: index)
                .map { savedPositions.distance(from: savedPositions.startIndex, to: $0) }
            let sections = SavedQueueSections(ids: ids, manualIndexes: manual, autoplayStart: start,
                                              currentIndex: currentIndex, position: position,
                                              finished: queueFinished, previousPosition: lastServerPosition)
            if let data = try? JSONEncoder().encode(sections) {
                UserDefaults.standard.set(data, forKey: "queueSections.\(queueAccount)")
            }
        }
        writeQueue(using: client, ids: ids, currentID: current.id, position: position)
    }

    private func writeQueue(using client: SubsonicClient, ids: [String], currentID: String?, position: Int) {
        let previous = queueWriteTask
        queueWriteRevision += 1
        let revision = queueWriteRevision
        let stoppedKey = queueAccount.map { "queueStopped.\($0)" }
        let marker = stoppedKey.flatMap { UserDefaults.standard.string(forKey: $0) }
        queueWriteTask = Task {
            await previous?.value
            guard revision == queueWriteRevision else { return }
            do {
                try await client.savePlayQueue(ids: ids, current: currentID, positionMs: position)
                if self.client === client { lastServerPosition = ids.isEmpty ? nil : position }
                if let stoppedKey, let marker, UserDefaults.standard.string(forKey: stoppedKey) == marker {
                    UserDefaults.standard.removeObject(forKey: stoppedKey)
                }
            } catch {
                // Keep the local checkpoint if the server is unreachable.
            }
        }
    }

    // MARK: - AVQueuePlayer plumbing

    func retryPlayback() {
        guard playbackIssue != nil, current != nil else { return }
        startCurrent(at: retryPosition, retrying: true)
    }

    private func startCurrent(autoPlay: Bool = true, at position: Double = 0, retrying: Bool = false, finished: Bool = false) {
        guard let song = current else { return }
        queueFinished = finished
        playbackIssue = nil
        stallTask?.cancel()
        stallTask = nil
        itemStatus = nil
        retryPosition = position
        if finished {
            currentItem = nil
            preloadedItem = nil
            elapsed = 0
            duration = Double(song.duration ?? 0)
            trackChanged(announce: false)
            return
        }
        if let cast, cast.isCasting {
            avPlayer.pause()
            avPlayer.removeAllItems()
            currentItem = nil
            preloadedItem = nil
            elapsed = position
            duration = Double(song.duration ?? 0)
            scrobbled = false
            loadCastQueue(cast, position: position, autoPlay: autoPlay)
            trackChanged(announce: autoPlay && !retrying, resetHistory: !retrying)
            return
        }
        avPlayer.removeAllItems()
        preloadedItem = nil
        let item = makeItem(song)
        currentItem = item
        avPlayer.insert(item, after: nil)
        observeItemStatus(item)
        if position > 0 { item.seek(to: CMTime(seconds: position, preferredTimescale: 600), completionHandler: nil) }
        elapsed = position
        duration = Double(song.duration ?? 0)
        scrobbled = false
        applyGain(song)
        preloadNext()
        if autoPlay {
            activateSession()
            avPlayer.play()
        }
        trackChanged(announce: autoPlay && !retrying, resetHistory: !retrying)
    }

    private func preloadNext() {
        if let p = preloadedItem { avPlayer.remove(p); preloadedItem = nil }
        guard repeatMode != .one, currentItem != nil else { return }
        let nextSong: Song?
        if queue.indices.contains(index + 1) { nextSong = queue[index + 1] }
        else if repeatMode == .all, !queue.isEmpty { nextSong = queue[repeatStartIndex] }
        else { nextSong = nil }
        guard let nextSong, !nextSong.isRadio else { return }
        let item = makeItem(nextSong)
        if avPlayer.canInsert(item, after: currentItem) {
            avPlayer.insert(item, after: currentItem)
            preloadedItem = item
        }
    }

    private func queueEdited() {
        if let cast, cast.isCasting, current != nil {
            loadCastQueue(cast, position: elapsed, autoPlay: isPlaying)
        } else {
            preloadNext()
        }
        scheduleQueueSave()
        onStateChange?()
        Task { await fillAutoplayIfNeeded() }
    }

    private func playbackURL(for song: Song) -> URL? {
        if let radio = radioURLs[song.id] { return radio }
        if let local = downloads?.localURL(for: song.id) { return local }
        let quality = streamingQuality
        return client?.streamURL(song.id, maxBitRate: quality.bitRate, format: quality.format)
    }

    var streamingQuality: (bitRate: Int, format: String) {
        let defaults = UserDefaults.standard
        let format = defaults.string(forKey: Pref.format) ?? "raw"
        #if os(iOS)
        if StreamingConnection.shared.isCellular,
           let cellularRate = defaults.object(forKey: Pref.cellularBitRate) as? Int, cellularRate >= 0 {
            if cellularRate == 0 { return (0, "raw") }
            return (cellularRate, format == "raw" ? "mp3" : format)
        }
        #endif
        return (defaults.integer(forKey: Pref.maxBitRate), format)
    }

    private func makeItem(_ song: Song) -> AVPlayerItem {
        let url = playbackURL(for: song) ?? URL(string: "about:blank")!
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        item.preferredForwardBufferDuration = 30
        return item
    }

    private func currentItemChanged() {
        guard playbackIssue == nil else { return }
        if let currentItem, currentItem.status == .failed {
            itemFailed(currentItem)
            return
        }
        let item = avPlayer.currentItem
        if let item, item === preloadedItem {
            if index + 1 < queue.count { index += 1 }
            else { wrapRepeatQueue() }
            stallTask?.cancel()
            stallTask = nil
            currentItem = item
            observeItemStatus(item)
            preloadedItem = nil
            elapsed = 0
            retryPosition = 0
            duration = Double(current?.duration ?? 0)
            scrobbled = false
            if let song = current { applyGain(song) }
            preloadNext()
            trackChanged(announce: true)
            syncStatus()
        } else if item == nil, currentItem != nil, repeatMode != .one {
            currentItem = nil
            finishQueue()
        }
    }

    private func finishQueue() {
        guard !queueFinished, let song = current else { return }
        queueFinished = true
        if !isCasting { avPlayer.pause() }
        isPlaying = false
        isBuffering = false
        elapsed = 0
        updateNowPlaying()
        scheduleQueueSave(immediately: true)
        onStateChange?()
        guard autoplay else { return }
        Task {
            await fillAutoplayIfNeeded(force: true)
            guard queueFinished, current?.id == song.id, index + 1 < queue.count else { return }
            index += 1
            startCurrent()
        }
    }

    private func itemDidEnd(_ item: AVPlayerItem?) {
        guard repeatMode == .one, let item, item === currentItem else { return }
        avPlayer.seek(to: .zero)
        avPlayer.play()
        scrobbled = false
        if let song = current { scrobble(song, submission: false) }
    }

    private func observeItemStatus(_ item: AVPlayerItem) {
        itemStatus = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            if item.status == .failed { Task { @MainActor in self?.itemFailed(item) } }
        }
    }

    private func itemFailed(_ item: AVPlayerItem) {
        guard item === currentItem, !isCasting else { return }
        showPlaybackIssue("This track couldn’t be played.")
    }

    private func showPlaybackIssue(_ message: String) {
        guard playbackIssue == nil, current != nil else { return }
        playbackIssue = message
        stallTask?.cancel()
        stallTask = nil
        if !isCasting { avPlayer.pause() }
        isPlaying = false
        isBuffering = false
        updateNowPlaying()
        onStateChange?()
    }

    private func syncStatus() {
        guard !isCasting else { return }
        let active = playbackIssue == nil && !queueFinished && currentItem != nil
        let waiting = avPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate && active
        isPlaying = avPlayer.timeControlStatus != .paused && active
        isBuffering = waiting
        if !waiting {
            stallTask?.cancel()
            stallTask = nil
        } else if stallTask == nil, let item = currentItem {
            stallTask = Task { [weak self, weak item] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self, let item, currentItem === item, isBuffering else { return }
                showPlaybackIssue("The stream stopped responding.")
            }
        }
        updateNowPlaying()
        onStateChange?()
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite, currentItem != nil, playbackIssue == nil else { return }
        elapsed = seconds
        if avPlayer.timeControlStatus == .playing {
            retryPosition = seconds
            recordListeningHistory()
        }
        if let d = avPlayer.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
        checkScrobble()
        if abs(seconds - lastNowPlayingPush) > 15 {
            lastNowPlayingPush = seconds
            updateNowPlaying()
            scheduleQueueSave()
        }
    }

    private func trackChanged(announce: Bool, resetHistory: Bool = true) {
        if resetHistory { recordedCurrent = false }
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
        if !queueFinished { Task { await fillAutoplayIfNeeded() } }
    }

    private func recordListeningHistory() {
        guard !recordedCurrent, elapsed > 0, let song = current, !song.isRadio, let queueAccount else { return }
        recordedCurrent = true
        listeningHistory.insert(ListeningHistoryEntry(id: UUID(), song: song, playedAt: Date()), at: 0)
        if listeningHistory.count > 100 { listeningHistory.removeLast(listeningHistory.count - 100) }
        if let data = try? JSONEncoder().encode(listeningHistory) {
            UserDefaults.standard.set(data, forKey: "listeningHistory.\(queueAccount)")
        }
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
        guard autoplay, repeatMode == .off, current?.id == seed.id, self.client === client else { return }
        let existing = Set(queue.suffix(200).map(\.id))
        songs = songs.filter { !existing.contains($0.id) }.uniqued()
        guard !songs.isEmpty else { return }
        if autoplayStart == nil || autoplayStart! > queue.count { autoplayStart = queue.count }
        queue.append(contentsOf: songs)
        if preloadedItem == nil, currentItem != nil { preloadNext() }
        onStateChange?()
    }

    // MARK: - Google Cast

    private func loadCastQueue(_ cast: CastManager, position: Double, autoPlay: Bool) {
        cast.load(Array(queue[index...].prefix(repeatMode == .one ? 1 : 100)), startingAt: index,
                  position: position, autoplay: autoPlay)
    }

    /// Hands the current queue to the receiver and pauses local playback.
    func castDidStart() {
        guard current != nil else { return }
        let wasPlaying = isPlaying
        startCurrent(autoPlay: wasPlaying, at: elapsed)
    }

    /// Back to the phone, paused where the receiver left off.
    func castDidEnd(position: Double) {
        guard current != nil else { return }
        startCurrent(autoPlay: false, at: position, finished: queueFinished)
        isPlaying = false
    }

    func castTick(position: Double) {
        guard position.isFinite, playbackIssue == nil, !queueFinished, current != nil else { return }
        elapsed = position
        if isPlaying {
            retryPosition = position
            recordListeningHistory()
        }
        checkScrobble()
    }

    func castStatus(queueIndex: Int?, playing: Bool, position: Double) {
        guard !queueFinished, current != nil else { return }
        if isPlaying != playing {
            isPlaying = playing
            onStateChange?()
        }
        if position.isFinite { elapsed = position }
        if let queueIndex, queue.indices.contains(queueIndex), queueIndex != index {
            index = queueIndex
            duration = Double(current?.duration ?? 0)
            scrobbled = false
            retryPosition = max(0, elapsed)
            trackChanged(announce: true)
        }
        updateNowPlaying()
    }

    func castFailed() {
        guard isCasting else { return }
        showPlaybackIssue("The Cast device couldn’t play this track.")
    }

    /// The receiver played everything it was given; continue with the rest of the queue or Autoplay.
    func castQueueFinished() {
        guard isCasting else { return }
        if repeatMode == .one { startCurrent() }
        else if repeatMode == .all || index + 1 < queue.count { next() }
        else { finishQueue() }
    }

    private func checkScrobble() {
        if !scrobbled, let song = current, !song.isRadio, duration > 30, elapsed >= min(duration / 2, 240) {
            scrobbled = true
            scrobble(song, submission: true)
        }
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
    private func activateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    nonisolated private static func mediaArtwork(_ image: PlatformImage) -> MPMediaItemArtwork {
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
        handle(center.stopCommand) { $0.stop() }
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

/// Incoming and outgoing handoffs are staged separately from the player’s live queue.
@MainActor
final class PlaybackEndpoint {
    private let player: Player
    private var staged: (id: String, transfer: PlaybackTransfer, expiry: Date)?
    private var released: (id: String, transfer: PlaybackTransfer, expiry: Date)?
    private var lastCommit: String?

    init(player: Player) { self.player = player }

    func handle(_ command: WatchCommand, _ message: [String: Any]) async -> [String: Any]? {
        let id = message[WatchKey.transaction] as? String ?? ""
        switch command {
        case .snapshot:
            guard let data = player.transferSnapshot?.encoded else { return failure }
            return [WatchKey.success: true, WatchKey.transfer: data]
        case .release:
            if let released, released.expiry <= Date() { self.released = nil }
            if let released, released.id == id, let data = released.transfer.encoded {
                return [WatchKey.success: true, WatchKey.transfer: data]
            }
            guard released == nil, !id.isEmpty, let snapshot = player.transferSnapshot,
                  snapshot.song?.id == message[WatchKey.songID] as? String,
                  let data = snapshot.encoded else { return failure }
            released = (id, snapshot, Date().addingTimeInterval(60))
            player.pause()
            return [WatchKey.success: true, WatchKey.transfer: data]
        case .prepare:
            guard !id.isEmpty, let transfer = PlaybackTransfer.decode(message[WatchKey.transfer]),
                  await player.canReceive(transfer),
                  staged == nil || staged?.id == id || (staged?.expiry ?? .distantPast) <= Date() else { return failure }
            staged = (id, transfer, Date().addingTimeInterval(30))
            return success
        case .commit:
            if lastCommit == id { return success }
            guard let staged, staged.id == id, staged.expiry > Date(), !player.isCasting else { return failure }
            self.staged = nil
            lastCommit = id
            let requestedPosition = message[WatchKey.elapsed] as? Double ?? staged.transfer.position
            let position = requestedPosition.isFinite ? max(0, requestedPosition) : staged.transfer.position
            player.receive(PlaybackTransfer(queue: staged.transfer.queue, index: staged.transfer.index,
                                            position: position, playing: message[WatchKey.isPlaying] as? Bool ?? staged.transfer.playing,
                                            manualIndexes: staged.transfer.manualIndexes,
                                            autoplayStart: staged.transfer.autoplayStart))
            return success
        case .committed:
            return lastCommit == id ? success : failure
        case .cancel:
            if staged?.id == id { staged = nil }
            if let released, released.id == id {
                self.released = nil
                if released.transfer.playing, player.current?.id == released.transfer.song?.id { player.resume() }
            }
            return success
        case .finish:
            if let released, released.id == id {
                self.released = nil
                if let current = player.transferSnapshot, !current.playing,
                   current.index == released.transfer.index, current.queue == released.transfer.queue {
                    player.releaseForTransfer()
                }
            }
            return success
        default:
            return nil
        }
    }

    private var success: [String: Any] { [WatchKey.success: true] }
    private var failure: [String: Any] { [WatchKey.success: false] }
}
