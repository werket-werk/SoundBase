import Foundation
import Observation

/// Stores original-quality files for offline playback.
@Observable @MainActor
final class DownloadManager {
    private(set) var songs: [String: Song] = [:]
    private(set) var inProgress: Set<String> = []

    @ObservationIgnored var client: SubsonicClient?
    @ObservationIgnored private var pending: [Song] = []
    @ObservationIgnored private var active = 0
    @ObservationIgnored private let dir: URL
    @ObservationIgnored private var indexURL: URL { dir.appendingPathComponent("index.json") }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var d = dir
        try? d.setResourceValues(values)
        if let data = try? Data(contentsOf: indexURL),
           let list = try? JSONDecoder().decode([Song].self, from: data) {
            songs = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    var sortedSongs: [Song] {
        songs.values.sorted { ($0.artist ?? "", $0.album ?? "", $0.discNumber ?? 0, $0.track ?? 0) < ($1.artist ?? "", $1.album ?? "", $1.discNumber ?? 0, $1.track ?? 0) }
    }

    func isDownloaded(_ id: String) -> Bool { songs[id] != nil }

    func localURL(for id: String) -> URL? {
        guard let song = songs[id] else { return nil }
        let url = fileURL(song)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func download(_ list: [Song]) {
        for song in list where !song.isRadio && songs[song.id] == nil && !inProgress.contains(song.id) {
            inProgress.insert(song.id)
            pending.append(song)
        }
        pump()
    }

    func remove(_ id: String) {
        guard let song = songs.removeValue(forKey: id) else { return }
        try? FileManager.default.removeItem(at: fileURL(song))
        persist()
    }

    func removeAll() {
        for song in songs.values { try? FileManager.default.removeItem(at: fileURL(song)) }
        songs = [:]
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
        while active < 3, !pending.isEmpty {
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
        let quality = UserDefaults.standard.object(forKey: Pref.downloadQuality) as? Int ?? Pref.defaultDownloadQuality
        var stored = song
        let url: URL
        if song.shouldTranscode(toKbps: quality) {
            url = client.streamURL(song.id, maxBitRate: quality, format: "aac")
            stored.suffix = "aac"
            stored.bitRate = quality
        } else {
            url = client.downloadURL(song.id)
        }
        do {
            let (tmp, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 300 else { return }
            let dest = fileURL(stored)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            songs[song.id] = stored
            persist()
        } catch {
            // Leave it un-downloaded; the user can retry.
        }
    }

    private func fileURL(_ song: Song) -> URL {
        dir.appendingPathComponent("\(song.id).\(song.suffix ?? "mp3")")
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Array(songs.values)) { try? data.write(to: indexURL, options: .atomic) }
    }
}

