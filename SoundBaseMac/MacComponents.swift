import SwiftUI
import AVKit

// MARK: - Artwork

struct MacArtwork: View {
    let id: String?
    var size: Int = 400
    var corner: CGFloat = 6
    var circle = false
    @Environment(AppModel.self) private var model
    @State private var image: NSImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Image(systemName: circle ? "music.mic" : "music.note").font(.title2).foregroundStyle(.tertiary)
                    }
                }
            }
            .clipShape(circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: corner, style: .continuous)))
            .task(id: id) {
                guard let id, let url = model.client?.coverURL(id, size: size) else { image = nil; return }
                if let hit = ImageLoader.shared.cached(url) { image = hit; return }
                image = nil
                image = await ImageLoader.shared.image(url)
            }
    }
}

struct AirPlayRouteButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        return view
    }
    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

// MARK: - Shelves & tiles

struct MacShelfHeader: View {
    let title: String
    var subtitle: String? = nil
    var route: Route? = nil
    @Environment(Router.self) private var router

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
                Text(title).font(.title2.bold())
            }
            Spacer()
            if let route {
                Button("See All") { router.go(route) }.buttonStyle(.link)
            }
        }
        .padding(.horizontal, 24)
    }
}

struct MacAlbumTile: View {
    let album: Album
    var width: CGFloat = 170
    var listRow = false
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var hover = false

    var body: some View {
        Group {
            if listRow {
                NavigationLink(value: Route.album(album.id)) {
                    HStack(spacing: 12) {
                        MacArtwork(id: album.coverArt, size: 120).frame(width: 44, height: 44)
                        LibraryItemTitle(title: album.name, subtitle: album.artist)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    MacArtwork(id: album.coverArt, size: 400)
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                        .overlay(alignment: .bottomLeading) {
                            if hover {
                                Button { Task { await model.playAlbum(album.id) } } label: {
                                    Image(systemName: "play.fill")
                                        .frame(width: 32, height: 32)
                                        .background(.tint, in: Circle())
                                        .foregroundStyle(.white)
                                }
                                .buttonStyle(.plain)
                                .padding(8)
                            }
                        }
                    Text(album.name).font(.callout).lineLimit(1)
                    Text(album.artist ?? "").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(width: width)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
                .onTapGesture { router.go(.album(album.id)) }
            }
        }
        .contextMenu {
            Button("Play") { Task { await model.playAlbum(album.id) } }
            Button("Shuffle") { Task { await model.playAlbum(album.id, shuffled: true) } }
            Button("Play Next") { Task { if let s = try? await model.client?.album(album.id)?.song { model.player.playNext(s) } } }
            Button("Add to Queue") { Task { if let s = try? await model.client?.album(album.id)?.song { model.player.addToQueue(s) } } }
            Divider()
            Button(model.isLoved(album.id) ? "Unfavourite" : "Favourite") { model.toggleLove(album.id, kind: .album) }
            if model.downloads.savedAlbum("id:\(album.id)") == nil {
                Button("Download Album") {
                    Task {
                        guard let client = model.client, let tracks = try? await client.album(album.id)?.song,
                              model.client?.creds.libraryKey == client.creds.libraryKey else { return }
                        model.downloads.downloadAlbum(id: album.id, name: album.name, tracks: tracks)
                    }
                }
            }
            if let artistId = album.artistId {
                Divider()
                Button("Go to Artist") { router.go(.artist(artistId)) }
            }
        }
    }
}

struct MacArtistTile: View {
    let artist: Artist
    var width: CGFloat = 140
    @Environment(Router.self) private var router

    var body: some View {
        VStack(spacing: 6) {
            MacArtwork(id: artist.artworkID, size: 400, circle: true)
            Text(artist.name).font(.callout).lineLimit(1)
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .onTapGesture { router.go(.artist(artist.id)) }
    }
}

struct MacAlbumShelf: View {
    let title: String
    var subtitle: String? = nil
    let albums: [Album]
    var route: Route? = nil

    var body: some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                MacShelfHeader(title: title, subtitle: subtitle, route: route)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 18) {
                        ForEach(albums) { MacAlbumTile(album: $0) }
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
    }
}

struct MacArtistShelf: View {
    let title: String
    var subtitle: String? = nil
    let artists: [Artist]
    var route: Route? = nil

    var body: some View {
        if !artists.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                MacShelfHeader(title: title, subtitle: subtitle, route: route)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 20) {
                        ForEach(artists) { MacArtistTile(artist: $0) }
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
    }
}

struct MacAlbumGrid: View {
    let albums: [Album]
    var onLast: (() -> Void)? = nil

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 20, alignment: .top)], spacing: 24) {
            ForEach(albums) { album in
                GeometryReader { geo in MacAlbumTile(album: album, width: geo.size.width) }
                    .aspectRatio(0.78, contentMode: .fit)
                    .onAppear { if album.id == albums.last?.id { onLast?() } }
            }
        }
        .padding(.horizontal, 24)
    }
}

struct MacMixTile: View {
    let title: String
    var subtitle: String? = nil
    var systemImage = "music.note"
    var colors: [Color]
    var width: CGFloat? = 260
    var height: CGFloat = 150
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: systemImage)
                    .font(.system(size: 60, weight: .bold))
                    .foregroundStyle(.white.opacity(0.18))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(14)
                VStack(alignment: .leading, spacing: 2) {
                    if let subtitle { Text(subtitle.uppercased()).font(.caption2.bold()).opacity(0.8) }
                    Text(title).font(.title3.bold())
                }
                .foregroundStyle(.white)
                .padding(14)
            }
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

enum MacPalette {
    static let sets: [[Color]] = [
        [Color(hex: 0xFA2D48), Color(hex: 0x8C0D59)],
        [Color(hex: 0x5C4DF2), Color(hex: 0x1A8CF2)],
        [Color(hex: 0xFF8C1A), Color(hex: 0xE6334D)],
        [Color(hex: 0x1AB38C), Color(hex: 0x0D598C)],
        [Color(hex: 0xBF40D9), Color(hex: 0x591A99)],
        [Color(hex: 0xF2BF26), Color(hex: 0xD9661A)],
    ]
    static func stable(_ key: String) -> [Color] {
        sets[key.unicodeScalars.reduce(0) { $0 + Int($1.value) } % sets.count]
    }
}

// MARK: - Song table

struct MacPlayingIndicator: View {
    var animating: Bool
    var body: some View {
        Image(systemName: "waveform")
            .symbolEffect(.variableColor.iterative, isActive: animating)
            .foregroundStyle(.tint)
    }
}

/// A native Mac track list: sortable-looking columns, double-click to play, context menu.
struct MacSongTable: View {
    let songs: [Song]
    var showNumber = false
    var showAlbum = true
    var playSingle = false
    var query = ""
    var onDelete: ((IndexSet) -> Void)? = nil
    @Environment(AppModel.self) private var model
    @Environment(Player.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @State private var selection = Set<Int>()

    private struct Row: Identifiable {
        let id: Int
        let song: Song
    }

    var body: some View {
        let rows = songs.enumerated().compactMap { index, song in
            song.matchesDownloadSearch(query) ? Row(id: index, song: song) : nil
        }
        Table(rows, selection: $selection) {
            TableColumn("") { row in
                Group {
                    if player.current?.id == row.song.id {
                        MacPlayingIndicator(animating: player.isPlaying)
                    } else if showNumber {
                        Text("\(row.song.track ?? row.id + 1)").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(28)
            TableColumn("Title") { row in
                HStack(spacing: 6) {
                    Text(row.song.title).lineLimit(1)
                    if model.isLoved(row.song.id) { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.tint) }
                    if downloads.isDownloaded(row.song.id) {
                        Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            TableColumn("Artist") { row in Text(row.song.artist ?? "").foregroundStyle(.secondary).lineLimit(1) }
            if showAlbum {
                TableColumn("Album") { row in Text(row.song.album ?? "").foregroundStyle(.secondary).lineLimit(1) }
            }
            TableColumn("Time") { row in
                Text(formatTime(Double(row.song.duration ?? 0))).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(56)
            TableColumn("") { row in
                QueueTrackButton(song: row.song).id(row.song.id)
            }
            .width(32)
        }
        .contextMenu(forSelectionType: Int.self) { ids in
            let picked = ids.sorted().filter { songs.indices.contains($0) }.map { songs[$0] }
            if !picked.isEmpty { MacSongMenu(songs: picked, onDelete: onDelete.map { del in { del(IndexSet(ids)) } }) }
        } primaryAction: { ids in
            guard let first = ids.min(), songs.indices.contains(first) else { return }
            if playSingle { model.playFromLibrary([songs[first]]) }
            else { model.playFromLibrary(songs, startAt: first) }
        }
        .onChange(of: query) { _, _ in selection = [] }
        .onDeleteCommand { if let onDelete, !selection.isEmpty { onDelete(IndexSet(selection)); selection = [] } }
    }
}

struct MacSongMenu: View {
    let songs: [Song]
    var album: OfflineAlbum? = nil
    var onDelete: (() -> Void)? = nil
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        let player = model.player
        Button("Play") { model.playFromLibrary(songs) }
        Button("Play Next") { player.playNext(songs) }
        Button("Add to Queue") { player.addToQueue(songs) }
        Divider()
        Button("Add to Playlist…") { router.playlistPickerSongs = songs }
        if songs.count == 1, let song = songs.first {
            Button(model.isLoved(song.id) ? "Unfavourite" : "Favourite") { model.toggleLove(song.id, kind: .song) }
        }
        if let album {
            if model.downloads.savedAlbum(album.id) == nil && !songs.isEmpty {
                Button("Download Album") { model.downloads.downloadAlbum(album) }
            }
        } else {
            let tracks = songs.filter { !$0.isRadio }
            if tracks.contains(where: { model.downloads.canRemoveTrack($0.id) }) {
                Button("Remove Track Downloads") { model.downloads.removeTracks(tracks.map(\.id)) }
            }
            if tracks.contains(where: { !model.downloads.isDownloaded($0.id) || !model.downloads.canRemoveTrack($0.id) }) {
                Button("Download Tracks") { model.downloads.download(tracks) }
            }
        }
        if let song = songs.first, songs.count == 1 {
            Divider()
            Button("Create Station") { router.go(.generated(.song(song))) }
            if let albumId = song.albumId { Button("Go to Album") { router.go(.album(albumId)) } }
            if let artistId = song.artistId { Button("Go to Artist") { router.go(.artist(artistId)) } }
        }
        if album == nil, songs.count == 1, let song = songs.first, !song.isRadio {
            LibraryEditButton(edit: LibraryEdit(song))
        }
        if let onDelete {
            Divider()
            Button("Remove", role: .destructive, action: onDelete)
        }
    }
}

struct MacPlayShuffle: View {
    let songs: [Song]
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Button { model.playFromLibrary(songs) } label: { Label("Play", systemImage: "play.fill").frame(minWidth: 70) }
                .buttonStyle(.borderedProminent)
            Button { model.playFromLibrary(songs, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle").frame(minWidth: 70) }
                .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .disabled(songs.isEmpty)
    }
}

extension View {
    func macRoutes() -> some View {
        navigationDestination(for: Route.self) { MacRouteView(route: $0) }
    }
}

struct MacRouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case .album(let id): MacAlbumView(id: id)
        case .artist(let id): MacArtistView(id: id)
        case .playlist(let id): MacPlaylistView(id: id)
        case .generated(let playlist): MacGeneratedPlaylistView(playlist: playlist)
        case .searchResults(let query, let category): MacSearchCategoryView(query: query, category: category)
        case .radio(let station): LiveRadioView(station: station)
        case .genre(let name): MacGenreView(genre: name)
        case .albums(let title, let type): MacAlbumGridView(title: title, type: type)
        case .artists: MacArtistsView()
        case .songs: MacSongsView()
        case .playlists: MacPlaylistsView()
        case .genres: MacGenresView()
        case .loved: MacLovedView()
        case .downloads: MacDownloadsView()
        case .history: MacListeningHistoryView()
        }
    }
}
