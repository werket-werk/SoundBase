import AVFoundation
import Foundation
import Observation

/// Stores downloaded tracks and ordered playlists for offline playback.
@Observable @MainActor
final class DownloadManager {
    private(set) var songs: [String: Song] = [:]
    private(set) var inProgress: Set<String> = []
    private(set) var downloadIssue: String?

    private(set) var playlistIndex = DownloadedPlaylistIndex()
    var playlists: [DownloadedPlaylist] {
        playlistIndex.playlists.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @ObservationIgnored var client: SubsonicClient? {
        didSet {
            if oldValue?.creds.libraryKey != client?.creds.libraryKey { loadAccount() }
        }
    }
    @ObservationIgnored private var pending: [Song] = []
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    #if os(iOS)
    @ObservationIgnored private lazy var wifiSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = false
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()
    #endif
    @ObservationIgnored private let root: URL
    @ObservationIgnored private var dir: URL
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var playlistURL: URL { dir.appendingPathComponent("playlists.json") }
    @ObservationIgnored private var indexURL: URL { dir.appendingPathComponent("index.json") }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("Downloads", isDirectory: true)
        dir = root
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var d = dir
        try? d.setResourceValues(values)
    }

    private func loadAccount() {
        generation = UUID()
        pending = []
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        inProgress = []
        downloadIssue = nil
        songs = [:]
        playlistIndex = DownloadedPlaylistIndex()
        guard let client else { return }
        dir = client.creds.downloadDirectory(in: root)
        if let data = try? Data(contentsOf: indexURL),
           let list = try? JSONDecoder().decode([Song].self, from: data) {
            songs = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            songs = songs.filter { FileManager.default.fileExists(atPath: fileURL($0.value).path) }
        }
        playlistIndex = .load(from: playlistURL, existingIDs: songs.keys)
    }

    struct OfflineAlbum: Identifiable {
        let id: String
        let tracks: [Song]
    }

    var albums: [OfflineAlbum] {
        Dictionary(grouping: sortedSongs, by: \.offlineAlbumKey).map { id, tracks in
            OfflineAlbum(id: id, tracks: tracks.sorted {
                ($0.discNumber ?? 0, $0.track ?? 0, $0.title) < ($1.discNumber ?? 0, $1.track ?? 0, $1.title)
            })
        }.sorted {
            ($0.tracks.first?.album ?? "", $0.id) < ($1.tracks.first?.album ?? "", $1.id)
        }
    }

    var sortedSongs: [Song] {
        songs.values.sorted { ($0.artist ?? "", $0.album ?? "", $0.discNumber ?? 0, $0.track ?? 0) < ($1.artist ?? "", $1.album ?? "", $1.discNumber ?? 0, $1.track ?? 0) }
    }

    func isDownloaded(_ id: String) -> Bool { localURL(for: id) != nil }

    func localURL(for id: String) -> URL? {
        guard let song = songs[id] else { return nil }
        let url = fileURL(song)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func download(_ list: [Song]) {
        guard client != nil else { return }
        playlistIndex.standaloneIDs.formUnion(list.filter { !$0.isRadio }.map(\.id))
        playlistIndex.save(to: playlistURL)
        enqueue(list)
    }

    func downloadPlaylist(_ playlist: DownloadedPlaylist) {
        guard client != nil, !playlist.tracks.isEmpty else { return }
        let previous = playlistIndex.playlists.updateValue(playlist, forKey: playlist.id)
        if let previous { removeUnreferenced(previous.trackIDs.subtracting(playlist.trackIDs)) }
        persist()
        enqueue(playlist.tracks)
    }

    private func enqueue(_ list: [Song]) {
        for song in list where !song.isRadio && localURL(for: song.id) == nil && !inProgress.contains(song.id) {
            downloadIssue = nil
            inProgress.insert(song.id)
            pending.append(song)
        }
        pump()
    }

    func remove(_ id: String) {
        playlistIndex.standaloneIDs.remove(id)
        removeFile(id)
        persist()
    }

    func removePlaylist(_ id: String) {
        guard let playlist = playlistIndex.playlists.removeValue(forKey: id) else { return }
        removeUnreferenced(playlist.trackIDs)
        persist()
    }

    private func removeUnreferenced(_ ids: Set<String>) {
        for id in ids where !playlistIndex.retains(id) {
            removeFile(id)
            if let queued = pending.firstIndex(where: { $0.id == id }) {
                pending.remove(at: queued)
                inProgress.remove(id)
            }
        }
    }

    private func removeFile(_ id: String) {
        guard let song = songs.removeValue(forKey: id) else { return }
        try? FileManager.default.removeItem(at: fileURL(song))
    }

    func removeAll() {
        generation = UUID()
        pending = []
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        inProgress = []
        downloadIssue = nil
        for id in Array(songs.keys) { removeFile(id) }
        playlistIndex = DownloadedPlaylistIndex()
        persist()
    }

    var totalBytes: Int64 {
        songs.values.reduce(0) { total, song in
            let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL(song).path)
            return total + ((attrs?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    // MARK: Private

    private func pump() {
        while tasks.count < 3, !pending.isEmpty {
            let song = pending.removeFirst()
            let generation = generation
            tasks[song.id] = Task {
                await fetch(song, generation: generation)
                guard self.generation == generation else { return }
                inProgress.remove(song.id)
                tasks[song.id] = nil
                pump()
            }
        }
    }

    private func fetch(_ song: Song, generation: UUID) async {
        guard self.generation == generation, let client else { return }
        let defaults = UserDefaults.standard
        let quality = defaults.object(forKey: Pref.downloadQuality) as? Int ?? Pref.defaultDownloadQuality
        let format = DownloadFormat.selected(quality: quality, format: defaults.string(forKey: Pref.downloadFormat) ?? "")
        let needsConversion: Bool
        switch format {
        case .original: needsConversion = false
        case .aac: needsConversion = song.shouldTranscode(toKbps: quality)
        case .mp3, .opus:
            needsConversion = song.suffix?.lowercased() != format.rawValue || song.shouldTranscode(toKbps: quality)
        }
        let url = needsConversion
            ? client.streamURL(song.id, maxBitRate: quality, format: format.rawValue)
            : client.downloadURL(song.id)

        let session: URLSession
        #if os(iOS)
        session = defaults.bool(forKey: Pref.wifiOnlyDownloads) ? wifiSession : .shared
        #else
        session = .shared
        #endif

        do {
            let (tmp, response) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard self.generation == generation, playlistIndex.retains(song.id) else { return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  Self.hasAudioBody(tmp) else { throw DownloadError.invalidResponse }

            var stored = song
            if needsConversion {
                stored.suffix = format.rawValue
                stored.bitRate = quality
            }

            if format == .mp3 || format == .opus {
                let suffix = try Self.containerSuffix(for: format, in: tmp)
                let staged = tmp.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).\(suffix)")
                try FileManager.default.moveItem(at: tmp, to: staged)
                defer { try? FileManager.default.removeItem(at: staged) }
                guard await Self.isPlayable(staged, as: format) else { throw DownloadError.unsupportedFormat }
                guard self.generation == generation, playlistIndex.retains(song.id) else { return }
                stored.suffix = suffix
                try store(stored, from: staged)
            } else {
                try store(stored, from: tmp)
            }
        } catch {
            guard self.generation == generation, playlistIndex.retains(song.id), !Task.isCancelled else { return }
            switch error {
            case DownloadError.unsupportedFormat:
                downloadIssue = "Couldn’t download \(song.title). The server didn’t return playable \(format.title) audio. Try another download format."
            default:
                downloadIssue = "Couldn’t download \(song.title). Check your connection and server, then try again."
            }
        }
    }

    private enum DownloadError: Error {
        case invalidResponse, unsupportedFormat
    }

    private func store(_ song: Song, from source: URL) throws {
        let dest = fileURL(song)
        if FileManager.default.fileExists(atPath: dest.path) {
            _ = try FileManager.default.replaceItemAt(dest, withItemAt: source)
        } else {
            try FileManager.default.moveItem(at: source, to: dest)
        }
        songs[song.id] = song
        persist()
    }

    private static func containerSuffix(for format: DownloadFormat, in url: URL) throws -> String {
        guard format == .opus else { return format.rawValue }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let header = try file.read(upToCount: 8) ?? Data()
        if header.starts(with: Data("OggS".utf8)) { return "opus" }
        if header.starts(with: Data("caff".utf8)) { return "caf" }
        if header.dropFirst(4).starts(with: Data("ftyp".utf8)) { return "mp4" }
        throw DownloadError.unsupportedFormat
    }

    private static func isPlayable(_ url: URL, as format: DownloadFormat) async -> Bool {
        let asset = AVURLAsset(url: url)
        let codec = format == .mp3 ? kAudioFormatMPEGLayer3 : kAudioFormatOpus
        guard (try? await asset.load(.isPlayable)) == true,
              let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let descriptions = try? await track.load(.formatDescriptions) else { return false }
        return descriptions.contains { $0.mediaSubType.rawValue == codec }
    }

    private static func hasAudioBody(_ url: URL) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        guard let prefix = try? file.read(upToCount: 512), !prefix.isEmpty else { return false }
        let text = String(decoding: prefix, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        return !text.hasPrefix("{") && !text.hasPrefix("[") && !text.hasPrefix("<")
    }

    private func fileURL(_ song: Song) -> URL {
        dir.appendingPathComponent("\(song.id).\(song.suffix ?? "mp3")")
    }

    private func persist() {
        playlistIndex.save(to: playlistURL)
        if let data = try? JSONEncoder().encode(Array(songs.values)) { try? data.write(to: indexURL, options: .atomic) }
    }
}

