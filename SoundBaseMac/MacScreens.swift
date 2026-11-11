import SwiftUI

// MARK: - Home

struct MacHomeView: View {
    @Environment(AppModel.self) private var model
    @State private var recent: [Album] = []
    @State private var frequent: [Album] = []
    @State private var newest: [Album] = []
    @State private var starred: [Album] = []
    @State private var rediscover: [Album] = []
    @State private var similar: [Artist] = []
    @State private var seed: String?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 10) {
                    MacShelfHeader(title: "Made For You")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            MacMixTile(title: "Favourites Mix", subtitle: "Your starred songs", systemImage: "star.fill", colors: MacPalette.sets[0]) {
                                Task { await model.playFavouritesMix() }
                            }
                            MacMixTile(title: "Discovery Mix", subtitle: "Deep cuts", systemImage: "sparkles", colors: MacPalette.sets[1]) {
                                Task { await model.playDiscoveryMix() }
                            }
                            if let a = recent.first, let id = a.artistId, let name = a.artist {
                                MacMixTile(title: "\(name) Station", subtitle: "Inspired by recent listening", systemImage: "dot.radiowaves.left.and.right", colors: MacPalette.sets[2]) {
                                    Task { await model.playArtistStation(artistId: id, name: name) }
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                }
                MacAlbumShelf(title: "Recently Played", albums: recent, route: .albums(title: "Recently Played", type: "recent"))
                if let seed { MacArtistShelf(title: "You Might Also Like", subtitle: "Because you listened to \(seed)", artists: similar) }
                MacAlbumShelf(title: "Recently Added", albums: newest, route: .albums(title: "Recently Added", type: "newest"))
                MacAlbumShelf(title: "Most Played", albums: frequent, route: .albums(title: "Most Played", type: "frequent"))
                MacAlbumShelf(title: "Favourite Albums", albums: starred, route: .albums(title: "Favourite Albums", type: "starred"))
                MacAlbumShelf(title: "Rediscover", albums: rediscover, route: .albums(title: "Rediscover", type: "random"))
                if !loaded { ProgressView().frame(maxWidth: .infinity) }
            }
            .padding(.vertical, 24)
        }
        .navigationTitle("Home")
        .toolbar { ToolbarItem { Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") } } }
        .task { if !loaded { await load() } }
    }

    private func load() async {
        guard let client = model.client else { return }
        async let r = try? client.albumList("recent", size: 20)
        async let f = try? client.albumList("frequent", size: 20)
        async let n = try? client.albumList("newest", size: 20)
        async let s = try? client.albumList("starred", size: 20)
        async let x = try? client.albumList("random", size: 20)
        recent = await r ?? []; frequent = await f ?? []; newest = await n ?? []
        starred = await s ?? []; rediscover = await x ?? []
        loaded = true
        if let a = recent.first(where: { $0.artistId != nil }), let id = a.artistId {
            similar = (try? await client.artistInfo(id))?.similarArtist ?? []
            seed = similar.isEmpty ? nil : a.artist
        }
    }
}

// MARK: - New

struct MacBrowseView: View {
    @Environment(AppModel.self) private var model
    @State private var newest: [Album] = []
    @State private var highest: [Album] = []
    @State private var random: [Album] = []
    @State private var genres: [Genre] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                MacAlbumShelf(title: "New Releases", albums: newest, route: .albums(title: "New Releases", type: "newest"))
                MacAlbumShelf(title: "Top Rated", albums: highest, route: .albums(title: "Top Rated", type: "highest"))
                MacAlbumShelf(title: "Random Picks", albums: random, route: .albums(title: "Random Picks", type: "random"))
                MacGenreGrid(genres: Array(genres.prefix(16)))
            }
            .padding(.vertical, 24)
        }
        .navigationTitle("New")
        .task {
            guard newest.isEmpty, let client = model.client else { return }
            async let n = try? client.albumList("newest", size: 20)
            async let h = try? client.albumList("highest", size: 20)
            async let r = try? client.albumList("random", size: 20)
            async let g = try? client.genres()
            newest = await n ?? []; highest = await h ?? []; random = await r ?? []; genres = await g ?? []
        }
    }
}

struct MacGenreGrid: View {
    let genres: [Genre]
    @Environment(Router.self) private var router

    var body: some View {
        if !genres.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                MacShelfHeader(title: "Browse by Genre", route: .genres)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                    ForEach(genres) { g in
                        MacMixTile(title: g.value, systemImage: "music.quarternote.3", colors: MacPalette.stable(g.value), width: nil, height: 90) {
                            router.go(.genre(g.value))
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }
}

// MARK: - Radio

struct MacRadioView: View {
    @Environment(AppModel.self) private var model
    @State private var genres: [Genre] = []
    @State private var stations: [RadioStation] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack(spacing: 16) {
                    MacMixTile(title: "Discovery Station", subtitle: "Endless music from your library", systemImage: "dot.radiowaves.left.and.right", colors: MacPalette.sets[1], width: nil, height: 170) {
                        Task { await model.playDiscoveryMix() }
                    }
                    MacMixTile(title: "Favourites Station", subtitle: "Starred songs, shuffled", systemImage: "star.fill", colors: MacPalette.sets[0], width: nil, height: 170) {
                        Task { await model.playFavouritesMix() }
                    }
                }
                .padding(.horizontal, 24)
                if !genres.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        MacShelfHeader(title: "Genre Stations")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                            ForEach(genres.prefix(20)) { g in
                                MacMixTile(title: g.value, subtitle: "Station", systemImage: "dot.radiowaves.left.and.right", colors: MacPalette.stable(g.value), width: nil, height: 90) {
                                    Task { await model.playGenreStation(g.value) }
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                }
                if !stations.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        MacShelfHeader(title: "Internet Radio")
                        ForEach(stations) { s in
                            Button { model.player.playRadio(s) } label: {
                                Label(s.name, systemImage: "antenna.radiowaves.left.and.right").padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 24)
                        }
                    }
                }
            }
            .padding(.vertical, 24)
        }
        .navigationTitle("Radio")
        .task {
            guard genres.isEmpty, let client = model.client else { return }
            async let g = try? client.genres()
            async let s = try? client.radioStations()
            genres = await g ?? []; stations = await s ?? []
        }
    }
}

// MARK: - Search

struct MacSearchView: View {
    let query: String
    @Environment(AppModel.self) private var model
    @State private var results: SearchResult?

    var body: some View {
        ScrollView {
            if let r = results {
                VStack(alignment: .leading, spacing: 28) {
                    MacArtistShelf(title: "Artists", artists: r.artist ?? [])
                    MacAlbumShelf(title: "Albums", albums: r.album ?? [])
                    if let songs = r.song, !songs.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            MacShelfHeader(title: "Songs")
                            MacSongTable(songs: songs)
                                .frame(height: min(CGFloat(songs.count) * 28 + 32, 520))
                                .padding(.horizontal, 24)
                        }
                    }
                    if (r.artist ?? []).isEmpty && (r.album ?? []).isEmpty && (r.song ?? []).isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
                .padding(.vertical, 24)
            } else {
                ContentUnavailableView("Search Your Library", systemImage: "magnifyingglass", description: Text("Find artists, albums and songs."))
                    .padding(.top, 80)
            }
        }
        .navigationTitle("Search")
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { results = nil; return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            results = try? await model.client?.search(q, artists: 12, albums: 20, songs: 50)
        }
    }
}

// MARK: - Library

struct MacArtistsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("library.artists.layout") private var layout = LibraryLayout.grid
    @State private var artists: [Artist] = []

    var body: some View {
        Group {
            if layout == .grid {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 20, alignment: .top)], spacing: 24) {
                        ForEach(artists) { MacArtistTile(artist: $0) }
                    }
                    .padding(24)
                }
            } else {
                List(artists) { artist in
                    NavigationLink(value: Route.artist(artist.id)) {
                        HStack(spacing: 12) {
                            MacArtwork(id: artist.artworkID, size: 120, circle: true)
                                .frame(width: 44, height: 44)
                            Text(artist.name)
                        }
                    }
                }
            }
        }
        .overlay { if artists.isEmpty { ProgressView() } }
        .navigationTitle("Artists")
        .toolbar { LibraryLayoutMenu(layout: $layout) }
        .task {
            guard artists.isEmpty else { return }
            artists = ((try? await model.client?.artists()) ?? []).flatMap { $0.artist ?? [] }
        }
    }
}

struct MacAlbumGridView: View {
    let title: String
    let type: String
    @Environment(AppModel.self) private var model
    @AppStorage("library.albums.layout") private var layout = LibraryLayout.grid
    @State private var albums: [Album] = []
    @State private var sort: String?
    @State private var done = false
    @State private var loading = false

    private var current: String { sort ?? type }
    private var showsViewOptions: Bool { type.hasPrefix("alphabetical") }

    var body: some View {
        Group {
            if showsViewOptions && layout == .list {
                List(albums) { album in
                    MacAlbumTile(album: album, listRow: true)
                        .onAppear {
                            if album.id == albums.last?.id { Task { await loadMore() } }
                        }
                }
            } else {
                ScrollView {
                    MacAlbumGrid(albums: albums) { Task { await loadMore() } }
                        .padding(.vertical, 24)
                }
            }
        }
        .navigationTitle(title)
        .toolbar {
            if showsViewOptions {
                LibraryLayoutMenu(layout: $layout)
                Picker("Sort", selection: Binding(get: { current }, set: { sort = $0 })) {
                    Text("Title").tag("alphabeticalByName")
                    Text("Artist").tag("alphabeticalByArtist")
                    Text("Recently Added").tag("newest")
                    Text("Recently Played").tag("recent")
                    Text("Most Played").tag("frequent")
                }
                .pickerStyle(.menu)
            }
        }
        .onChange(of: sort) { _, _ in albums = []; done = false; Task { await loadMore() } }
        .task { if albums.isEmpty { await loadMore() } }
    }

    private func loadMore() async {
        guard !loading, !done, let client = model.client else { return }
        loading = true
        defer { loading = false }
        let page = (try? await client.albumList(current, size: 80, offset: albums.count)) ?? []
        if page.count < 80 || type == "random" { done = true }
        let seen = Set(albums.map(\.id))
        albums += page.filter { !seen.contains($0.id) }
    }
}

struct MacSongsView: View {
    @Environment(AppModel.self) private var model
    @State private var songs: [Song] = []
    @State private var done = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacPlayShuffle(songs: songs).padding(.horizontal, 20).padding(.top, 16)
            MacSongTable(songs: songs)
        }
        .navigationTitle("Songs")
        .task {
            guard songs.isEmpty, let client = model.client else { return }
            while !done {
                let page = (try? await client.search("", artists: 0, albums: 0, songs: 500, songOffset: songs.count).song) ?? []
                songs += page
                if page.count < 500 || songs.count >= 20000 { done = true }
            }
        }
    }
}

struct MacGenresView: View {
    @Environment(AppModel.self) private var model
    @State private var genres: [Genre] = []

    var body: some View {
        ScrollView { MacGenreGrid(genres: genres).padding(.vertical, 24) }
            .navigationTitle("Genres")
            .task { if genres.isEmpty { genres = (try? await model.client?.genres()) ?? [] } }
    }
}

struct MacGenreView: View {
    let genre: String
    @Environment(AppModel.self) private var model
    @State private var albums: [Album] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MacMixTile(title: "\(genre) Station", subtitle: "Play", systemImage: "dot.radiowaves.left.and.right", colors: MacPalette.stable(genre), width: 320, height: 110) {
                    Task { await model.playGenreStation(genre) }
                }
                .padding(.horizontal, 24)
                MacAlbumGrid(albums: albums)
            }
            .padding(.vertical, 24)
        }
        .navigationTitle(genre)
        .task { if albums.isEmpty { albums = (try? await model.client?.albumList("byGenre", size: 300, genre: genre)) ?? [] } }
    }
}

struct MacLovedView: View {
    @Environment(AppModel.self) private var model
    @State private var starred: Starred?

    var body: some View {
        let songs = starred?.song ?? []
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    MacArtistShelf(title: "Artists", artists: starred?.artist ?? [])
                    MacAlbumShelf(title: "Albums", albums: starred?.album ?? [])
                    HStack {
                        Text("Songs").font(.title2.bold())
                        Spacer()
                        MacPlayShuffle(songs: songs)
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.vertical, 20)
            }
            .frame(maxHeight: (starred?.album ?? []).isEmpty && (starred?.artist ?? []).isEmpty ? 90 : 480)
            MacSongTable(songs: songs)
        }
        .navigationTitle("Favourites")
        .task { starred = try? await model.client?.starred() }
    }
}

struct MacDownloadsView: View {
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        let songs = downloads.sortedSongs
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                MacPlayShuffle(songs: songs)
                Spacer()
                if !downloads.inProgress.isEmpty {
                    ProgressView().controlSize(.small)
                    Text("Downloading \(downloads.inProgress.count)…").foregroundStyle(.secondary)
                }
                Text("\(songs.count) songs · \(ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file))")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            if songs.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle", description: Text("Right-click albums or songs and choose Download to listen offline."))
            } else {
                MacSongTable(songs: songs) { offsets in offsets.map { songs[$0].id }.forEach(downloads.remove) }
            }
        }
        .navigationTitle("Downloaded")
    }
}

struct MacPlaylistsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("library.playlists.layout") private var layout = LibraryLayout.list

    var body: some View {
        Group {
            if layout == .grid {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 20, alignment: .top)], spacing: 24) {
                        ForEach(model.playlists) { playlist in
                            NavigationLink(value: Route.playlist(playlist.id)) {
                                VStack(alignment: .leading, spacing: 6) {
                                    MacArtwork(id: playlist.coverArt, size: 400)
                                    playlistTitle(playlist)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(24)
                }
            } else {
                List(model.playlists) { playlist in
                    NavigationLink(value: Route.playlist(playlist.id)) {
                        HStack(spacing: 12) {
                            MacArtwork(id: playlist.coverArt, size: 120).frame(width: 44, height: 44)
                            playlistTitle(playlist)
                        }
                    }
                }
            }
        }
        .navigationTitle("Playlists")
        .toolbar { LibraryLayoutMenu(layout: $layout) }
    }

    private func playlistTitle(_ playlist: Playlist) -> some View {
        LibraryItemTitle(title: playlist.name, subtitle: "\(playlist.songCount ?? 0) songs")
    }
}

// MARK: - Detail pages

struct MacDetailHeader<Extra: View>: View {
    let artworkID: String?
    var circle = false
    let kind: String
    let title: String
    let subtitle: String?
    var onSubtitle: (() -> Void)? = nil
    let meta: String
    let songs: [Song]
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        HStack(alignment: .bottom, spacing: 24) {
            MacArtwork(id: artworkID, size: 600, corner: 8, circle: circle)
                .frame(width: 220, height: 220)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
            VStack(alignment: .leading, spacing: 6) {
                Text(kind.uppercased()).font(.caption.bold()).foregroundStyle(.secondary)
                Text(title).font(.largeTitle.bold()).lineLimit(2)
                if let subtitle {
                    Button { onSubtitle?() } label: { Text(subtitle).font(.title2).foregroundStyle(.tint) }
                        .buttonStyle(.plain)
                }
                Text(meta).font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    MacPlayShuffle(songs: songs)
                    extra()
                }
                .padding(.top, 8)
            }
            Spacer()
        }
        .padding(24)
    }
}

struct MacAlbumView: View {
    let id: String
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var album: AlbumDetail?
    @State private var more: [Album] = []
    @State private var similar: [Artist] = []

    var body: some View {
        let songs = album?.song ?? []
        ScrollView {
            if let album {
                VStack(alignment: .leading, spacing: 8) {
                    MacDetailHeader(
                        artworkID: album.coverArt, kind: "Album", title: album.name, subtitle: album.artist,
                        onSubtitle: { if let a = album.artistId { router.go(.artist(a)) } },
                        meta: [album.genre, album.year.map(String.init), "\(songs.count) songs", "\(songs.totalDuration / 60) min",
                               songs.contains(where: \.isLossless) ? "Lossless" : nil].compactMap { $0 }.joined(separator: " · "),
                        songs: songs
                    ) {
                        Button { model.toggleLove(album.id, kind: .album) } label: {
                            Image(systemName: model.isLoved(album.id) ? "star.fill" : "star")
                        }
                        .controlSize(.large)
                        Menu {
                            MacSongMenu(songs: songs)
                        } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    MacSongTable(songs: songs, showNumber: true, showAlbum: false)
                        .frame(height: CGFloat(songs.count) * 28 + 34)
                        .padding(.horizontal, 24)
                        .scrollDisabled(true)
                    VStack(alignment: .leading, spacing: 28) {
                        MacAlbumShelf(title: "More by \(album.artist ?? "Artist")", albums: more)
                        MacArtistShelf(title: "You Might Also Like", artists: similar)
                    }
                    .padding(.vertical, 24)
                }
            } else {
                ProgressView().padding(80).frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(album?.name ?? "")
        .task(id: id) {
            guard let client = model.client, let detail = try? await client.album(id) else { return }
            album = detail
            if let artistId = detail.artistId {
                async let a = try? client.artist(artistId)
                async let s = try? client.artistInfo(artistId)
                more = (await a)?.album?.filter { $0.id != id } ?? []
                similar = (await s)?.similarArtist ?? []
            }
        }
    }
}

struct MacArtistView: View {
    let id: String
    @Environment(AppModel.self) private var model
    @State private var artist: ArtistDetail?
    @State private var info: ArtistInfo?
    @State private var top: [Song] = []

    var body: some View {
        ScrollView {
            if let artist {
                let albums = (artist.album ?? []).sorted { ($0.year ?? 0) > ($1.year ?? 0) }
                VStack(alignment: .leading, spacing: 28) {
                    MacDetailHeader(artworkID: artist.artworkID, circle: true, kind: "Artist", title: artist.name, subtitle: nil,
                                    meta: "\(albums.count) albums", songs: top) {
                        Button { Task { await model.playArtistStation(artistId: artist.id, name: artist.name) } } label: {
                            Label("Station", systemImage: "dot.radiowaves.left.and.right")
                        }
                        .controlSize(.large)
                        Button { model.toggleLove(artist.id, kind: .artist) } label: {
                            Image(systemName: model.isLoved(artist.id) ? "star.fill" : "star")
                        }
                        .controlSize(.large)
                    }
                    if !top.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            MacShelfHeader(title: "Top Songs")
                            MacSongTable(songs: Array(top.prefix(10)))
                                .frame(height: CGFloat(min(top.count, 10)) * 28 + 34)
                                .padding(.horizontal, 24)
                                .scrollDisabled(true)
                        }
                    }
                    MacAlbumShelf(title: "Albums", albums: albums)
                    MacArtistShelf(title: "Similar Artists", artists: info?.similarArtist ?? [])
                    if let bio = info?.biography?.strippingHTML, !bio.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("About").font(.title2.bold())
                            Text(bio).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        .padding(.horizontal, 24)
                        .frame(maxWidth: 800, alignment: .leading)
                    }
                }
                .padding(.bottom, 24)
            } else {
                ProgressView().padding(80).frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(artist?.name ?? "")
        .task(id: id) {
            guard let client = model.client, let detail = try? await client.artist(id) else { return }
            artist = detail
            async let i = try? client.artistInfo(id)
            async let t = try? client.topSongs(artist: detail.name)
            info = await i
            top = await t ?? []
        }
    }
}

struct MacPlaylistView: View {
    let id: String
    @Environment(AppModel.self) private var model
    @State private var playlist: PlaylistDetail?
    @State private var confirmDelete = false

    var body: some View {
        let songs = playlist?.entry ?? []
        VStack(alignment: .leading, spacing: 0) {
            if let playlist {
                MacDetailHeader(artworkID: playlist.coverArt, kind: "Playlist", title: playlist.name, subtitle: playlist.owner,
                                meta: "\(songs.count) songs · \(songs.totalDuration / 60) min", songs: songs) {
                    Menu {
                        Button("Download") { model.downloads.download(songs) }
                        Button("Play Next") { model.player.playNext(songs) }
                        Divider()
                        Button("Delete Playlist", role: .destructive) { confirmDelete = true }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                MacSongTable(songs: songs) { offsets in
                    Task {
                        try? await model.client?.removeFromPlaylist(id, indexes: Array(offsets))
                        await load()
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(playlist?.name ?? "")
        .confirmationDialog("Delete this playlist?", isPresented: $confirmDelete) {
            Button("Delete Playlist", role: .destructive) {
                Task {
                    try? await model.client?.deletePlaylist(id)
                    await model.refreshPlaylists()
                }
            }
        }
        .task(id: id) { await load() }
    }

    private func load() async { playlist = try? await model.client?.playlist(id) }
}

// MARK: - Add to playlist

struct MacPlaylistPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        let songs = router.playlistPickerSongs ?? []
        VStack(alignment: .leading, spacing: 12) {
            Text("Add \(songs.count == 1 ? "“\(songs[0].title)”" : "\(songs.count) songs") to Playlist").font(.headline)
            List(model.playlists) { p in
                Button(p.name) {
                    Task {
                        try? await model.client?.addToPlaylist(p.id, songIds: songs.map(\.id))
                        await model.refreshPlaylists()
                        close()
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(height: 220)
            HStack {
                TextField("New playlist name", text: $newName)
                Button("Create") {
                    let name = newName
                    Task {
                        try? await model.client?.createPlaylist(name: name, songIds: songs.map(\.id))
                        await model.refreshPlaylists()
                        close()
                    }
                }
                .disabled(newName.isEmpty)
            }
            HStack { Spacer(); Button("Cancel") { close() }.keyboardShortcut(.cancelAction) }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func close() {
        router.playlistPickerSongs = nil
        dismiss()
    }
}
