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
    @Environment(WatchSession.self) private var session

    var body: some View {
        @Bindable var store = store
        NavigationStack(path: $store.path) {
            List {
                NavigationLink(value: WatchRoute.nowPlaying) {
                    Label {
                        VStack(alignment: .leading) {
                            Text("Now Playing").font(.headline)
                            Text(session.currentTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    } icon: { Image(systemName: session.device.icon) }
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
                case .nowPlaying: WatchNowPlayingView()
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
    case nowPlaying, downloaded, playlists, albums
    case album(id: String, name: String)
}

// MARK: - Now Playing

struct WatchNowPlayingView: View {
    @Environment(WatchSession.self) private var session
    @Environment(WatchPlayer.self) private var player
    @Environment(WatchStore.self) private var store

    private var local: Bool { session.device == .watch }
    private var hasTrack: Bool { local ? player.current != nil : session.phoneIsPlayingSomething }
    private var controlsEnabled: Bool { hasTrack && session.availableDevices.contains(session.device) && !session.switching }
    private var upNext: [String] {
        if !local { return session.upNext }
        return player.queue.dropFirst(player.index + 1).prefix(12).map { $0.title }
    }

    var body: some View {
        TabView {
            ScrollView {
                VStack(spacing: 5) {
                    WatchDeviceButton()
                        .buttonStyle(.plain)
                        .font(.caption2)

                    artwork
                        .frame(width: 74, height: 74)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .trailing) {
                            let loved = local ? session.localLoved : session.loved
                            transport(loved ? "Remove Favourite" : "Add Favourite",
                                      icon: loved ? "star.fill" : "star", command: .love)
                                .frame(width: 44)
                                .foregroundStyle(loved ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                                .disabled(!controlsEnabled || (local && store.client == nil))
                        }
                        .padding(.top, 3)

                    VStack(spacing: 0) {
                        Text(session.currentTitle).font(.headline).lineLimit(1)
                        if let artist = local ? player.current?.artist : session.artist, !artist.isEmpty {
                            Text(artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 5)

                    HStack(spacing: 0) {
                        transport("Previous track", icon: "backward.fill", command: .previous)
                        transport(session.playing ? "Pause" : "Play",
                                  icon: session.playing ? "pause.fill" : "play.fill", command: .togglePlay)
                        transport("Next track", icon: "forward.fill", command: .next)
                    }
                    .disabled(!controlsEnabled)

                    if hasTrack {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let duration = local ? Double(player.current?.duration ?? 0) : session.duration
                            let elapsed = local ? player.elapsed : session.elapsed(at: context.date)
                            if duration > 0 { ProgressView(value: min(duration, elapsed), total: duration) }
                        }
                    }
                    if session.switching { ProgressView().controlSize(.mini) }
                    if let error = session.commandError ?? (local ? player.error : nil) {
                        Text(error).font(.caption2).foregroundStyle(.secondary)
                    } else if !local && !session.availableDevices.contains(session.device) {
                        Text("\(session.device.name) unavailable").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 4)
            }
            .containerBackground(session.accent.color.gradient.opacity(0.38), for: .tabView)

            List {
                Section("Up Next") {
                    if upNext.isEmpty { Text("Nothing queued").foregroundStyle(.secondary) }
                    ForEach(Array(upNext.enumerated()), id: \.offset) { index, title in
                        Button { session.control(.jump, index: index) } label: {
                            Text(title).font(.footnote).lineLimit(2)
                        }
                        .disabled(!controlsEnabled)
                    }
                }
            }
        }
        .tabViewStyle(.verticalPage)
        .task(id: player.current?.id) { await session.refreshLocalFavourite() }
    }

    private var artwork: some View {
        Group {
            if let image = local ? player.currentArtwork : session.artwork {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.white.opacity(0.14)).overlay {
                    Image(systemName: "music.note").font(.title2)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func transport(_ title: String, icon: String, command: WatchCommand) -> some View {
        Button { session.control(command) } label: {
            Image(systemName: icon)
                .font(command == .togglePlay ? .title2 : .body)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct WatchDeviceButton: View {
    @Environment(WatchSession.self) private var session
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 5) {
                Label(session.device.name, systemImage: session.device.icon)
                Image(systemName: "chevron.down").font(.caption2)
            }
        }
        .accessibilityLabel("Playing on \(session.device.name). Change device")
        .disabled(session.switching)
        .sheet(isPresented: $showing) {
            NavigationStack {
                List(session.availableDevices) { device in
                    Button {
                        showing = false
                        Task { await session.select(device) }
                    } label: {
                        Label(device.name, systemImage: device == session.device ? "checkmark" : device.icon)
                    }
                }
                .navigationTitle("Play on")
            }
        }
    }
}

// MARK: - Library on the Watch

struct DownloadedWatchView: View {
    @Environment(WatchStore.self) private var store

    var body: some View {
        let songs = store.downloadedSongs
        let albums = Dictionary(grouping: songs, by: store.downloadAlbumKey)
        List {
            if songs.isEmpty {
                Text("Download playlists or albums to listen without your iPhone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(albums.keys.sorted { (albums[$0]?.first?.album ?? "", $0) < (albums[$1]?.first?.album ?? "", $1) }, id: \.self) { key in
                    if let song = albums[key]?.first {
                        NavigationLink {
                            DownloadedSongsView(albumKey: key, title: song.album ?? "Unknown Album")
                        } label: {
                            HStack {
                                DownloadedArtwork(song: song)
                                VStack(alignment: .leading) {
                                    Text(song.album ?? "Unknown Album").lineLimit(1)
                                    if let artist = song.artist {
                                        Text(artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
                NavigationLink("All Songs") { DownloadedSongsView(title: "All Songs") }
                Text(ByteCountFormatter.string(fromByteCount: store.totalBytes, countStyle: .file) + " used")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Downloaded")
    }
}

private struct DownloadedArtwork: View {
    let song: Song
    @Environment(WatchStore.self) private var store
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Rectangle().fill(.secondary.opacity(0.2)).overlay { Image(systemName: "music.note") } }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: song.coverArt) { image = store.savedArtwork(for: song) }
    }
}

private struct DownloadedSongsView: View {
    var albumKey: String?
    let title: String
    @Environment(WatchStore.self) private var store
    @Environment(WatchSession.self) private var session

    var body: some View {
        let songs = store.downloadedSongs.filter { song in
            albumKey.map { store.downloadAlbumKey(for: song) == $0 } ?? true
        }
        List {
            if songs.isEmpty { Text("No downloaded songs").foregroundStyle(.secondary) }
            else {
                PlayButtons(songs: songs)
                WatchDeviceButton()
                ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                    WatchSongRow(song: song) { Task { await session.play(songs, startAt: index) } }
                }
                .onDelete { offsets in offsets.map { songs[$0].id }.forEach(store.remove) }
            }
        }
        .navigationTitle(title)
        .alert("Playback", isPresented: Binding(
            get: { session.commandError != nil },
            set: { if !$0 { session.dismissError() } }
        )) {
            Button("OK") { session.dismissError() }
        } message: {
            Text(session.commandError ?? "")
        }
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
    @Environment(WatchSession.self) private var session
    @State private var songs: [Song]?

    var body: some View {
        List {
            if let songs {
                if songs.isEmpty { Text("No songs").foregroundStyle(.secondary) }
                else {
                    PlayButtons(songs: songs)
                    WatchDeviceButton()
                    downloadButton(songs)
                    ForEach(Array(songs.enumerated()), id: \.offset) { i, song in
                        WatchSongRow(song: song) { Task { await session.play(songs, startAt: i) } }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(title)
        .alert("Playback", isPresented: Binding(
            get: { session.commandError != nil },
            set: { if !$0 { session.dismissError() } }
        )) {
            Button("OK") { session.dismissError() }
        } message: {
            Text(session.commandError ?? "")
        }
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
            } else if songs.contains(where: { store.failedDownloads.contains($0.id) }) {
                Label("Retry Download", systemImage: "arrow.clockwise")
            } else {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }
        .disabled(done == songs.count)
    }
}

struct PlayButtons: View {
    let songs: [Song]
    @Environment(WatchSession.self) private var session

    var body: some View {
        let active = songs.contains { $0.id == session.currentSongID }
        let pause = active && session.playing
        HStack(spacing: 8) {
            Button {
                if active { session.control(.togglePlay) }
                else { Task { await session.play(songs) } }
            } label: {
                Label(pause ? "Pause" : "Play", systemImage: pause ? "pause.fill" : "play.fill")
                    .labelStyle(.iconOnly).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(pause ? "Pause" : "Play")
            Button { Task { await session.play(songs, shuffled: true) } } label: {
                Label("Shuffle", systemImage: "shuffle").labelStyle(.iconOnly).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Shuffle")
        }
        .disabled(session.switching)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }
}

struct WatchSongRow: View {
    let song: Song
    let action: () -> Void
    @Environment(WatchStore.self) private var store
    @Environment(WatchSession.self) private var session

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading) {
                    Text(song.title).lineLimit(1)
                        .foregroundStyle(session.currentSongID == song.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
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
