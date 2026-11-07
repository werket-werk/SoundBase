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
}

enum WatchCommand: String {
    case togglePlay, next, previous, love, requestState, shuffleFavourites, shuffleAll, jump
}
