import SwiftUI

// MARK: - Library root

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var recent: [Album] = []

    private let rows: [(String, String, Route)] = [
        ("Playlists", "music.note.list", .playlists),
        ("Artists", "music.mic", .artists),
        ("Albums", "square.stack", .albums(title: "Albums", type: "alphabeticalByName")),
        ("Songs", "music.note", .songs),
        ("Genres", "guitars", .genres),
        ("Favourites", "star", .loved),
        ("Downloaded", "arrow.down.circle", .downloads),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows, id: \.0) { row in
                    NavigationLink(value: row.2) {
                        HStack(spacing: 14) {
                            Image(systemName: row.1).font(.title3).foregroundStyle(.tint).frame(width: 30)
                            Text(row.0).font(.title3).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.subheadline.bold()).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                    Divider().padding(.leading, 60)
                }
                Text("Recently Added")
                    .font(.title2.bold())
                    .padding(.horizontal)
                    .padding(.top, 28)
                    .padding(.bottom, 12)
                AlbumGrid(albums: recent)
            }
            .padding(.bottom)
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { router.showSettings = true } label: { Image(systemName: "person.crop.circle") }
            }
        }
        .refreshable { recent = (try? await model.client?.albumList("newest", size: 30)) ?? recent }
        .task { if recent.isEmpty { recent = (try? await model.client?.albumList("newest", size: 30)) ?? [] } }
    }
}

// MARK: - Albums (paged, sortable)

struct AlbumGridView: View {
    let title: String
    let type: String
    @Environment(AppModel.self) private var model
    @AppStorage("library.albums.layout") private var layout = LibraryLayout.grid
    @State private var albums: [Album] = []
    @State private var sort: String?
    @State private var done = false
    @State private var loading = false

    private var currentType: String { sort ?? type }
    private var showsViewOptions: Bool { type == "alphabeticalByName" || type == "alphabeticalByArtist" }

    var body: some View {
        ScrollView {
            if showsViewOptions && layout == .list {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(albums) { album in
                        AlbumCard(album: album, listRow: true)
                            .padding(.vertical, 6)
                            .onAppear {
                                if album.id == albums.last?.id { Task { await loadMore() } }
                            }
                        Divider().padding(.leading, 60)
                    }
                }
                .padding(.horizontal)
            } else {
                AlbumGrid(albums: albums) { Task { await loadMore() } }
                    .padding(.vertical)
            }
            if loading { ProgressView().padding() }
        }
        .navigationTitle(title)
        .toolbar {
            if showsViewOptions {
                LibraryLayoutMenu(layout: $layout)
                Menu {
                    Picker("Sort", selection: Binding(get: { currentType }, set: { sort = $0 })) {
                        Text("Title").tag("alphabeticalByName")
                        Text("Artist").tag("alphabeticalByArtist")
                        Text("Recently Added").tag("newest")
                        Text("Recently Played").tag("recent")
                        Text("Most Played").tag("frequent")
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
            }
        }
        .onChange(of: sort) { _, _ in
            albums = []; done = false
            Task { await loadMore() }
        }
        .task { if albums.isEmpty { await loadMore() } }
    }

    private func loadMore() async {
        guard !loading, !done, let client = model.client else { return }
        loading = true
        defer { loading = false }
        let page = (try? await client.albumList(currentType, size: 60, offset: albums.count)) ?? []
        if page.count < 60 || type == "random" { done = true }
        let existing = Set(albums.map(\.id))
        albums += page.filter { !existing.contains($0.id) }
    }
}

// MARK: - Artists

struct ArtistsListView: View {
    @Environment(AppModel.self) private var model
    @State private var index: [ArtistIndexEntry] = []
    @State private var filter = ""

    @AppStorage("library.artists.layout") private var layout = LibraryLayout.list

    private var filteredIndex: [ArtistIndexEntry] {
        index.compactMap { section in
            let artists = (section.artist ?? []).filter {
                filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)
            }
            return artists.isEmpty ? nil : ArtistIndexEntry(name: section.name, artist: artists)
        }
    }

    var body: some View {
        Group {
            if layout == .grid {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 170), spacing: 14, alignment: .top)], spacing: 18) {
                        ForEach(filteredIndex.flatMap { $0.artist ?? [] }) { artist in
                            GeometryReader { geometry in
                                ArtistCard(artist: artist, width: geometry.size.width)
                            }
                            .aspectRatio(0.78, contentMode: .fit)
                        }
                    }
                    .padding()
                }
            } else {
                List {
                    ForEach(filteredIndex, id: \.name) { section in
                        Section(section.name) {
                            ForEach(section.artist ?? []) { artist in
                                NavigationLink(value: Route.artist(artist.id)) {
                                    HStack(spacing: 12) {
                                        Artwork(id: artist.artworkID, size: 120, circle: true)
                                            .frame(width: 48, height: 48)
                                        Text(artist.name)
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .searchable(text: $filter, placement: .navigationBarDrawer, prompt: "Find in Artists")
        .navigationTitle("Artists")
        .toolbar { LibraryLayoutMenu(layout: $layout) }
        .overlay { if index.isEmpty { ProgressView() } }
        .task { if index.isEmpty { index = (try? await model.client?.artists()) ?? [] } }
    }
}

// MARK: - Songs

struct SongsListView: View {
    @Environment(AppModel.self) private var model
    @State private var songs: [Song] = []
    @State private var done = false
    @State private var loading = false

    var body: some View {
        List {
            PlayShuffleButtons(play: { model.playFromLibrary(songs) }, shuffle: { model.playFromLibrary(songs, shuffled: true) })
                .listRowSeparator(.hidden)
            ForEach(Array(songs.enumerated()), id: \.element.id) { i, song in
                SongRow(song: song) { model.playFromLibrary(songs, startAt: i) }
                    .onAppear { if i == songs.count - 1 { Task { await loadMore() } } }
            }
            if loading { ProgressView().frame(maxWidth: .infinity) }
        }
        .listStyle(.plain)
        .navigationTitle("Songs")
        .task { if songs.isEmpty { await loadMore() } }
    }

    private func loadMore() async {
        guard !loading, !done, let client = model.client else { return }
        loading = true
        defer { loading = false }
        let page = (try? await client.search("", artists: 0, albums: 0, songs: 200, songOffset: songs.count).song) ?? []
        if page.count < 200 { done = true }
        songs += page
    }
}

// MARK: - Genres

struct GenresView: View {
    @Environment(AppModel.self) private var model
    @State private var genres: [Genre] = []

    var body: some View {
        List(genres) { genre in
            NavigationLink(value: Route.genre(genre.value)) {
                HStack {
                    Text(genre.value)
                    Spacer()
                    Text("\(genre.albumCount ?? 0) albums").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Genres")
        .task { if genres.isEmpty { genres = (try? await model.client?.genres()) ?? [] } }
    }
}

// MARK: - Playlists

struct PlaylistsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("library.playlists.layout") private var layout = LibraryLayout.list
    @State private var newName = ""
    @State private var showNew = false

    var body: some View {
        Group {
            if layout == .grid {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Button { showNew = true } label: {
                            Label("New Playlist…", systemImage: "plus")
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 135, maximum: 240), spacing: 14, alignment: .top)], spacing: 18) {
                            ForEach(model.playlists) { playlist in
                                NavigationLink(value: Route.playlist(playlist.id)) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Artwork(id: playlist.coverArt, size: 400)
                                        playlistTitle(playlist)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding()
                }
            } else {
                List {
                    Button { showNew = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus")
                                .font(.title2)
                                .frame(width: 56, height: 56)
                                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                            Text("New Playlist…").foregroundStyle(.tint)
                        }
                    }
                    ForEach(model.playlists) { playlist in
                        NavigationLink(value: Route.playlist(playlist.id)) {
                            HStack(spacing: 12) {
                                Artwork(id: playlist.coverArt, size: 160, corner: 6).frame(width: 56, height: 56)
                                playlistTitle(playlist)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Playlists")
        .toolbar { LibraryLayoutMenu(layout: $layout) }
        .refreshable { await model.refreshPlaylists() }
        .task { await model.refreshPlaylists() }
        .alert("New Playlist", isPresented: $showNew) {
            TextField("Playlist Name", text: $newName)
            Button("Cancel", role: .cancel) { newName = "" }
            Button("Create") {
                let name = newName
                newName = ""
                Task {
                    try? await model.client?.createPlaylist(name: name, songIds: [])
                    await model.refreshPlaylists()
                }
            }
        }
    }

    private func playlistTitle(_ playlist: Playlist) -> some View {
        LibraryItemTitle(title: playlist.name, subtitle: "\(playlist.songCount ?? 0) songs")
    }
}

struct PlaylistPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var showNew = false

    var body: some View {
        let songs = router.playlistPickerSongs ?? []
        NavigationStack {
            List {
                Button { showNew = true } label: { Label("New Playlist…", systemImage: "plus") }
                ForEach(model.playlists) { playlist in
                    Button {
                        Task {
                            try? await model.client?.addToPlaylist(playlist.id, songIds: songs.map(\.id))
                            await model.refreshPlaylists()
                            close()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Artwork(id: playlist.coverArt, size: 120, corner: 5).frame(width: 44, height: 44)
                            Text(playlist.name).foregroundStyle(.primary)
                        }
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel") { close() } }
            .alert("New Playlist", isPresented: $showNew) {
                TextField("Playlist Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    let name = newName
                    Task {
                        try? await model.client?.createPlaylist(name: name, songIds: songs.map(\.id))
                        await model.refreshPlaylists()
                        close()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func close() {
        router.playlistPickerSongs = nil
        dismiss()
    }
}

// MARK: - Favourites

struct LovedView: View {
    @Environment(AppModel.self) private var model
    @State private var starred: Starred?

    var body: some View {
        ScrollView {
            if let starred {
                let songs = starred.song ?? []
                VStack(alignment: .leading, spacing: 26) {
                    if songs.isEmpty && (starred.album ?? []).isEmpty && (starred.artist ?? []).isEmpty {
                        EmptyStateView(title: "No Favourites Yet", systemImage: "star", message: "Tap the star on songs, albums and artists to see them here.")
                            .padding(.top, 60)
                    }
                    ArtistShelf(title: "Artists", artists: starred.artist ?? [])
                    AlbumShelf(title: "Albums", albums: starred.album ?? [])
                    if !songs.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ShelfHeader(title: "Songs")
                            PlayShuffleButtons(play: { model.playFromLibrary(songs) }, shuffle: { model.playFromLibrary(songs, shuffled: true) })
                                .padding(.horizontal).padding(.vertical, 8)
                            ForEach(Array(songs.enumerated()), id: \.element.id) { i, song in
                                SongRow(song: song) { model.playFromLibrary(songs, startAt: i) }.padding(.horizontal)
                            }
                        }
                    }
                }
                .padding(.vertical)
            } else {
                ProgressView().padding(80).frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Favourites")
        .refreshable { starred = try? await model.client?.starred() }
        .task { starred = try? await model.client?.starred() }
    }
}

// MARK: - Downloads

struct DownloadsView: View {
    @Environment(DownloadManager.self) private var downloads
    @State private var category: DownloadCategory = .albums
    @State private var query = ""
    @State private var confirm = false

    var body: some View {
        List {
            Picker("Downloads", selection: $category) {
                ForEach(DownloadCategory.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if let issue = downloads.downloadIssue {
                Label(issue, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }

            switch category {
            case .albums:
                let albums = downloads.albums.filter { $0.tracks.contains { $0.matchesDownloadSearch(query) } }
                if albums.isEmpty { emptyState("Albums") }
                ForEach(albums, id: \.id) { album in
                    let tracks = album.tracks
                    if let first = tracks.first {
                        NavigationLink {
                            OfflineTracksView(title: first.album ?? "Unknown Album", tracks: tracks)
                        } label: {
                            Label(first.album ?? "Unknown Album", systemImage: "square.stack")
                        }
                    }
                }
            case .playlists:
                let playlists = downloads.playlists.filter { playlist in
                    query.isEmpty || playlist.name.localizedStandardContains(query)
                        || playlist.tracks.contains { $0.matchesDownloadSearch(query) }
                }
                if playlists.isEmpty { emptyState("Playlists") }
                ForEach(playlists) { playlist in
                    NavigationLink {
                        OfflineTracksView(title: playlist.name, tracks: playlist.tracks, playlist: playlist)
                    } label: {
                        Label(playlist.name, systemImage: "music.note.list")
                    }
                }
            case .songs:
                let songs = downloads.sortedSongs.filter { $0.matchesDownloadSearch(query) }
                if songs.isEmpty { emptyState("Songs") }
                OfflineTrackRows(tracks: songs, allowRemoval: true)
            }

            if !downloads.inProgress.isEmpty {
                Label("Downloading \(downloads.inProgress.count) songs…", systemImage: "arrow.down.circle.dotted")
                    .foregroundStyle(.secondary)
            }
            Text(ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file) + " used")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .listStyle(.plain)
        .navigationTitle("Downloaded")
        .searchable(text: $query, prompt: "Find downloaded music")
        .toolbar {
            if !downloads.songs.isEmpty || !downloads.playlists.isEmpty || !downloads.inProgress.isEmpty {
                Button("Remove All", role: .destructive) { confirm = true }
            }
        }
        .confirmationDialog("Remove all downloaded music from this iPhone?", isPresented: $confirm) {
            Button("Remove All Downloads", role: .destructive) { downloads.removeAll() }
        }
    }

    private func emptyState(_ title: String) -> some View {
        Text(query.isEmpty ? "No Downloaded \(title)" : "No Matching \(title)")
            .foregroundStyle(.secondary)
    }
}

struct OfflineTracksView: View {
    let title: String
    let tracks: [Song]
    var playlist: DownloadedPlaylist? = nil
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        let available = tracks.filter { downloads.isDownloaded($0.id) }
        List {
            if let playlist { OfflinePlaylistActions(playlist: playlist) }
            OfflineTrackRows(tracks: available)
        }
        .navigationTitle(title)
    }
}

private struct OfflineTrackRows: View {
    let tracks: [Song]
    var allowRemoval = false
    @Environment(AppModel.self) private var model
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        if !tracks.isEmpty {
            PlayShuffleButtons(
                play: { model.playFromLibrary(tracks) },
                shuffle: { model.playFromLibrary(tracks, shuffled: true) }
            )
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, song in
                SongRow(song: song) { model.playFromLibrary(tracks, startAt: index) }
            }
            .onDelete(perform: allowRemoval ? remove : nil)
        }
    }

    private func remove(_ offsets: IndexSet) {
        for offset in offsets { downloads.remove(tracks[offset].id) }
    }
}

struct ListeningHistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(Player.self) private var player

    var body: some View {
        List {
            if player.listeningHistory.isEmpty {
                ContentUnavailableView("No Listening History", systemImage: "clock.arrow.circlepath",
                                       description: Text("Tracks you play on this device appear here."))
            }
            ForEach(player.listeningHistory) { entry in
                VStack(alignment: .leading, spacing: 0) {
                    SongRow(song: entry.song) { model.playFromLibrary([entry.song]) }
                    Text(entry.playedAt, format: .dateTime.day().month().hour().minute())
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Listening History")
    }
}
