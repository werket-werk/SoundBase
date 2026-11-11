import Foundation

/// Keys and commands shared by the iPhone app and the Watch companion.
enum WatchKey {
    static let title = "title"
    static let artist = "artist"
    static let album = "album"
    static let isPlaying = "isPlaying"
    static let duration = "duration"
    static let elapsed = "elapsed"
    static let timestamp = "ts"
    static let artwork = "artwork"
    static let loved = "loved"
    static let upNext = "upNext"
    static let command = "cmd"
    static let index = "index"
    static let credentials = "creds"
    static let accent = "accent"
    static let songID = "songID"
    static let destination = "destination"
    static let devices = "devices"
    static let transfer = "transfer"
    static let success = "success"
    static let account = "account"
    static let uncertain = "uncertain"
    static let transaction = "transaction"
}

enum WatchCommand: String {
    case togglePlay, pause, next, previous, love, requestState, shuffleFavourites, shuffleAll, jump
    case snapshot, release, prepare, commit, cancel, committed, finish
}

enum PlaybackDevice: String, Codable, CaseIterable, Identifiable {
    case watch, phone, mac

    var id: Self { self }
    var name: String {
        switch self {
        case .watch: "Apple Watch"
        case .phone: "iPhone"
        case .mac: "Mac"
        }
    }
    var icon: String {
        switch self {
        case .watch: "applewatch"
        case .phone: "iphone"
        case .mac: "desktopcomputer"
        }
    }
}

struct PlaybackTransfer: Codable {
    let queue: [Song]
    let index: Int
    let position: Double
    let playing: Bool
    var manualIndexes: IndexSet? = nil
    var autoplayStart: Int? = nil

    var song: Song? { queue.indices.contains(index) ? queue[index] : nil }

    var encoded: Data? {
        guard let json = try? JSONEncoder().encode(self),
              let compressed = try? (json as NSData).compressed(using: .lzfse),
              compressed.length <= 58_000 else { return nil }
        return compressed as Data
    }

    static func decode(_ data: Any?) -> Self? {
        guard let data = data as? Data, data.count <= 58_000,
              let json = try? (data as NSData).decompressed(using: .lzfse), json.length <= 4_000_000,
              let transfer = try? JSONDecoder().decode(Self.self, from: json as Data),
              transfer.song != nil, transfer.position.isFinite, transfer.position >= 0,
              !transfer.queue.contains(where: \.isRadio) else { return nil }
        return transfer
    }
}
