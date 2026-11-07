import SwiftUI
import Observation

enum AppTab: Hashable { case home, browse, radio, library, search }

enum Route: Hashable {
    case album(String)
    case artist(String)
    case playlist(String)
    case genre(String)
    case albums(title: String, type: String)
    case artists, songs, playlists, genres, loved, downloads
}

@Observable @MainActor
final class Router {
    var tab: AppTab = .home
    var homePath: [Route] = []
    var browsePath: [Route] = []
    var radioPath: [Route] = []
    var libraryPath: [Route] = []
    var searchPath: [Route] = []
    var showNowPlaying = false
    var showSettings = false
    var playlistPickerSongs: [Song]? = nil
    /// Debug screenshot mode: the panel Now Playing opens with ("lyrics" or "queue").
    var initialNowPlayingPanel: String?
    /// Debug screenshot mode: a query the Search tab starts with.
    var initialSearch: String?

    func go(_ route: Route) {
        showNowPlaying = false
        switch tab {
        case .home: homePath.append(route)
        case .browse: browsePath.append(route)
        case .radio: radioPath.append(route)
        case .library: libraryPath.append(route)
        case .search: searchPath.append(route)
        }
    }
}

@Observable @MainActor
final class AppModel {
    private(set) var credentials: ServerCredentials?
    private(set) var client: SubsonicClient?
    let player = Player()
    let downloads = DownloadManager()
    let router = Router()
    var loved: Set<String> = []
    var playlists: [Playlist] = []

    init() {
        CastManager.shared.configure()
        CastManager.shared.player = player
        player.cast = CastManager.shared
        player.downloads = downloads
        player.onLove = { [weak self] in self?.toggleLoveCurrent() }
        PhoneSession.shared.attach(model: self)
        if let saved = CredentialStore.load() { apply(saved) }
    }

    private func apply(_ creds: ServerCredentials) {
        credentials = creds
        let client = SubsonicClient(creds: creds)
        self.client = client
        player.client = client
        downloads.client = client
        PhoneSession.shared.push()
        Task {
            await refreshLoved()
            await refreshPlaylists()
            await player.restoreQueue()
            await PendingScrobbles.flush(using: client)
        }
    }

    func signIn(server: String, username: String, password: String) async throws {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.host != nil else { throw SubsonicFailure.invalidURL }
        let creds = SubsonicClient.makeCredentials(url: url, username: username, password: password)
        try await SubsonicClient(creds: creds).ping()
        CredentialStore.save(creds)
        UserDefaults.standard.set(s, forKey: Pref.lastServer)
        UserDefaults.standard.set(username, forKey: Pref.lastUser)
        apply(creds)
    }

    func signOut() {
        player.stop()
        CredentialStore.clear()
        credentials = nil
        client = nil
        player.client = nil
        loved = []
        playlists = []
    }

    // MARK: Favourites

    func refreshLoved() async {
        guard let client, let s = try? await client.starred() else { return }
        loved = Set((s.song ?? []).map(\.id) + (s.album ?? []).map(\.id) + (s.artist ?? []).map(\.id))
        PhoneSession.shared.push()
    }

    func isLoved(_ id: String) -> Bool { loved.contains(id) }

    func toggleLove(_ id: String, kind: SubsonicClient.StarKind) {
        guard let client else { return }
        let on = !loved.contains(id)
        if on { loved.insert(id) } else { loved.remove(id) }
        PhoneSession.shared.push()
        Task {
            do { try await client.setStar(id, kind: kind, on: on) }
            catch { if on { loved.remove(id) } else { loved.insert(id) } }
        }
    }

    func toggleLoveCurrent() {
        guard let song = player.current, !song.isRadio else { return }
        toggleLove(song.id, kind: .song)
    }

    // MARK: Playlists

    func refreshPlaylists() async {
        guard let client, let list = try? await client.playlists() else { return }
        playlists = list
    }

    // MARK: Mixes & stations

    func playFavouritesMix() async {
        guard let client, let s = try? await client.starred(), let songs = s.song, !songs.isEmpty else { return }
        player.play(songs, shuffled: true)
    }

    func playDiscoveryMix() async {
        guard let client, let songs = try? await client.randomSongs(size: 100), !songs.isEmpty else { return }
        player.play(songs)
    }

    func playGenreStation(_ genre: String) async {
        guard let client, let songs = try? await client.songsByGenre(genre, count: 300), !songs.isEmpty else { return }
        player.play(songs, shuffled: true)
    }

    func playArtistStation(artistId: String, name: String) async {
        guard let client else { return }
        async let similar = (try? await client.similarSongs2(artistId: artistId, count: 60)) ?? []
        async let top = (try? await client.topSongs(artist: name, count: 10)) ?? []
        var songs = await top + similar
        if songs.isEmpty, let detail = try? await client.artist(artistId) {
            for album in (detail.album ?? []).prefix(6) {
                songs += (try? await client.album(album.id))?.song ?? []
            }
        }
        guard !songs.isEmpty else { return }
        player.play(songs.uniqued(), shuffled: true)
    }

    func playSongStation(_ seed: Song) async {
        guard let client else { return }
        var songs = (try? await client.similarSongs(seed.id, count: 60)) ?? []
        if songs.isEmpty, let artistId = seed.artistId { songs = (try? await client.similarSongs2(artistId: artistId)) ?? [] }
        if songs.isEmpty { songs = (try? await client.randomSongs(size: 60)) ?? [] }
        player.play([seed] + songs.filter { $0.id != seed.id }.uniqued())
    }

    func playAlbum(_ id: String, shuffled: Bool = false) async {
        guard let client, let songs = try? await client.album(id)?.song, !songs.isEmpty else { return }
        player.play(songs, shuffled: shuffled)
    }
}

extension Array where Element == Song {
    func uniqued() -> [Song] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
    var totalDuration: Int { reduce(0) { $0 + ($1.duration ?? 0) } }
}
