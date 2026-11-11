import SwiftUI

// MARK: - Home

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @AppStorage(HomeLayout.recentPlaylistsKey) private var showRecentPlaylists = true
    @AppStorage(HomeLayout.orderKey) private var sectionOrder = ""
    @AppStorage(HomeLayout.hiddenSectionsKey) private var hiddenSections = ""
    @AppStorage(HomeLayout.hiddenMixesKey) private var hiddenMixes = ""
    @State private var editingHome = false
    @State private var recent: [Album] = []
    @State private var frequent: [Album] = []
    @State private var newest: [Album] = []
    @State private var starred: [Album] = []
    @State private var rediscover: [Album] = []
    @State private var similar: [Artist] = []
    @State private var similarSeed: String?
    @State private var becauseAlbums: [Album] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                ForEach(visibleSections) { section in
                    homeSection(section)
                }
                if visibleSections.isEmpty {
                    ContentUnavailableView("Home is empty", systemImage: "rectangle.stack",
                                           description: Text("Use Edit Home to show sections."))
                }
                if !loaded { ProgressView().frame(maxWidth: .infinity).padding(40) }
            }
            .padding(.vertical)
        }
        .navigationTitle("Home")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                editHomeButton
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { router.showSettings = true } label: { Image(systemName: "person.crop.circle") }
            }
        }
        .refreshable { await load() }
        .sheet(isPresented: $editingHome) {
            NavigationStack {
                HomeLayoutSettings()
                    .toolbar { Button("Done") { editingHome = false } }
            }
        }
        .task { if !loaded { await load() } }
    }

    private var visibleSections: [HomeSection] {
        HomeSection.order(from: sectionOrder).filter {
            HomeLayout.isVisible($0.id, in: hiddenSections)
                && ($0 != .recentPlaylists || (showRecentPlaylists && !model.recentPlaylists.isEmpty))
                && ($0 != .mixes || HomeMix.available.contains(where: mixIsVisible))
        }
    }

    private var editHomeButton: some View {
        Button { editingHome = true } label: {
            Label("Edit Home", systemImage: "slider.horizontal.3")
        }
    }

    @ViewBuilder private func homeSection(_ section: HomeSection) -> some View {
        switch section {
        case .recentPlaylists:
            RecentPlaylistCards(playlists: model.recentPlaylists)
        case .mixes:
            mixes
        case .recent:
            AlbumShelf(title: "Recently Played", albums: recent, route: .albums(title: "Recently Played", type: "recent"))
        case .history:
            NavigationLink(value: Route.history) {
                Label("Listening History", systemImage: "clock.arrow.circlepath")
            }
            .padding(.horizontal)
        case .similar:
            if let seed = similarSeed {
                ArtistShelf(title: "You Might Also Like", subtitle: "Because you listened to \(seed)", artists: similar)
            }
        case .newest:
            AlbumShelf(title: "Recently Added", albums: newest, route: .albums(title: "Recently Added", type: "newest"))
        case .frequent:
            AlbumShelf(title: "Most Played", albums: frequent, route: .albums(title: "Most Played", type: "frequent"))
        case .favourites:
            AlbumShelf(title: "Favourite Albums", albums: starred, route: .albums(title: "Favourite Albums", type: "starred"))
        case .rediscover:
            AlbumShelf(title: "Rediscover", subtitle: "From your library", albums: rediscover, route: .albums(title: "Rediscover", type: "random"))
        }
    }

    private func mixIsVisible(_ mix: HomeMix) -> Bool {
        guard HomeLayout.isVisible(mix.id, in: hiddenMixes) else { return false }
        return mix != .artistStation || (recent.first?.artistId != nil && recent.first?.artist != nil)
    }

    private var mixes: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfHeader(title: "Made For You")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    if mixIsVisible(.favourites) {
                        MixTile(title: "Favourites Mix", subtitle: "Your starred songs", systemImage: "star.fill", colors: Palette.sets[0]) {
                            model.router.go(.generated(.favourites))
                        }
                    }
                    if mixIsVisible(.discovery) {
                        MixTile(title: "Discovery Mix", subtitle: "Deep cuts from your library", systemImage: "sparkles", colors: Palette.sets[1]) {
                            model.router.go(.generated(.discovery))
                        }
                    }
                    if mixIsVisible(.artistStation), let seedAlbum = recent.first, let artistId = seedAlbum.artistId, let name = seedAlbum.artist {
                        MixTile(title: "\(name) Station", subtitle: "Inspired by recent listening", systemImage: "dot.radiowaves.left.and.right", colors: Palette.sets[2]) {
                            model.router.go(.generated(.artist(id: artistId, name: name)))
                        }
                    }
                    if mixIsVisible(.heavyRotation) {
                        MixTile(title: "Heavy Rotation", subtitle: "Your most played", systemImage: "flame.fill", colors: Palette.sets[4]) {
                            router.go(.generated(.heavyRotation))
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func load() async {
        guard let client = model.client else { return }
        async let r = try? client.albumList("recent", size: 20)
        async let f = try? client.albumList("frequent", size: 20)
        async let n = try? client.albumList("newest", size: 20)
        async let s = try? client.albumList("starred", size: 20)
        async let x = try? client.albumList("random", size: 20)
        recent = await r ?? []
        frequent = await f ?? []
        newest = await n ?? []
        starred = await s ?? []
        rediscover = await x ?? []
        loaded = true
        if let seed = recent.first(where: { $0.artistId != nil }), let artistId = seed.artistId {
            let info = try? await client.artistInfo(artistId)
            similar = info?.similarArtist ?? []
            similarSeed = similar.isEmpty ? nil : seed.artist
        }
    }
}

// MARK: - New / Browse

struct BrowseView: View {
    @Environment(AppModel.self) private var model
    @State private var newest: [Album] = []
    @State private var highest: [Album] = []
    @State private var random: [Album] = []
    @State private var genres: [Genre] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                if let hero = newest.first {
                    HeroAlbum(album: hero)
                }
                AlbumShelf(title: "New Releases", albums: Array(newest.dropFirst()), route: .albums(title: "New Releases", type: "newest"))
                AlbumShelf(title: "Top Rated", albums: highest, route: .albums(title: "Top Rated", type: "highest"))
                AlbumShelf(title: "Random Picks", albums: random, route: .albums(title: "Random Picks", type: "random"))
                GenreGrid(genres: Array(genres.prefix(12)), title: "Browse by Genre")
            }
            .padding(.vertical)
        }
        .navigationTitle("New")
        .refreshable { await load() }
        .task { if newest.isEmpty { await load() } }
    }

    private func load() async {
        guard let client = model.client else { return }
        async let n = try? client.albumList("newest", size: 21)
        async let h = try? client.albumList("highest", size: 20)
        async let r = try? client.albumList("random", size: 20)
        async let g = try? client.genres()
        newest = await n ?? []
        highest = await h ?? []
        random = await r ?? []
        genres = await g ?? []
    }
}

struct HeroAlbum: View {
    let album: Album
    @Environment(Router.self) private var router
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LATEST ADDITION").font(.caption.bold()).foregroundStyle(.secondary).padding(.horizontal)
            Button { router.go(.album(album.id)) } label: {
                ZStack(alignment: .bottomLeading) {
                    Artwork(id: album.coverArt, size: 1000, corner: 16)
                    LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(album.name).font(.title2.bold()).lineLimit(2)
                            Text(album.artist ?? "").font(.headline).opacity(0.8)
                        }
                        Spacer()
                        Button { Task { await model.playAlbum(album.id) } } label: {
                            Image(systemName: "play.fill").font(.title2).frame(width: 52, height: 52).background(.white, in: Circle()).foregroundStyle(.black)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(18)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
        }
    }
}

struct GenreGrid: View {
    let genres: [Genre]
    var title: String = "Genres"
    @Environment(Router.self) private var router

    var body: some View {
        if !genres.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ShelfHeader(title: title, route: .genres)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(genres) { genre in
                        MixTile(title: genre.value, systemImage: "music.quarternote.3", colors: Palette.stable(genre.value), width: nil, height: 100) {
                            router.go(.genre(genre.value))
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

// MARK: - Radio

struct RadioView: View {
    @Environment(AppModel.self) private var model
    @State private var genres: [Genre] = []
    @State private var stations: [RadioStation] = []
    @State private var artists: [Artist] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                VStack(spacing: 14) {
                    MixTile(title: "Discovery Station", subtitle: "A mix from your library", systemImage: "dot.radiowaves.left.and.right", colors: Palette.sets[1], width: nil, height: 200) {
                        model.router.go(.generated(.discoveryStation))
                    }
                    MixTile(title: "Favourites Station", subtitle: "Starred songs, shuffled", systemImage: "star.fill", colors: Palette.sets[0], width: nil, height: 120) {
                        model.router.go(.generated(.favouritesStation))
                    }
                }
                .padding(.horizontal)

                if !artists.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ShelfHeader(title: "Artist Stations")
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 16) {
                                ForEach(artists) { artist in
                                    Button { model.router.go(.generated(.artist(id: artist.id, name: artist.name))) } label: {
                                        VStack(spacing: 6) {
                                            Artwork(id: artist.artworkID, size: 300, circle: true)
                                                .overlay(alignment: .bottomTrailing) {
                                                    Image(systemName: "dot.radiowaves.left.and.right")
                                                        .font(.caption.bold()).padding(6)
                                                        .background(.tint, in: Circle()).foregroundStyle(.white)
                                                }
                                            Text(artist.name).font(.subheadline).lineLimit(1)
                                        }
                                        .frame(width: 120)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }

                if !genres.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ShelfHeader(title: "Genre Stations")
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                            ForEach(genres.prefix(16)) { genre in
                                MixTile(title: genre.value, subtitle: "Station", systemImage: "dot.radiowaves.left.and.right", colors: Palette.stable(genre.value), width: nil, height: 100) {
                                    model.router.go(.generated(.genre(genre.value)))
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }

                if !stations.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ShelfHeader(title: "Internet Radio")
                        ForEach(stations) { station in
                            Button { model.router.go(.radio(station)) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .frame(width: 46, height: 46)
                                        .background(LinearGradient(colors: Palette.stable(station.name), startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 8))
                                        .foregroundStyle(.white)
                                    Text(station.name).foregroundStyle(.primary)
                                    Spacer()
                                }
                                .padding(.horizontal).padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Radio")
        .task {
            guard genres.isEmpty, let client = model.client else { return }
            async let g = try? client.genres()
            async let s = try? client.radioStations()
            async let f = try? client.albumList("frequent", size: 30)
            genres = await g ?? []
            stations = await s ?? []
            var seen = Set<String>()
            artists = (await f ?? []).compactMap { album in
                guard let id = album.artistId, let name = album.artist, seen.insert(id).inserted else { return nil }
                return Artist(id: id, name: name)
            }
        }
    }
}
