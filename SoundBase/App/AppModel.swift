import SwiftUI
import Observation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

enum AppTab: Hashable { case home, browse, radio, library, search }

enum Route: Hashable {
    case album(String)
    case artist(String)
    case playlist(String)
    case generated(GeneratedPlaylist)
    case searchResults(String, SearchCategory)
    case radio(RadioStation)
    case genre(String)
    case albums(title: String, type: String)
    case artists, songs, playlists, genres, loved, downloads, history
}

enum GeneratedPlaylist: Hashable {
    case favourites, discovery, favouritesStation, discoveryStation
    case heavyRotation
    case genre(String)
    case artist(id: String, name: String)
    case song(Song)

    var title: String {
        switch self {
        case .favourites: "Favourites Mix"
        case .discovery: "Discovery Mix"
        case .favouritesStation: "Favourites Station"
        case .discoveryStation: "Discovery Station"
        case .heavyRotation: "Heavy Rotation"
        case .genre(let name), .artist(_, let name): "\(name) Station"
        case .song(let song): "\(song.title) Station"
        }
    }

    var kind: String {
        switch self {
        case .favourites, .discovery, .heavyRotation: "Mix"
        default: "Station"
        }
    }

    var icon: String {
        switch self {
        case .favourites, .favouritesStation: "star.fill"
        case .discovery: "sparkles"
        case .heavyRotation: "flame.fill"
        default: "dot.radiowaves.left.and.right"
        }
    }

    func tracks(using client: SubsonicClient) async throws -> [Song] {
        switch self {
        case .favourites, .favouritesStation:
            return (try await client.starred().song ?? []).uniqued().shuffled()
        case .discovery, .discoveryStation:
            return try await client.randomSongs(size: 100).uniqued()
        case .heavyRotation:
            let albums = try await client.albumList("frequent", size: 8)
            return try await albumTracks(albums, using: client).shuffled()
        case .genre(let name):
            return try await client.songsByGenre(name, count: 300).uniqued().shuffled()
        case .artist(let id, let name):
            async let similar = try? client.similarSongs2(artistId: id, count: 60)
            async let top = try? client.topSongs(artist: name, count: 10)
            let songs = (await top ?? []) + (await similar ?? [])
            if !songs.isEmpty { return songs.uniqued().shuffled() }
            let albums = try await client.artist(id)?.album ?? []
            return try await albumTracks(Array(albums.prefix(6)), using: client).shuffled()
        case .song(let seed):
            var songs = (try? await client.similarSongs(seed.id, count: 60)) ?? []
            if songs.isEmpty, let artistId = seed.artistId {
                songs = (try? await client.similarSongs2(artistId: artistId)) ?? []
            }
            if songs.isEmpty { songs = (try? await client.randomSongs(size: 60)) ?? [] }
            return ([seed] + songs).uniqued()
        }
    }

    private func albumTracks(_ albums: [Album], using client: SubsonicClient) async throws -> [Song] {
        try await withThrowingTaskGroup(of: (Int, [Song]).self) { group in
            for (index, album) in albums.enumerated() {
                group.addTask { (index, try await client.album(album.id)?.song ?? []) }
            }
            var results: [(Int, [Song])] = []
            for try await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.flatMap { $0.1 }.uniqued()
        }
    }
}

struct GeneratedPlaylistContent<Content: View>: View {
    let playlist: GeneratedPlaylist
    @ViewBuilder let content: ([Song]) -> Content

    @Environment(AppModel.self) private var model
    @State private var songs: [Song]?
    @State private var failure = false
    @State private var attempt = 0

    var body: some View {
        Group {
            if let songs {
                if songs.isEmpty {
                    ContentUnavailableView("No Tracks Yet", systemImage: "music.note.list",
                                           description: Text("There are no matching tracks in your library."))
                } else {
                    content(songs)
                }
            } else if failure {
                ContentUnavailableView {
                    Label("Couldn’t Load Tracks", systemImage: "exclamationmark.circle")
                } actions: {
                    Button("Try Again") { attempt += 1 }
                }
            } else {
                ProgressView("Loading tracks…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(playlist.title)
        .task(id: attempt) {
            guard songs == nil, let client = model.client else { return }
            failure = false
            do {
                let tracks = try await playlist.tracks(using: client)
                if !Task.isCancelled { songs = tracks }
            } catch {
                if !Task.isCancelled { failure = true }
            }
        }
    }
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
    /// Debug screenshot mode (Mac): the sidebar section to open, e.g. "playlist:<id>".
    var initialSection: String?

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
    var libraryRevision = 0
    var libraryEdit: LibraryEdit?
    var libraryCapabilities: SubsonicClient.LibraryManagementResponse?
    let player = Player()
    let downloads = DownloadManager()
    let router = Router()
    var loved: Set<String> = []
    var playlists: [Playlist] = []
    private var loadedPlaylists = false
    private(set) var pinnedPlaylistIDs: [String] = []
    private var recentPlaylistIDs: [String] = []

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
        pinnedPlaylistIDs = UserDefaults.standard.stringArray(forKey: "pinnedPlaylists.\(creds.libraryKey)") ?? []
        recentPlaylistIDs = UserDefaults.standard.stringArray(forKey: recentPlaylistsKey(creds)) ?? []
        let client = SubsonicClient(creds: creds)
        self.client = client
        player.client = client
        player.queueAccount = playbackAccount
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
        CredentialStore.clear()
        credentials = nil
        client = nil
        player.client = nil
        player.queueAccount = nil
        downloads.client = nil
        loved = []
        playlists = []
        loadedPlaylists = false
        recentPlaylistIDs = []
        pinnedPlaylistIDs = []
        player.stop(clearSavedQueue: false)
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
        guard let client, let list = try? await client.playlists(), self.client === client else { return }
        playlists = list
        loadedPlaylists = true
    }

    func togglePlaylistPin(_ id: String) {
        guard let credentials else { return }
        if pinnedPlaylistIDs.contains(id) { pinnedPlaylistIDs.removeAll { $0 == id } }
        else { pinnedPlaylistIDs.append(id) }
        UserDefaults.standard.set(pinnedPlaylistIDs, forKey: "pinnedPlaylists.\(credentials.libraryKey)")
    }

    var browsablePlaylists: [Playlist] {
        if loadedPlaylists { return playlists }
        return downloads.playlists.map {
            Playlist(id: $0.id, name: $0.name, songCount: $0.tracks.count, coverArt: $0.tracks.first?.coverArt)
        }
    }

    var recentPlaylists: [Playlist] {
        let byID = Dictionary(browsablePlaylists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return recentPlaylistIDs.compactMap { byID[$0] }
    }

    func recordPlaylistOpen(_ id: String, using client: SubsonicClient) {
        guard self.client === client, let credentials else { return }
        recentPlaylistIDs.removeAll { $0 == id }
        recentPlaylistIDs.insert(id, at: 0)
        recentPlaylistIDs = Array(recentPlaylistIDs.prefix(8))
        UserDefaults.standard.set(recentPlaylistIDs, forKey: recentPlaylistsKey(credentials))
    }

    private func recentPlaylistsKey(_ credentials: ServerCredentials) -> String {
        "recentPlaylistIDs.\(credentials.libraryKey)"
    }

    // MARK: Playback started from the library

    func playFromLibrary(_ songs: [Song], startAt: Int = 0, shuffled: Bool = false) {
        guard !songs.isEmpty else { return }
        player.play(songs, startAt: startAt, shuffled: shuffled)
        router.showNowPlaying = true
    }

    private func playRemoteMix(_ playlist: GeneratedPlaylist) async {
        guard let client, let songs = try? await playlist.tracks(using: client) else { return }
        player.play(songs)
    }

    func playRadio(_ station: RadioStation) {
        if player.playRadio(station) { router.showNowPlaying = true }
    }

    func playAlbum(_ id: String, shuffled: Bool = false) async {
        guard let client, let songs = try? await client.album(id)?.song else { return }
        playFromLibrary(songs, shuffled: shuffled)
    }
}

extension Array where Element == Song {
    func uniqued() -> [Song] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
    var totalDuration: Int { reduce(0) { $0 + ($1.duration ?? 0) } }
}

extension AppModel {
    var playbackAccount: String? {
        guard let credentials else { return nil }
        let identity = Data((credentials.url.absoluteString + "\n" + credentials.username).utf8)
        return Data(SHA256.hash(data: identity)).base64EncodedString()
    }

    func playbackState() -> [String: Any] {
        var state: [String: Any] = [
            WatchKey.title: player.current?.title ?? "Not Playing",
            WatchKey.isPlaying: player.isPlaying,
            WatchKey.duration: player.duration,
            WatchKey.elapsed: player.elapsed,
            WatchKey.timestamp: Date().timeIntervalSince1970
        ]
        guard let song = player.current else { return state }
        state[WatchKey.songID] = song.id
        state[WatchKey.artist] = song.artist
        state[WatchKey.album] = song.album
        state[WatchKey.loved] = isLoved(song.id)
        state[WatchKey.upNext] = player.queue.dropFirst(player.index + 1).prefix(12)
            .map { "\($0.title) — \($0.artist ?? "")" }
        return state
    }

    func handlePlaybackControl(_ command: WatchCommand, index: Int?) {
        switch command {
        case .togglePlay: player.togglePlayPause()
        case .pause: player.pause()
        case .next: player.next()
        case .previous: player.previous()
        case .love: toggleLoveCurrent()
        case .shuffleFavourites: Task { await playRemoteMix(.favourites) }
        case .shuffleAll: Task { await playRemoteMix(.discovery) }
        case .jump: if let index { player.jump(to: player.index + 1 + index) }
        default: break
        }
    }
}

struct LiveRadioView: View {
    let station: RadioStation
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text(station.name).font(.largeTitle.bold())
            Text("Live Internet Radio").foregroundStyle(.secondary)
            Button { model.playRadio(station) } label: {
                Label("Listen Live", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(station.name)
    }
}

struct QueueTrackButton: View {
    let song: Song
    @Environment(Player.self) private var player
    @State private var added = false

    var body: some View {
        Button {
            player.addToQueue([song])
            added = true
        } label: {
            Image(systemName: added ? "checkmark" : "text.badge.plus")
                .foregroundStyle(added ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
                #if os(iOS)
                .frame(width: 44, height: 44)
                #else
                .frame(width: 28, height: 22)
                #endif
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(added)
        .accessibilityLabel(added ? "Added to queue" : "Add \(song.title) to queue")
        .help("Add to Queue")
        .task(id: added) {
            guard added else { return }
            do {
                try await Task.sleep(for: .seconds(1.2))
                added = false
            } catch {}
        }
        .onDisappear { added = false }
    }
}

struct RepeatModeMenu: View {
    @Environment(Player.self) private var player

    var body: some View {
        Menu {
            ForEach(RepeatMode.allCases, id: \.self) { mode in
                Button { player.setRepeatMode(mode) } label: {
                    if mode == player.repeatMode {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Text(mode.title)
                    }
                }
            }
        } label: {
            Image(systemName: player.repeatMode.icon)
                .foregroundStyle(player.repeatMode == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                #if os(iOS)
                .frame(width: 44, height: 44)
                #endif
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Repeat")
        .accessibilityValue(player.repeatMode.title)
        .help(player.repeatMode.title)
        .disabled(player.current == nil || player.current?.isRadio == true)
    }
}

struct SearchRequest: Hashable {
    let query: String
    let attempt: Int
}

enum SearchCategory: String, Hashable {
    case songs = "Songs"
    case albums = "Albums"
    case artists = "Artists"
}

@Observable @MainActor
final class SearchPage {
    private(set) var results = SearchResult()
    private(set) var loading = false
    private(set) var failed = false
    private(set) var hasMore = true
    private var offset = 0

    func load(query: String, category: SearchCategory, client: SubsonicClient?) async {
        guard !loading, hasMore, let client else { return }
        loading = true
        failed = false
        defer { loading = false }
        let count = 25
        do {
            let page = try await client.search(
                query, artists: category == .artists ? count : 0,
                albums: category == .albums ? count : 0, songs: category == .songs ? count : 0,
                artistOffset: category == .artists ? offset : 0,
                albumOffset: category == .albums ? offset : 0,
                songOffset: category == .songs ? offset : 0
            )
            try Task.checkCancellation()
            switch category {
            case .songs: results.song = merge(results.song, page.song, limit: count)
            case .albums: results.album = merge(results.album, page.album, limit: count)
            case .artists: results.artist = merge(results.artist, page.artist, limit: count)
            }
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }

    private func merge<T: Identifiable>(_ existing: [T]?, _ page: [T]?, limit: Int) -> [T] {
        let existing = existing ?? []
        let page = page ?? []
        var seen = Set(existing.map(\.id))
        let additions = page.filter { seen.insert($0.id).inserted }
        offset += page.count
        hasMore = page.count >= limit && !additions.isEmpty
        return existing + additions
    }
}

struct SearchPageFooter: View {
    let page: SearchPage
    let load: () async -> Void

    var body: some View {
        if page.loading {
            ProgressView().frame(maxWidth: .infinity)
        } else if page.failed {
            VStack(spacing: 8) {
                Text("Couldn’t load results").foregroundStyle(.secondary)
                Button("Retry") { Task { await load() } }
            }
            .frame(maxWidth: .infinity)
        } else if page.hasMore {
            Button("Load More") { Task { await load() } }.frame(maxWidth: .infinity)
        } else if (page.results.song ?? []).isEmpty && (page.results.album ?? []).isEmpty
                    && (page.results.artist ?? []).isEmpty {
            ContentUnavailableView("No Results", systemImage: "magnifyingglass")
        }
    }
}

struct SaveMixButton: View {
    let title: String
    let songs: [Song]
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var naming = false
    @State private var saving = false
    @State private var result: String?
    @State private var succeeded = false

    var body: some View {
        Button {
            name = title
            naming = true
        } label: {
            if saving {
                ProgressView()
            } else {
                Label("Save as Playlist…", systemImage: "text.badge.plus")
            }
        }
        .disabled(saving)
        .alert("Save as Playlist", isPresented: $naming) {
            TextField("Playlist Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, let client = model.client else { return }
                saving = true
                Task {
                    defer { saving = false }
                    do {
                        try await client.createPlaylist(name: name, songIds: songs.map(\.id))
                        await model.refreshPlaylists()
                        succeeded = true
                        result = "“\(name)” is in your Navidrome playlists."
                    } catch {
                        succeeded = false
                        result = error.localizedDescription
                    }
                }
            }
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(succeeded ? "Playlist Saved" : "Couldn’t Save Playlist", isPresented: Binding(
            get: { result != nil }, set: { if !$0 { result = nil } }
        )) {
            Button("OK", role: .cancel) { result = nil }
        } message: {
            Text(result ?? "")
        }
    }
}

enum DownloadCategory: String, CaseIterable, Identifiable {
    case albums = "Albums"
    case playlists = "Playlists"
    case songs = "Songs"

    var id: Self { self }
}

struct OfflineAlbumActions: View {
    let album: OfflineAlbum
    @Environment(DownloadManager.self) private var downloads
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(downloads.status(for: album.tracks)).foregroundStyle(.secondary)
            let failures = album.trackIDs.sorted().compactMap(downloads.failure)
            if !failures.isEmpty {
                DisclosureGroup(failures.count == 1 ? "1 failed track" : "\(failures.count) failed tracks") {
                    ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                        Text(failure).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if album.tracks.contains(where: { !downloads.isDownloaded($0.id) }) {
                Button("Retry Missing Downloads") { downloads.downloadAlbum(album) }
                    .disabled(!downloads.canRequestDownloads() || !downloads.inProgress.isDisjoint(with: album.trackIDs))
            }
            Button("Remove Album Download", role: .destructive) { confirmRemove = true }
        }
        .font(.subheadline)
        .confirmationDialog("Remove this album download?", isPresented: $confirmRemove) {
            Button("Remove Album Download", role: .destructive) { downloads.removeAlbum(album.id) }
        }
    }
}

struct StandaloneDownloadRows: View {
    let query: String
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        ForEach(downloads.missingStandaloneTracks.filter { $0.matchesDownloadSearch(query) }) { track in
            HStack {
                VStack(alignment: .leading) {
                    Text(track.title)
                    if let failure = downloads.failure(for: track.id) {
                        Text(failure).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(downloads.inProgress.contains(track.id) ? "Downloading" : "Pending")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Menu {
                    Button("Retry Download") { downloads.download([track]) }
                        .disabled(!downloads.canRequestDownloads() || downloads.inProgress.contains(track.id))
                    Button("Cancel Download", role: .destructive) { downloads.remove(track.id) }
                } label: {
                    Label("Manage Download", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                }
            }
        }
    }
}

struct OfflinePlaylistActions: View {
    let playlist: DownloadedPlaylist
    var dismissAfterRemoval = true
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemove = false

    var body: some View {
        let available = playlist.tracks.filter { downloads.isDownloaded($0.id) }.count
        let downloading = !downloads.inProgress.isDisjoint(with: playlist.trackIDs)
        VStack(alignment: .leading, spacing: 8) {
            if downloading {
                Label("Downloading \(available) of \(playlist.tracks.count) tracks", systemImage: "arrow.down.circle.dotted")
            } else if available < playlist.tracks.count {
                Text("\(playlist.tracks.count - available) tracks missing")
                Button("Retry Missing Downloads") { downloads.downloadPlaylist(playlist) }
            } else {
                Label("Ready to Play Offline", systemImage: "checkmark.circle")
            }
            Button("Remove Playlist Download", role: .destructive) { confirmRemove = true }
        }
        .font(.subheadline)
        .confirmationDialog("Remove this offline playlist?", isPresented: $confirmRemove) {
            Button("Remove Download", role: .destructive) {
                downloads.removePlaylist(playlist.id)
                if dismissAfterRemoval { dismiss() }
            }
        }
    }
}

struct PlaybackIssueControls: View {
    @Environment(Player.self) private var player

    var body: some View {
        if let issue = player.playbackIssue {
            HStack(spacing: 10) {
                Label(issue, systemImage: "exclamationmark.circle")
                Spacer(minLength: 4)
                Button("Retry") { player.retryPlayback() }
                    .buttonStyle(.bordered)
            }
            .font(.footnote)
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct LibraryEdit: Identifiable {
    enum Kind: String {
        case track, album, artist
        var label: String { rawValue.capitalized }
    }

    struct Field: Identifiable {
        let id: String
        let label: String
        let current: String?
    }

    let kind: Kind
    let id: String
    let name: String
    var artist: String?
    var album: String?
    var genre: String?
    var year: Int?
    var track: Int?
    var disc: Int?

    init(_ song: Song) {
        kind = .track
        id = song.id
        name = song.title
        artist = song.artist
        album = song.album
        genre = song.genre
        year = song.year
        track = song.track
        disc = song.discNumber
    }

    init(_ detail: AlbumDetail) {
        kind = .album
        id = detail.id
        name = detail.name
        artist = detail.artist
        album = detail.name
        genre = detail.genre
        year = detail.year
    }

    init(_ detail: ArtistDetail) {
        kind = .artist
        id = detail.id
        name = detail.name
    }

    var fields: [Field] {
        let albumTitle = Field(id: "album", label: "Album title", current: album)
        let albumArtist = Field(id: "albumartist", label: "Album artist", current: kind == .album ? artist : nil)
        let date = Field(id: "date", label: "Release date", current: year.map(String.init))
        switch kind {
        case .track:
            return [Field(id: "title", label: "Track title", current: name),
                    Field(id: "artist", label: "Track artist", current: artist),
                    albumTitle, albumArtist, date,
                    Field(id: "tracknumber", label: "Track number", current: track.map(String.init)),
                    Field(id: "discnumber", label: "Disc number", current: disc.map(String.init))]
        case .album:
            return [albumTitle, albumArtist, date]
        case .artist:
            return [Field(id: "artist", label: "Artist name", current: name)]
        }
    }

    var removalDescription: String {
        switch kind {
        case .track: "Move this track to the server’s recovery folder?"
        case .album: "Move all tracks on this album to the server’s recovery folder?"
        case .artist: "Move tracks from albums credited solely to this album artist to the server’s recovery folder?"
        }
    }
}

struct LibraryEditButton: View {
    let edit: LibraryEdit
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.libraryCapabilities?.editor == true {
            Button {
                model.libraryEdit = edit
            } label: {
                Label("Edit \(edit.kind.label)…", systemImage: "pencil")
            }
        }
    }
}

struct LibraryEditSheet: View {
    let edit: LibraryEdit
    let client: SubsonicClient
    let artistArtwork: Bool
    let onComplete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var fields: [String: String] = [:]
    @State private var genre = ""
    @State private var genreOptions: [Genre] = []
    @State private var artwork: Data?
    @State private var preview: CGImage?
    @State private var covers: [LibraryCoverRelease] = []
    @State private var importing = false
    @State private var confirmingRemoval = false
    @State private var renamingFile = false
    @State private var filename = ""
    @State private var working = false
    @State private var result: String?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Edit \(edit.kind.label)").font(.title2.bold())
                Text(edit.name).foregroundStyle(.secondary)
                if let result {
                    Text(result)
                    Button("Done", action: onComplete).buttonStyle(.borderedProminent)
                } else {
                    fieldsForm
                    if edit.kind != .artist || artistArtwork { artworkForm }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
                    if working { ProgressView() }
                    HStack {
                        Button("Cancel") { dismiss() }
                        Spacer()
                        Button("Save Changes") { save(action: "edit") }
                            .buttonStyle(.borderedProminent)
                            .disabled(tags.isEmpty && artwork == nil)
                    }
                    if edit.kind == .track {
                        Button("Rename Audio File…") { renamingFile = true }
                            .disabled(!tags.isEmpty || artwork != nil)
                    }
                    Button("Remove \(edit.kind.label) from Library…", role: .destructive) {
                        confirmingRemoval = true
                    }
                }
            }
            .padding(24)
            .disabled(working)
        }
        .frame(idealWidth: 510, idealHeight: 680)
        .interactiveDismissDisabled(working || result != nil)
        .task { genreOptions = (try? await client.genres()) ?? [] }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { selection in
            do {
                let url = try selection.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 20_000_000 else { throw SubsonicFailure.server("Choose an image smaller than 20 MB.") }
                try setArtwork(Data(contentsOf: url))
            } catch { errorMessage = error.localizedDescription }
        }
        .alert("Rename Audio File", isPresented: $renamingFile) {
            TextField("New filename without extension", text: $filename)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { save(action: "rename-file") }
                .disabled(filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("The file will stay in its current folder and keep its extension.")
        }
        .alert("Remove \(edit.kind.label) from Library?", isPresented: $confirmingRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Recovery", role: .destructive) { save(action: "remove") }
        } message: {
            Text("\(edit.removalDescription) This affects everyone who uses the library.")
        }
    }

    private var fieldsForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(edit.fields) { field in
                Text(field.label).font(.subheadline.bold())
                TextField(field.current ?? field.label, text: Binding(
                    get: { fields[field.id, default: ""] },
                    set: { fields[field.id] = $0 }
                ))
                .accessibilityLabel(field.label)
                .textFieldStyle(.roundedBorder)
            }
            Text("Genre").font(.subheadline.bold())
            HStack {
                TextField(edit.genre ?? "New genre", text: $genre)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Genre")
                Menu("Existing Genres") {
                    ForEach(genreOptions, id: \.value) { option in
                        Button(option.value) { genre = option.value }
                    }
                }
                .disabled(genreOptions.isEmpty)
            }
            Text("Enter only the fields you want to change. A new genre is added when you save.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var artworkForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Artwork").font(.subheadline.bold())
            if let preview {
                Image(decorative: preview, scale: 1)
                    .resizable().scaledToFit().frame(maxWidth: 140, maxHeight: 140)
                    .accessibilityLabel("Selected artwork")
                Button("Clear Selection") { artwork = nil; self.preview = nil }
            }
            HStack {
                Button("Choose Image…") { importing = true }
                if edit.kind != .artist, edit.album != nil {
                    Button("Find Album Artwork") { run { covers = try await LibraryCoverRelease.search(edit) } }
                }
            }
            ForEach(covers) { release in
                HStack {
                    AsyncImage(url: release.coverURL(size: 250)) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    }
                    .frame(width: 48, height: 48)
                    VStack(alignment: .leading) {
                        Text(release.title)
                        Text([release.date, release.country, release.disambiguation]
                            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Select") {
                        run {
                            let (data, response) = try await URLSession.shared.data(from: release.coverURL(size: 1200))
                            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 20_000_000 else {
                                throw SubsonicFailure.server("This release’s cover could not be downloaded.")
                            }
                            try setArtwork(data)
                        }
                    }
                }
            }
        }
    }

    private var tags: [String: String] {
        var changes = fields.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        changes["genre"] = genre.trimmingCharacters(in: .whitespacesAndNewlines)
        return changes.filter { !$0.value.isEmpty }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        working = true
        errorMessage = nil
        Task {
            defer { working = false }
            do { try await operation() }
            catch let failure as SubsonicFailure { errorMessage = failure.localizedDescription }
            catch { errorMessage = "The operation couldn’t be confirmed. Check the library before trying again." }
        }
    }

    private func save(action: String) {
        run {
            result = try await client.libraryManagement(
                action, id: edit.id, name: edit.name, kind: edit.kind.rawValue,
                tags: action == "edit" ? tags : [:], artwork: action == "edit" ? artwork : nil,
                filename: action == "rename-file" ? filename.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            ).message
        }
    }

    private func setArtwork(_ data: Data) throws {
        let error = SubsonicFailure.server("Couldn’t read that image. Choose a different image.")
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1200
              ] as CFDictionary) else { throw error }
        let output = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw error
        }
        CGImageDestinationAddImage(encoder, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(encoder), output.length <= 2 * 1024 * 1024 else { throw error }
        artwork = output as Data
        preview = thumbnail
    }
}

private struct LibraryCoverRelease: Decodable, Identifiable {
    let id: UUID
    let title: String
    let date: String?
    let country: String?
    let disambiguation: String?

    func coverURL(size: Int) -> URL {
        URL(string: "https://coverartarchive.org/release/\(id.uuidString.lowercased())/front-\(size)")!
    }

    static func search(_ edit: LibraryEdit) async throws -> [Self] {
        struct Response: Decodable { let releases: [LibraryCoverRelease] }
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var query = "release:\(quoted(edit.album ?? edit.name))"
        if let artist = edit.artist, !artist.isEmpty { query += " AND artist:\(quoted(artist))" }
        var url = URLComponents(string: "https://musicbrainz.org/ws/2/release")!
        url.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "fmt", value: "json"),
                          URLQueryItem(name: "limit", value: "8")]
        var request = URLRequest(url: url.url!)
        request.setValue("SoundBase/1.0 (https://werket-werk.github.io/SoundBase/)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SubsonicFailure.server("MusicBrainz is unavailable. Try again or choose an image.")
        }
        let releases = try JSONDecoder().decode(Response.self, from: data).releases
        guard !releases.isEmpty else { throw SubsonicFailure.server("No matching releases found. You can choose an image instead.") }
        return releases
    }
}

extension View {
    func libraryEditor(model: AppModel) -> some View {
        @Bindable var model = model
        let client = model.client
        return task(id: client?.creds) {
            model.libraryCapabilities = nil
            let status = try? await client?.libraryManagement("status")
            guard !Task.isCancelled, model.client === client else { return }
            model.libraryCapabilities = status
        }
        .sheet(item: $model.libraryEdit) { selection in
            if let client {
                LibraryEditSheet(edit: selection, client: client,
                                 artistArtwork: model.libraryCapabilities?.artistArtwork == true) {
                    model.libraryEdit = nil
                    if model.client === client { model.libraryRevision += 1 }
                }
            }
        }
    }
}
