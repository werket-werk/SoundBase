import AVFoundation
import Foundation
import Observation

struct OfflineAlbum: Identifiable, Codable {
    let id: String
    let name: String
    let tracks: [Song]

    var trackIDs: Set<String> { Set(tracks.map(\.id)) }
}

@Observable @MainActor
final class DownloadManager {
    private struct Catalog: Codable {
        var owners = DownloadedPlaylistIndex()
        var albums: [String: OfflineAlbum] = [:]
        var requests: [String: Song] = [:]
        var stored: [String: Song] = [:]
        var failures: [String: String] = [:]
        var discarded: [String: Song] = [:]

        func retains(_ id: String) -> Bool {
            owners.retains(id) || albums.values.contains { $0.tracks.contains { $0.id == id } }
        }
    }

    private var catalog = Catalog()
    private(set) var inProgress: Set<String> = []
    private(set) var storageIssue: String?

    var songs: [String: Song] { catalog.stored }
    var playlistIndex: DownloadedPlaylistIndex { catalog.owners }
    var failedDownloads: Set<String> { Set(catalog.failures.keys) }
    var downloadIssue: String? { storageIssue ?? catalog.failures.values.sorted().first }
    var missingStandaloneTracks: [Song] {
        sorted(catalog.requests.values.filter { catalog.owners.standaloneIDs.contains($0.id) && !isDownloaded($0.id) })
    }
    var playlists: [DownloadedPlaylist] {
        playlistIndex.playlists.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var client: SubsonicClient? {
        didSet {
            if let client, client.creds.libraryKey != libraryKey {
                openLibrary(client.creds.libraryKey, directory: client.creds.downloadDirectory(in: root))
            } else if client == nil {
                resetQueue()
                #if !os(watchOS)
                libraryKey = nil
                canWrite = false
                catalog = Catalog()
                storageIssue = nil
                #endif
            }
            resume()
        }
    }
    @ObservationIgnored private var pending: [Song] = []
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var libraryKey: String?
    private var canWrite = false
    @ObservationIgnored private let root: URL
    @ObservationIgnored private var dir: URL
    @ObservationIgnored private var catalogURL: URL { dir.appendingPathComponent("catalog.json") }

    #if os(watchOS)
    static let watchQuality = 128
    private let concurrency = 2
    private let defaultSuffix = "aac"
    #else
    private let concurrency = 3
    private let defaultSuffix = "mp3"
    #endif

    #if os(iOS)
    @ObservationIgnored private lazy var wifiSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = false
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()
    #endif

    init(root: URL? = nil) {
        #if os(watchOS)
        let defaultRoot = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Music", isDirectory: true)
        #else
        let defaultRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        #endif
        self.root = root ?? defaultRoot
        dir = self.root
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        #if !os(watchOS)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = self.root
        try? folder.setResourceValues(values)
        #endif
    }

    #if os(watchOS)
    func openOfflineLibrary(_ key: String?) {
        openLibrary(key, directory: key.map { root.appendingPathComponent($0, isDirectory: true) } ?? root)
    }

    func artworkURL(_ id: String) -> URL { dir.appendingPathComponent("cover-\(id).jpg") }
    #endif

    private func openLibrary(_ key: String?, directory: URL) {
        resetQueue()
        libraryKey = key
        dir = directory
        catalog = Catalog()
        storageIssue = nil
        canWrite = false
        do {
            var loaded: Catalog
            if let saved: Catalog = try read("catalog.json") {
                loaded = saved
            } else {
                let legacy: [Song]? = try read("index.json")
                let owners: DownloadedPlaylistIndex? = try read("playlists.json")
                guard legacy != nil || owners != nil else {
                    canWrite = key != nil
                    return
                }
                loaded = Catalog()
                loaded.stored = Dictionary((legacy ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                loaded.owners = owners ?? DownloadedPlaylistIndex()
                for id in loaded.stored.keys where !loaded.retains(id) {
                    loaded.owners.standaloneIDs.insert(id)
                }
            }
            for track in loaded.owners.playlists.values.flatMap(\.tracks) where !track.isRadio {
                if loaded.requests[track.id] == nil { loaded.requests[track.id] = track }
            }
            var unreadableFiles = false
            for (id, track) in loaded.stored {
                if loaded.requests[id] == nil { loaded.requests[id] = track }
                let file = fileURL(track)
                do {
                    if try Self.hasAudioBody(file) {
                        loaded.failures[id] = nil
                    } else {
                        loaded.stored[id] = nil
                        loaded.discarded[file.lastPathComponent] = track
                    }
                } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                    loaded.stored[id] = nil
                } catch {
                    unreadableFiles = true
                }
            }
            catalog = loaded
            canWrite = true
            if commit(loaded) {
                cleanDiscarded()
                if unreadableFiles && storageIssue == nil {
                    storageIssue = "Some downloaded files couldn’t be checked."
                }
            }
        } catch {
            storageIssue = "Couldn’t read the download catalog."
        }
    }

    private func read<T: Decodable>(_ name: String) throws -> T? {
        do {
            return try JSONDecoder().decode(T.self, from: Data(contentsOf: dir.appendingPathComponent(name)))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }

    private func resetQueue() {
        generation = UUID()
        pending.removeAll()
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        inProgress.removeAll()
    }

    var albums: [OfflineAlbum] {
        let claimed = Set(catalog.albums.values.flatMap(\.trackIDs))
        let grouped = Dictionary(grouping: songs.values.filter { !claimed.contains($0.id) }, by: \.offlineAlbumKey)
        let inferred = grouped.compactMap { id, tracks -> OfflineAlbum? in
            guard catalog.albums[id] == nil else { return nil }
            return OfflineAlbum(id: id, name: tracks.first?.album ?? "Unknown Album", tracks: sorted(tracks))
        }
        return (Array(catalog.albums.values) + inferred).sorted {
            ($0.name, $0.id) < ($1.name, $1.id)
        }
    }

    func downloadAlbum(id: String, name: String, tracks: [Song]) {
        downloadAlbum(OfflineAlbum(id: "id:\(id)", name: name, tracks: tracks))
    }

    func status(for tracks: [Song]) -> String {
        let ids = Set(tracks.filter { !$0.isRadio }.map(\.id))
        let available = ids.filter(isDownloaded).count
        if available == ids.count { return "Ready to Play Offline" }
        if !inProgress.isDisjoint(with: ids) { return "Downloading · \(available) of \(ids.count) saved" }
        return "\(available) of \(ids.count) downloaded"
    }

    func savedAlbum(_ id: String) -> OfflineAlbum? { catalog.albums[id] }
    func failure(for id: String) -> String? { catalog.failures[id] }
    func canRemoveTrack(_ id: String) -> Bool { playlistIndex.standaloneIDs.contains(id) }
    func canRequestDownloads() -> Bool { client != nil && canWrite }

    var sortedSongs: [Song] {
        #if os(watchOS)
        sorted(Array(songs.values))
        #else
        songs.values.sorted {
            ($0.artist ?? "", $0.album ?? "", $0.discNumber ?? 0, $0.track ?? 0, $0.title, $0.id)
                < ($1.artist ?? "", $1.album ?? "", $1.discNumber ?? 0, $1.track ?? 0, $1.title, $1.id)
        }
        #endif
    }

    private func sorted(_ tracks: [Song]) -> [Song] {
        tracks.sorted {
            ($0.album ?? "", $0.discNumber ?? 0, $0.track ?? 0, $0.title, $0.id)
                < ($1.album ?? "", $1.discNumber ?? 0, $1.track ?? 0, $1.title, $1.id)
        }
    }

    func isDownloaded(_ id: String) -> Bool { localURL(for: id) != nil }

    func localURL(for id: String) -> URL? {
        guard let song = songs[id] else { return nil }
        let url = fileURL(song)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func download(_ tracks: [Song]) {
        let tracks = tracks.filter { !$0.isRadio }
        request(tracks) { $0.owners.standaloneIDs.formUnion(tracks.map(\.id)) }
    }

    func downloadAlbum(_ album: OfflineAlbum) {
        let tracks = album.tracks.filter { !$0.isRadio }
        request(tracks) { $0.albums[album.id] = OfflineAlbum(id: album.id, name: album.name, tracks: tracks) }
    }

    func downloadPlaylist(_ playlist: DownloadedPlaylist) {
        let tracks = playlist.tracks.filter { !$0.isRadio }
        request(tracks) {
            $0.owners.playlists[playlist.id] = DownloadedPlaylist(id: playlist.id, name: playlist.name, tracks: tracks)
        }
    }

    private func request(_ tracks: [Song], update: (inout Catalog) -> Void) {
        guard canRequestDownloads(), !tracks.isEmpty else { return }
        var next = catalog
        update(&next)
        for track in tracks {
            next.requests[track.id] = track
            next.failures[track.id] = nil
        }
        if applyOwnership(next) { enqueue(tracks) }
    }

    func remove(_ id: String) {
        removeTracks([id])
    }

    func removeTracks(_ ids: [String]) {
        guard !catalog.owners.standaloneIDs.isDisjoint(with: ids) else { return }
        var next = catalog
        next.owners.standaloneIDs.subtract(ids)
        applyOwnership(next)
    }

    func removeAlbum(_ id: String) {
        var next = catalog
        guard next.albums.removeValue(forKey: id) != nil else { return }
        applyOwnership(next)
    }

    func removePlaylist(_ id: String) {
        var next = catalog
        guard next.owners.playlists.removeValue(forKey: id) != nil else { return }
        applyOwnership(next)
    }

    func removeAll() {
        var next = catalog
        next.owners = DownloadedPlaylistIndex()
        next.albums.removeAll()
        applyOwnership(next)
    }

    @discardableResult
    private func applyOwnership(_ updated: Catalog) -> Bool {
        var next = updated
        let removed = Set(next.requests.keys).union(next.stored.keys).filter { !next.retains($0) }
        for id in removed {
            next.requests[id] = nil
            next.failures[id] = nil
            if let track = next.stored.removeValue(forKey: id) {
                next.discarded[fileURL(track).lastPathComponent] = track
            }
        }
        guard commit(next) else { return false }
        pending.removeAll { removed.contains($0.id) }
        for id in removed {
            tasks.removeValue(forKey: id)?.cancel()
            inProgress.remove(id)
        }
        cleanDiscarded()
        pump()
        return true
    }

    private func resume() {
        guard canRequestDownloads() else { return }
        let unfinished = catalog.requests.values.filter { catalog.stored[$0.id] == nil && catalog.failures[$0.id] == nil }
        enqueue(sorted(unfinished))
    }

    private func enqueue(_ tracks: [Song]) {
        for song in tracks where !song.isRadio && catalog.retains(song.id)
            && !isDownloaded(song.id) && !inProgress.contains(song.id) {
            inProgress.insert(song.id)
            pending.append(song)
        }
        pump()
    }

    private func pump() {
        guard client != nil else { return }
        while tasks.count < concurrency, !pending.isEmpty {
            let song = pending.removeFirst()
            let generation = generation
            tasks[song.id] = Task {
                await fetch(song, generation: generation)
                guard self.generation == generation, !Task.isCancelled else { return }
                inProgress.remove(song.id)
                tasks[song.id] = nil
                pump()
            }
        }
    }

    private func isCurrent(_ id: String, generation: UUID) -> Bool {
        self.generation == generation && !Task.isCancelled && catalog.retains(id)
    }

    private func fetch(_ song: Song, generation: UUID) async {
        guard isCurrent(song.id, generation: generation), let client else { return }
        var stored = song
        let url: URL
        #if os(watchOS)
        if song.shouldTranscode(toKbps: Self.watchQuality) {
            url = client.streamURL(song.id, maxBitRate: Self.watchQuality, format: "aac")
            stored.suffix = "aac"
            stored.bitRate = Self.watchQuality
        } else {
            url = client.downloadURL(song.id)
        }
        #else
        let defaults = UserDefaults.standard
        let quality = defaults.object(forKey: Pref.downloadQuality) as? Int ?? Pref.defaultDownloadQuality
        let format = DownloadFormat.selected(quality: quality, format: defaults.string(forKey: Pref.downloadFormat) ?? "")
        let optimizeLossless = defaults.object(forKey: Pref.optimizeLosslessDownloads) as? Bool
            ?? Pref.defaultOptimizeLosslessDownloads
        let needsConversion = format.shouldConvert(song, quality: quality, optimizeLossless: optimizeLossless)
        url = needsConversion ? client.streamURL(song.id, maxBitRate: quality, format: format.rawValue)
            : client.downloadURL(song.id)
        if needsConversion {
            stored.suffix = format.rawValue
            stored.bitRate = quality
        }
        #endif

        let session: URLSession
        #if os(iOS)
        session = defaults.bool(forKey: Pref.wifiOnlyDownloads) ? wifiSession : .shared
        #else
        session = .shared
        #endif

        do {
            let (tmp, response) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard isCurrent(song.id, generation: generation) else { return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  try Self.hasAudioBody(tmp) else { throw DownloadError.invalidResponse }

            #if !os(watchOS)
            if (needsConversion || !optimizeLossless) && (format == .mp3 || format == .opus) {
                let suffix = try Self.containerSuffix(for: format, in: tmp)
                let staged = tmp.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).\(suffix)")
                try FileManager.default.moveItem(at: tmp, to: staged)
                defer { try? FileManager.default.removeItem(at: staged) }
                guard await Self.isPlayable(staged, as: format) else { throw DownloadError.unsupportedFormat }
                guard isCurrent(song.id, generation: generation) else { return }
                stored.suffix = suffix
                install(stored, from: staged)
                return
            }
            #endif

            install(stored, from: tmp)
            #if os(watchOS)
            if isDownloaded(song.id), let cover = song.coverArt,
               !FileManager.default.fileExists(atPath: artworkURL(cover).path),
               let (data, _) = try? await session.data(from: client.coverURL(cover, size: 300)),
               isCurrent(song.id, generation: generation) {
                try? data.write(to: artworkURL(cover), options: .atomic)
            }
            #endif
        } catch {
            guard isCurrent(song.id, generation: generation) else { return }
            #if !os(watchOS)
            if case DownloadError.unsupportedFormat = error {
                recordFailure(song.id, "Couldn’t download \(song.title). The server didn’t return playable \(format.title) audio.")
                return
            }
            #endif
            recordFailure(song.id, "Couldn’t download \(song.title). Check your connection and server, then try again.")
        }
    }

    private enum DownloadError: Error { case invalidResponse, unsupportedFormat }

    private func install(_ track: Song, from source: URL) {
        let destination = fileURL(track)
        // Record the destination first so an interrupted install can be reconciled on launch.
        var next = catalog
        next.stored[track.id] = track
        next.failures[track.id] = nil
        next.discarded[destination.lastPathComponent] = nil
        do {
            try write(next)
        } catch {
            reportStorageFailure(track)
            return
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
            } else {
                try FileManager.default.moveItem(at: source, to: destination)
            }
            catalog = next
            storageIssue = nil
        } catch {
            reportStorageFailure(track)
        }
    }

    private func reportStorageFailure(_ track: Song) {
        let message = "Couldn’t save \(track.title). Check available storage and try again."
        recordFailure(track.id, message)
        storageIssue = message
    }

    private func recordFailure(_ id: String, _ message: String) {
        var next = catalog
        next.failures[id] = message
        if !commit(next) { catalog.failures[id] = message }
    }

    private func fileURL(_ song: Song) -> URL {
        dir.appendingPathComponent("\(song.id).\(song.suffix ?? defaultSuffix)")
    }

    private func write(_ next: Catalog) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: catalogURL, options: .atomic)
    }

    @discardableResult
    private func commit(_ next: Catalog) -> Bool {
        guard canWrite else { return false }
        do {
            try write(next)
            catalog = next
            storageIssue = nil
            return true
        } catch {
            storageIssue = "Couldn’t update downloads. Check available storage and try again."
            return false
        }
    }

    private func cleanDiscarded() {
        var next = catalog
        var failed = false
        for (name, track) in catalog.discarded {
            do {
                try FileManager.default.removeItem(at: fileURL(track))
                next.discarded[name] = nil
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                next.discarded[name] = nil
            } catch {
                failed = true
            }
        }
        if next.discarded.count != catalog.discarded.count { commit(next) }
        if failed { storageIssue = "Some download files couldn’t be removed. Try again later." }
    }

    var totalBytes: Int64 {
        (Array(songs.values) + Array(catalog.discarded.values)).reduce(0) { total, song in
            let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL(song).path)
            return total + ((attrs?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    #if !os(watchOS)
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

    #endif

    private static func hasAudioBody(_ url: URL) throws -> Bool {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard let prefix = try file.read(upToCount: 512), !prefix.isEmpty else { return false }
        let text = String(decoding: prefix, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        return !text.hasPrefix("{") && !text.hasPrefix("[") && !text.hasPrefix("<")
    }

}
