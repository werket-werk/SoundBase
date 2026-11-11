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
                .onOpenURL { url in
                    if url.scheme == "soundbase-watch" && url.host == "now-playing" {
                        store.path = [.nowPlaying]
                    }
                }
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
                    RemoteSongList(title: name, albumID: id) { client in (try? await client.album(id)?.song) ?? [] }
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var page = Page.playback
    @State private var showingDevices = false

    private enum Page { case playback, queue }

    private var local: Bool { session.device == .watch }
    private var hasTrack: Bool { local ? player.current != nil : session.phoneIsPlayingSomething }
    private var controlsEnabled: Bool { hasTrack && session.availableDevices.contains(session.device) && !session.switching }
    private var upNext: [String] {
        if !local { return session.upNext }
        return player.queue.dropFirst(player.index + 1).prefix(12).map { $0.title }
    }

    var body: some View {
        TabView(selection: $page) {
            ScrollView {
                VStack(spacing: 5) {
                    WatchDeviceButton(showing: $showingDevices)
                        .buttonStyle(.plain)
                        .font(.caption2)

                    artwork
                        .frame(width: 74, height: 74)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .leading) {
                            if controlsEnabled && session.device != .mac {
                                CrownVolumeControl(
                                    origin: local ? .local : .companion,
                                    focused: page == .playback && scenePhase == .active && !showingDevices
                                )
                                .id(session.device)
                                .frame(width: 44, height: 44)
                                .accessibilityLabel("Volume")
                            }
                        }
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
            .tag(Page.playback)

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
            .tag(Page.queue)
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

private struct CrownVolumeControl: WKInterfaceObjectRepresentable {
    let origin: WKInterfaceVolumeControl.Origin
    let focused: Bool

    final class Coordinator {
        var focused = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        WKInterfaceVolumeControl(origin: origin)
    }

    func updateWKInterfaceObject(_ control: WKInterfaceVolumeControl, context: Context) {
        guard context.coordinator.focused != focused else { return }
        context.coordinator.focused = focused
        if focused {
            control.focus()
        } else {
            control.resignFocus()
        }
    }

    static func dismantleWKInterfaceObject(_ control: WKInterfaceVolumeControl, coordinator: Coordinator) {
        if coordinator.focused { control.resignFocus() }
    }
}

private struct WatchDeviceButton: View {
    @Environment(WatchSession.self) private var session
    @Binding var showing: Bool

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
        let downloads = store.downloads
        List {
            if let issue = downloads.downloadIssue {
                Text(issue).font(.footnote).foregroundStyle(.secondary)
            }
            if !downloads.playlists.isEmpty {
                Section("Playlists") {
                    ForEach(downloads.playlists) { playlist in
                        NavigationLink(playlist.name) {
                            DownloadedSongsView(title: playlist.name, playlist: playlist)
                        }
                    }
                }
            }
            ForEach(downloads.albums) { album in
                NavigationLink {
                    DownloadedSongsView(albumKey: album.id, title: album.name)
                } label: {
                    HStack {
                        if let song = album.tracks.first { DownloadedArtwork(song: song) }
                        VStack(alignment: .leading) {
                            Text(album.name).lineLimit(1)
                            if let saved = downloads.savedAlbum(album.id) {
                                Text(downloads.status(for: saved.tracks)).font(.caption2).foregroundStyle(.secondary)
                            } else if let artist = album.tracks.first?.artist {
                                Text(artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
            if !downloads.songs.isEmpty || !downloads.missingStandaloneTracks.isEmpty {
                NavigationLink("All Songs") { DownloadedSongsView(title: "All Songs") }
            }
            if downloads.albums.isEmpty && downloads.playlists.isEmpty && downloads.missingStandaloneTracks.isEmpty {
                Text("Download playlists or albums to listen without your iPhone.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text(ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file) + " used")
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
    var playlist: DownloadedPlaylist? = nil
    @Environment(WatchStore.self) private var store
    @Environment(WatchSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemove = false
    @State private var showingDevices = false

    var body: some View {
        let downloads = store.downloads
        let album = albumKey.flatMap { id in downloads.albums.first { $0.id == id } }
        let savedAlbum = albumKey.flatMap(downloads.savedAlbum)
        let tracks = playlist?.tracks ?? (albumKey == nil ? downloads.sortedSongs : album?.tracks ?? [])
        let songs = tracks.filter { downloads.isDownloaded($0.id) }
        List {
            if playlist != nil || savedAlbum != nil {
                Text(downloads.status(for: tracks)).foregroundStyle(.secondary)
                let failedCount = Set(tracks.map(\.id)).intersection(downloads.failedDownloads).count
                if failedCount > 0 {
                    Text(failedCount == 1 ? "1 failed track" : "\(failedCount) failed tracks")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if tracks.contains(where: { !downloads.isDownloaded($0.id) }) {
                    Button("Retry Missing") {
                        if let playlist { downloads.downloadPlaylist(playlist) }
                        if let savedAlbum { downloads.downloadAlbum(savedAlbum) }
                    }
                    .disabled(!downloads.canRequestDownloads() || tracks.contains { downloads.inProgress.contains($0.id) })
                }
                Button("Remove Download", role: .destructive) { confirmRemove = true }
            }
            if albumKey == nil && playlist == nil {
                ForEach(downloads.missingStandaloneTracks) { track in
                    VStack(alignment: .leading) {
                        Text(track.title)
                        if let failure = downloads.failure(for: track.id) {
                            Text(failure).font(.caption2).foregroundStyle(.secondary)
                        }
                        Button("Retry") { downloads.download([track]) }
                            .disabled(!downloads.canRequestDownloads() || downloads.inProgress.contains(track.id))
                        Button("Cancel Download", role: .destructive) { downloads.remove(track.id) }
                    }
                }
            }
            if songs.isEmpty { Text("No downloaded songs").foregroundStyle(.secondary) }
            else {
                PlayButtons(songs: songs, alwaysStartSelection: playlist != nil)
                WatchDeviceButton(showing: $showingDevices)
                ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                    WatchSongRow(song: song) { Task { await session.play(songs, startAt: index) } }
                        .deleteDisabled(playlist != nil || !downloads.canRemoveTrack(song.id))
                }
                .onDelete { offsets in
                    if playlist == nil { downloads.removeTracks(offsets.map { songs[$0].id }) }
                }
            }
        }
        .navigationTitle(title)
        .confirmationDialog("Remove this download?", isPresented: $confirmRemove) {
            Button("Remove Download", role: .destructive) {
                if let playlist { downloads.removePlaylist(playlist.id) }
                if let savedAlbum { downloads.removeAlbum(savedAlbum.id) }
                dismiss()
            }
        }
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
                RemoteSongList(title: playlist.name, playlistID: playlist.id) { client in (try? await client.playlist(playlist.id)?.entry) ?? [] }
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
                RemoteSongList(title: album.name, albumID: album.id) { client in (try? await client.album(album.id)?.song) ?? [] }
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
    var playlistID: String? = nil
    var albumID: String? = nil
    let load: (SubsonicClient) async -> [Song]
    @Environment(WatchStore.self) private var store
    @Environment(WatchSession.self) private var session
    @State private var songs: [Song]?
    @State private var showingDevices = false

    var body: some View {
        List {
            if let songs {
                if songs.isEmpty { Text("No songs").foregroundStyle(.secondary) }
                else {
                    PlayButtons(songs: songs)
                    WatchDeviceButton(showing: $showingDevices)
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
        let downloads = store.downloads
        let done = songs.filter { downloads.isDownloaded($0.id) }.count
        let busy = songs.contains { downloads.inProgress.contains($0.id) }
        let hasSnapshot = playlistID.map { downloads.playlistIndex.playlists[$0] != nil }
            ?? albumID.map { downloads.savedAlbum("id:\($0)") != nil } ?? true
        Button {
            if let playlistID {
                downloads.downloadPlaylist(DownloadedPlaylist(id: playlistID, name: title, tracks: songs))
            } else if let albumID {
                downloads.downloadAlbum(id: albumID, name: title, tracks: songs)
            } else {
                downloads.download(songs)
            }
        } label: {
            if done == songs.count && hasSnapshot {
                Label("Downloaded", systemImage: "checkmark.circle.fill")
            } else if busy {
                Label("Downloading \(done)/\(songs.count)", systemImage: "arrow.down.circle.dotted")
            } else if songs.contains(where: { downloads.failedDownloads.contains($0.id) }) {
                Label("Retry Download", systemImage: "arrow.clockwise")
            } else {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }
        .disabled(!downloads.canRequestDownloads() || busy || (done == songs.count && hasSnapshot))
    }
}

struct PlayButtons: View {
    let songs: [Song]
    var alwaysStartSelection = false
    @Environment(WatchSession.self) private var session

    var body: some View {
        let active = !alwaysStartSelection && songs.contains { $0.id == session.currentSongID }
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
                if store.downloads.isDownloaded(song.id) {
                    Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundStyle(.secondary)
                } else if store.downloads.inProgress.contains(song.id) {
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
