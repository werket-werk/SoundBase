#if DEBUG
import SwiftUI

/// Debug-only automation for App Store screenshots of the Watch app (not in release builds).
/// Environment: SB_DEMO_SERVER / SB_DEMO_USER / SB_DEMO_PASS, and
/// SB_SCENE = home | remote | album | downloaded | nowplaying
@MainActor
enum WatchScreenshotDirector {
    static func run(store: WatchStore, session: WatchSession) async {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["SB_DEMO_SERVER"], let user = env["SB_DEMO_USER"], let pass = env["SB_DEMO_PASS"],
              let url = URL(string: server) else { return }
        let creds = SubsonicClient.makeCredentials(url: url, username: user, password: pass)
        if let data = try? JSONEncoder().encode(creds) { store.setCredentials(data) }
        guard let client = store.client else { return }
        let scene = env["SB_SCENE"] ?? "home"

        guard let hit = try? await client.search("Midnight Signals", artists: 0, albums: 3, songs: 0).album?.first,
              let album = try? await client.album(hit.id), let songs = album.song, !songs.isEmpty else { return }

        // Pretend the iPhone is playing something, so the remote screens have content.
        session.title = songs[0].title
        session.artist = songs[0].artist ?? ""
        session.isPlaying = true
        session.duration = Double(songs[0].duration ?? 200)
        session.elapsedAt = 64
        session.timestamp = Date().timeIntervalSince1970
        session.loved = true
        session.reachable = true
        session.upNext = songs.dropFirst().map { "\($0.title) — \($0.artist ?? "")" }
        if let cover = songs[0].coverArt, let (data, _) = try? await URLSession.shared.data(from: client.coverURL(cover, size: 160)) {
            session.artwork = UIImage(data: data)
        }

        switch scene {
        case "remote":
            store.path = [.nowPlaying]
        case "album":
            store.downloads.download(Array(songs.prefix(3)))
            try? await Task.sleep(for: .seconds(4))
            store.path = [.album(id: album.id, name: album.name)]
        case "downloaded":
            store.downloads.download(songs)
            if let other = try? await client.search("Saltwater", artists: 0, albums: 1, songs: 0).album?.first,
               let more = try? await client.album(other.id)?.song {
                store.downloads.download(more)
            }
            try? await Task.sleep(for: .seconds(8))
            store.path = [.downloaded]
        case "nowplaying":
            session.reachable = false
            await session.play(songs)
            try? await Task.sleep(for: .seconds(2))
            store.path = [.nowPlaying]
        default:
            break
        }
    }
}
#endif
