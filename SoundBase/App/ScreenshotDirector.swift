#if DEBUG
import SwiftUI

/// Debug-only automation for App Store screenshots (not compiled into release builds).
/// Launch with environment variables, e.g. via `xcrun simctl launch` and the SIMCTL_CHILD_ prefix:
///   SB_DEMO_SERVER, SB_DEMO_USER, SB_DEMO_PASS  sign in to a local demo server
///   SB_SCENE  home | album:<name> | artist:<name> | playlist:<name> | nowplaying | lyrics | queue | library | search:<query>
@MainActor
enum ScreenshotDirector {
    static func run(_ model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        if model.client == nil, let server = env["SB_DEMO_SERVER"], let user = env["SB_DEMO_USER"], let pass = env["SB_DEMO_PASS"] {
            try? await model.signIn(server: server, username: user, password: pass)
        }
        guard let scene = env["SB_SCENE"], let client = model.client else { return }
        let router = model.router
        try? await Task.sleep(for: .milliseconds(600))
        let parts = scene.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""

        func album(named name: String) async -> AlbumDetail? {
            guard let hit = try? await client.search(name, artists: 0, albums: 5, songs: 0).album?.first(where: { $0.name == name }) else { return nil }
            return try? await client.album(hit.id)
        }

        if env["SB_PLAY"] != nil, let songs = await album(named: "Midnight Signals")?.song {
            model.player.play(songs)
            try? await Task.sleep(for: .milliseconds(700))
            model.player.pause()
        }

        switch parts[0] {
        case "album":
            if let a = await album(named: arg) { router.go(.album(a.id)) }
        case "artist":
            if let a = try? await client.search(arg, artists: 3, albums: 0, songs: 0).artist?.first { router.go(.artist(a.id)) }
        case "playlist":
            if let p = try? await client.playlists().first(where: { $0.name == arg }) { router.tab = .library; router.libraryPath = [.playlists, .playlist(p.id)] }
        case "library":
            router.tab = .library
        case "search":
            router.initialSearch = arg
            router.tab = .search
        case "nowplaying", "lyrics", "queue":
            guard let songs = await album(named: env["SB_ALBUM"] ?? "Midnight Signals")?.song else { return }
            model.player.play(songs)
            try? await Task.sleep(for: .seconds(1))
            if let seek = env["SB_SEEK"].flatMap(Double.init) { model.player.seek(to: seek) }
            if parts[0] != "nowplaying" { router.initialNowPlayingPanel = parts[0] }
            try? await Task.sleep(for: .milliseconds(800))
            router.showNowPlaying = true
        default:
            break
        }
    }
}
#endif
