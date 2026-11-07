import SwiftUI
import WatchKit

@main
struct SoundBaseWatchApp: App {
    @State private var store = WatchStore()
    @State private var session = WatchSession()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(store)
                .environment(store.player)
                .environment(session)
                .tint(session.accent.color)
                .onAppear { session.start(store: store) }
                #if DEBUG
                .task { await WatchScreenshotDirector.run(store: store, session: session) }
                #endif
        }
    }
}

struct WatchRootView: View {
    @Environment(WatchStore.self) private var store
    @Environment(WatchPlayer.self) private var player
    @Environment(WatchSession.self) private var session

    var body: some View {
        @Bindable var store = store
        NavigationStack(path: $store.path) {
            List {
                if session.phoneIsPlayingSomething {
                    NavigationLink { RemoteView() } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text("On iPhone").font(.headline)
                                Text(session.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        } icon: { Image(systemName: "iphone") }
                    }
                }
                if player.current != nil {
                    NavigationLink { NowPlayingView() } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text("On Watch").font(.headline)
                                Text(player.current?.title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        } icon: { Image(systemName: "applewatch") }
                    }
                }
                Section("Library") {
                    NavigationLink { DownloadedWatchView() } label: { Label("Downloaded", systemImage: "arrow.down.circle.fill") }
                    if store.client != nil {
                        NavigationLink { PlaylistsWatchView() } label: { Label("Playlists", systemImage: "music.note.list") }
                        NavigationLink { AlbumsWatchView() } label: { Label("Albums", systemImage: "square.stack.fill") }
                        NavigationLink {
                            RemoteSongList(title: "Favourites") { client in (try? await client.starred().song) ?? [] }
                        } label: { Label("Favourites", systemImage: "star.fill") }
                        NavigationLink {
                            RemoteSongList(title: "Discovery Mix") { client in (try? await client.randomSongs(size: 40)) ?? [] }
                        } label: { Label("Discovery Mix", systemImage: "sparkles") }
                    }
                }
                if store.client == nil {
                    Text("Open SoundBase on your iPhone and sign in. The Watch picks up your server automatically.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("SoundBase")
            .navigationDestination(for: WatchRoute.self) { route in
                switch route {
                case .remote: RemoteView()
                case .nowPlaying: NowPlayingView()
                case .downloaded: DownloadedWatchView()
                case .playlists: PlaylistsWatchView()
                case .albums: AlbumsWatchView()
                case .album(let id, let name):
                    RemoteSongList(title: name) { client in (try? await client.album(id)?.song) ?? [] }
                }
            }
        }
    }
}

enum WatchRoute: Hashable {
    case remote, nowPlaying, downloaded, playlists, albums
    case album(id: String, name: String)
}

// MARK: - iPhone remote

struct RemoteView: View {
    @Environment(WatchSession.self) private var session

    var body: some View {
        TabView {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Group {
                            if let art = session.artwork { Image(uiImage: art).resizable().scaledToFill() }
                            else { Color.gray.opacity(0.3).overlay(Image(systemName: "music.note")) }
                        }
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(session.title).font(.headline).lineLimit(1)
                            Text(session.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    ProgressView(value: session.elapsed(at: ctx.date), total: max(session.duration, 1))
                    HStack {
                        Button { session.send(.previous) } label: { Image(systemName: "backward.fill") }
                        Button { session.send(.togglePlay) } label: {
                            Image(systemName: session.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                        }
                        Button { session.send(.next) } label: { Image(systemName: "forward.fill") }
                    }
                    .buttonStyle(.plain)
                    .font(.title3)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    Button { session.send(.love) } label: {
                        Label(session.loved ? "Favourited" : "Favourite", systemImage: session.loved ? "star.fill" : "star")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    if !session.reachable {
                        Text("iPhone not reachable").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 4)
            }
            .containerBackground(session.accent.color.gradient.opacity(0.5), for: .tabView)

            List {
                Section("Up Next") {
                    if session.upNext.isEmpty { Text("Nothing queued").foregroundStyle(.secondary) }
                    ForEach(Array(session.upNext.enumerated()), id: \.offset) { i, line in
                        Button { session.send(.jump, index: i) } label: { Text(line).font(.footnote).lineLimit(2) }
                    }
                }
            }
        }
        .tabViewStyle(.verticalPage)
        .navigationTitle("iPhone")
    }
}

// MARK: - Library on the Watch

struct DownloadedWatchView: View {
    @Environment(WatchStore.self) private var store

    var body: some View {
        let songs = store.downloadedSongs
        List {
            if songs.isEmpty {
                Text("Download playlists or albums to listen without your iPhone.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                PlayButtons(songs: songs)
                ForEach(Array(songs.enumerated()), id: \.element.id) { i, song in
                    WatchSongRow(song: song) { store.player.play(songs, startAt: i) }
                }
                .onDelete { offsets in offsets.map { songs[$0].id }.forEach(store.remove) }
                Text(ByteCountFormatter.string(fromByteCount: store.totalBytes, countStyle: .file) + " used")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Downloaded")
    }
}

struct PlaylistsWatchView: View {
    @Environment(WatchStore.self) private var store
    @State private var playlists: [Playlist] = []

    var body: some View {
        List(playlists) { playlist in
            NavigationLink {
                RemoteSongList(title: playlist.name) { client in (try? await client.playlist(playlist.id)?.entry) ?? [] }
            } label: {
                VStack(alignment: .leading) {
                    Text(playlist.name)
                    Text("\(playlist.songCount ?? 0) songs").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .overlay { if playlists.isEmpty { ProgressView() } }
        .navigationTitle("Playlists")
        .task { if let client = store.client { playlists = (try? await client.playlists()) ?? [] } }
    }
}

struct AlbumsWatchView: View {
    @Environment(WatchStore.self) private var store
    @State private var albums: [Album] = []

    var body: some View {
        List(albums) { album in
            NavigationLink {
                RemoteSongList(title: album.name) { client in (try? await client.album(album.id)?.song) ?? [] }
            } label: {
                HStack {
                    WatchArtwork(id: album.coverArt).frame(width: 36, height: 36)
                    VStack(alignment: .leading) {
                        Text(album.name).lineLimit(1)
                        Text(album.artist ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .overlay { if albums.isEmpty { ProgressView() } }
        .navigationTitle("Albums")
        .task {
            guard let client = store.client else { return }
            async let recent = try? client.albumList("recent", size: 25)
            async let newest = try? client.albumList("newest", size: 25)
            albums = ((await recent ?? []) + (await newest ?? [])).reduce(into: [Album]()) { acc, a in
                if !acc.contains(where: { $0.id == a.id }) { acc.append(a) }
            }
        }
    }
}

/// Songs loaded from the server, with Play, Shuffle and Download for offline use.
struct RemoteSongList: View {
    let title: String
    let load: (SubsonicClient) async -> [Song]
    @Environment(WatchStore.self) private var store
    @State private var songs: [Song]?

    var body: some View {
        List {
            if let songs {
                if songs.isEmpty { Text("No songs").foregroundStyle(.secondary) }
                else {
                    PlayButtons(songs: songs)
                    downloadButton(songs)
                    ForEach(Array(songs.enumerated()), id: \.element.id) { i, song in
                        WatchSongRow(song: song) { store.player.play(songs, startAt: i) }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(title)
        .task {
            guard songs == nil, let client = store.client else { return }
            songs = await load(client)
        }
    }

    @ViewBuilder
    private func downloadButton(_ songs: [Song]) -> some View {
        let done = songs.filter { store.isDownloaded($0.id) }.count
        let busy = songs.contains { store.inProgress.contains($0.id) }
        Button { store.download(songs) } label: {
            if done == songs.count {
                Label("Downloaded", systemImage: "checkmark.circle.fill")
            } else if busy {
                Label("Downloading \(done)/\(songs.count)", systemImage: "arrow.down.circle.dotted")
            } else {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }
        .disabled(done == songs.count)
    }
}

struct PlayButtons: View {
    let songs: [Song]
    @Environment(WatchStore.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            Button { store.player.play(songs) } label: {
                Label("Play", systemImage: "play.fill").labelStyle(.iconOnly).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Play")
            Button { store.player.play(songs, shuffled: true) } label: {
                Label("Shuffle", systemImage: "shuffle").labelStyle(.iconOnly).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Shuffle")
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }
}

struct WatchSongRow: View {
    let song: Song
    let action: () -> Void
    @Environment(WatchStore.self) private var store
    @Environment(WatchPlayer.self) private var player

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading) {
                    Text(song.title).lineLimit(1)
                        .foregroundStyle(player.current?.id == song.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    Text(song.artist ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if store.isDownloaded(song.id) {
                    Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundStyle(.secondary)
                } else if store.inProgress.contains(song.id) {
                    ProgressView().frame(width: 14, height: 14)
                }
            }
        }
    }
}

struct WatchArtwork: View {
    let id: String?
    @Environment(WatchStore.self) private var store

    var body: some View {
        AsyncImage(url: id.flatMap { store.client?.coverURL($0, size: 100) }) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color.gray.opacity(0.3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
