#if DEBUG
import SwiftUI
import AppKit

/// Debug-only automation for Mac App Store screenshots (not compiled into release builds).
/// Environment: SB_DEMO_SERVER / SB_DEMO_USER / SB_DEMO_PASS, SB_SCENE, SB_SNAPSHOT (output PNG path).
/// The window is sized to 1440 × 900 points and rendered at 2× (2880 × 1800), then the app quits.
@MainActor
enum MacScreenshotDirector {
    static func run(_ model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        guard let scene = env["SB_SCENE"] else { return }
        if model.client == nil, let server = env["SB_DEMO_SERVER"], let user = env["SB_DEMO_USER"], let pass = env["SB_DEMO_PASS"] {
            try? await model.signIn(server: server, username: user, password: pass)
            try? await Task.sleep(for: .seconds(1))
        }
        guard let client = model.client else { return }
        let router = model.router
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            window.setFrame(NSRect(x: 80, y: 80, width: 1440, height: 900), display: true)
        }
        try? await Task.sleep(for: .milliseconds(500))

        func album(_ name: String) async -> AlbumDetail? {
            guard let hit = try? await client.search(name, artists: 0, albums: 5, songs: 0).album?.first(where: { $0.name == name }) else { return nil }
            return try? await client.album(hit.id)
        }
        if let songs = await album("Midnight Signals")?.song {
            model.player.play(songs)
            try? await Task.sleep(for: .milliseconds(800))
            if let seek = env["SB_SEEK"].flatMap(Double.init) { model.player.seek(to: seek) }
            if env["SB_PAUSE"] != nil { model.player.pause() }
        }

        let parts = scene.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "album":
            if let a = await album(arg) { router.go(.album(a.id)) }
        case "artist":
            if let a = try? await client.search(arg, artists: 3, albums: 0, songs: 0).artist?.first { router.go(.artist(a.id)) }
        case "playlist":
            if let p = try? await client.playlists().first(where: { $0.name == arg }) { router.initialSection = "playlist:\(p.id)" }
        case "lyrics", "queue":
            router.initialNowPlayingPanel = parts[0]
        case "albums", "radio":
            router.initialSection = parts[0]
        case "search":
            router.initialSection = "search:\(arg)"
        default:
            break
        }
        if let extra = env["SB_INSPECTOR"] { router.initialNowPlayingPanel = extra }

        try? await Task.sleep(for: .seconds(Double(env["SB_WAIT"] ?? "4") ?? 4))
        if let path = env["SB_SNAPSHOT"] { snapshot(to: path) }
        NSApp.terminate(nil)
    }

    /// Captures this app's own window (no Screen Recording permission is needed for your own windows).
    private static func snapshot(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "CGWindowListCreateImage") else { return }
        let create = unsafeBitCast(sym, to: CreateImage.self)
        // kCGWindowListOptionIncludingWindow = 1 << 3; imageOption: boundsIgnoreFraming (1 << 0) | bestResolution (1 << 3)
        guard let image = create(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
