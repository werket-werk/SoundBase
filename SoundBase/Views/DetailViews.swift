import SwiftUI

// MARK: - Album

struct AlbumView: View {
    let id: String
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var album: AlbumDetail?
    @State private var info: AlbumInfo?
    @State private var more: [Album] = []
    @State private var similar: [Artist] = []
    @State private var showNotes = false
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let album {
                ScrollView {
                    let songs = album.song ?? []
                    let downloaded = songs.filter { model.downloads.isDownloaded($0.id) }.count
                    VStack(spacing: 0) {
                        Artwork(id: album.coverArt, size: 1000, corner: 10)
                            .frame(width: 270)
                            .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
                            .padding(.top, 8)
                        Text(album.name)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                            .padding(.top, 18)
                        Button { if let a = album.artistId { router.go(.artist(a)) } } label: {
                            Text(album.artist ?? "").font(.title2).foregroundStyle(.tint)
                        }
                        .buttonStyle(.plain)
                        HStack(spacing: 6) {
                            Text([album.genre, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · ").uppercased())
                            if songs.contains(where: \.isLossless) {
                                Label("Lossless", systemImage: "waveform").labelStyle(.titleAndIcon)
                            }
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)

                        if downloaded > 0 {
                            Label(downloaded == songs.count ? "Downloaded" : "\(downloaded) of \(songs.count) downloaded",
                                  systemImage: downloaded == songs.count ? "checkmark.circle" : "arrow.down.circle")
                                .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
                        }
                        PlayShuffleButtons(
                            play: { model.playFromLibrary(songs) },
                            shuffle: { model.playFromLibrary(songs, shuffled: true) })
                            .padding(.horizontal)
                            .padding(.vertical, 18)

                        if let notes = info?.notes?.strippingHTML, !notes.isEmpty {
                            Text(notes)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(showNotes ? nil : 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                                .padding(.bottom, 12)
                                .onTapGesture { withAnimation { showNotes.toggle() } }
                        }

                        Divider().padding(.leading)
                        trackList(songs)

                        Text("\(songs.count) songs, \(songs.totalDuration / 60) minutes")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()

                        VStack(alignment: .leading, spacing: 30) {
                            AlbumShelf(title: "More by \(album.artist ?? "Artist")", albums: more)
                            ArtistShelf(title: "You Might Also Like", artists: similar)
                        }
                        .padding(.vertical)
                    }
                }
            } else if let local = model.downloads.albums.first(where: { $0.id == "id:\(id)" }),
                      let first = local.tracks.first {
                OfflineTracksView(title: first.album ?? "Downloaded Album", tracks: local.tracks)
            } else if loadFailed {
                ContentUnavailableView {
                    Label("Couldn’t Open Album", systemImage: "exclamationmark.circle")
                } actions: {
                    Button("Retry") { Task { await load() } }
                }
            } else {
                ProgressView().padding(80)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let album {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { model.toggleLove(album.id, kind: .album) } label: {
                        Image(systemName: model.isLoved(album.id) ? "star.fill" : "star")
                    }
                    Menu {
                        let songs = album.song ?? []
                        Button { model.downloads.download(songs) } label: { Label("Download", systemImage: "arrow.down.circle") }
                        Button { router.playlistPickerSongs = songs } label: { Label("Add to Playlist…", systemImage: "text.badge.plus") }
                        Button { model.player.playNext(songs) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                        Button { model.player.addToQueue(songs) } label: { Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") }
                        if let artistId = album.artistId, let name = album.artist {
                            Button { model.router.go(.generated(.artist(id: artistId, name: name))) } label: {
                                Label("Create Station", systemImage: "dot.radiowaves.left.and.right")
                            }
                        }
                    } label: { Image(systemName: "ellipsis") }
                }
            }
        }
        .task(id: id) { await load() }
    }

    @ViewBuilder
    private func trackList(_ songs: [Song]) -> some View {
        let discs = Set(songs.compactMap(\.discNumber))
        LazyVStack(spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.element.id) { i, song in
                if discs.count > 1, i == 0 || songs[i - 1].discNumber != song.discNumber {
                    Text("Disc \(song.discNumber ?? 1)")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal).padding(.top, 16).padding(.bottom, 4)
                }
                SongRow(song: song, number: song.track ?? i + 1,
                        subtitle: song.artist != album?.artist ? song.artist : nil) {
                    model.playFromLibrary(songs, startAt: i)
                }
                .padding(.horizontal)
                Divider().padding(.leading, 54)
            }
        }
    }

    private func load() async {
        loadFailed = false
        guard let client = model.client, let detail = try? await client.album(id) else {
            if !Task.isCancelled { loadFailed = true }
            return
        }
        guard !Task.isCancelled else { return }
        album = detail
        async let i = try? client.albumInfo(id)
        if let artistId = detail.artistId {
            async let a = try? client.artist(artistId)
            async let s = try? client.artistInfo(artistId)
            more = (await a)?.album?.filter { $0.id != id } ?? []
            similar = (await s)?.similarArtist ?? []
        }
        info = await i
    }
}

// MARK: - Artist

struct ArtistView: View {
    let id: String
    @Environment(AppModel.self) private var model
    @State private var artist: ArtistDetail?
    @State private var info: ArtistInfo?
    @State private var top: [Song] = []
    @State private var showAllTop = false
    @State private var showBio = false

    var body: some View {
        ScrollView {
            if let artist {
                VStack(alignment: .leading, spacing: 28) {
                    header(artist)
                    if !top.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ShelfHeader(title: "Top Songs")
                            ForEach(Array(top.prefix(showAllTop ? 20 : 5).enumerated()), id: \.element.id) { i, song in
                                SongRow(song: song, subtitle: song.album) { model.playFromLibrary(top, startAt: i) }
                                    .padding(.horizontal)
                            }
                            if top.count > 5 {
                                Button(showAllTop ? "Show Less" : "Show More") { withAnimation { showAllTop.toggle() } }
                                    .padding(.horizontal)
                            }
                        }
                    }
                    let albums = (artist.album ?? []).sorted { ($0.year ?? 0) > ($1.year ?? 0) }
                    if let latest = albums.first {
                        VStack(alignment: .leading, spacing: 10) {
                            ShelfHeader(title: "Latest Release")
                            NavigationLink(value: Route.album(latest.id)) {
                                HStack(spacing: 14) {
                                    Artwork(id: latest.coverArt, size: 300).frame(width: 110)
                                    VStack(alignment: .leading, spacing: 4) {
                                        if let y = latest.year { Text(String(y)).font(.caption.bold()).foregroundStyle(.secondary) }
                                        Text(latest.name).font(.headline).foregroundStyle(.primary)
                                        Text("\(latest.songCount ?? 0) songs").font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal)
                        }
                    }
                    AlbumShelf(title: "Albums", albums: albums)
                    ArtistShelf(title: "Similar Artists", artists: info?.similarArtist ?? [])
                    if let bio = info?.biography?.strippingHTML, !bio.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("About \(artist.name)").font(.title2.bold())
                            Text(bio)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(showBio ? nil : 5)
                                .onTapGesture { withAnimation { showBio.toggle() } }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.bottom, 30)
            } else {
                ProgressView().padding(80).frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(artist?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let artist {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { model.toggleLove(artist.id, kind: .artist) } label: {
                        Image(systemName: model.isLoved(artist.id) ? "star.fill" : "star")
                    }
                    Menu {
                        Button { model.router.go(.generated(.artist(id: artist.id, name: artist.name))) } label: {
                            Label("Create Station", systemImage: "dot.radiowaves.left.and.right")
                        }
                        Button { Task { await shuffleAll(artist) } } label: { Label("Shuffle All", systemImage: "shuffle") }
                    } label: { Image(systemName: "ellipsis") }
                }
            }
        }
        .task(id: id) { await load() }
    }

    private func header(_ artist: ArtistDetail) -> some View {
        ZStack(alignment: .bottomLeading) {
            Artwork(id: artist.artworkID, size: 1000, corner: 0)
                .frame(maxWidth: .infinity)
                .frame(height: 340)
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
            HStack(alignment: .bottom) {
                Text(artist.name).font(.largeTitle.bold()).foregroundStyle(.white).lineLimit(2)
                Spacer()
                Button {
                    if top.isEmpty { Task { await shuffleAll(artist) } } else { model.playFromLibrary(top) }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.title2)
                        .frame(width: 54, height: 54)
                        .background(.tint, in: Circle())
                        .foregroundStyle(.white)
                }
            }
            .padding()
        }
        .frame(height: 340)
    }

    private func shuffleAll(_ artist: ArtistDetail) async {
        guard let client = model.client else { return }
        var songs: [Song] = []
        for album in artist.album ?? [] { songs += (try? await client.album(album.id))?.song ?? [] }
        model.playFromLibrary(songs, shuffled: true)
    }

    private func load() async {
        guard let client = model.client, let detail = try? await client.artist(id) else { return }
        artist = detail
        async let i = try? client.artistInfo(id)
        async let t = try? client.topSongs(artist: detail.name)
        info = await i
        top = await t ?? []
    }
}

// MARK: - Playlist

struct PlaylistView: View {
    let id: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var playlist: PlaylistDetail?
    @State private var query = ""
    @State private var loadFailed = false
    @State private var writeError: String?
    @State private var saving = false
    @State private var confirmDelete = false
    @State private var renaming = false
    @State private var name = ""
    @State private var reorder = false

    private var downloaded: DownloadedPlaylist? { model.downloads.playlistIndex.playlists[id] }
    private var canEdit: Bool {
        guard let playlist else { return false }
        return playlist.readonly != true && (playlist.owner == nil || playlist.owner == model.credentials?.username)
    }

    var body: some View {
        Group {
            if let playlist {
                onlinePlaylist(playlist)
            } else if let downloaded {
                OfflineTracksView(title: downloaded.name, tracks: downloaded.tracks, playlist: downloaded)
            } else if loadFailed {
                ContentUnavailableView {
                    Label("Couldn’t Open Playlist", systemImage: "exclamationmark.circle")
                } actions: {
                    Button("Retry") { Task { await load() } }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                let pinned = model.pinnedPlaylistIDs.contains(id)
                Button(pinned ? "Unpin from Library" : "Pin to Library",
                       systemImage: pinned ? "pin.slash" : "pin") { model.togglePlaylistPin(id) }
                if let playlist {
                    Button("Download", systemImage: "arrow.down.circle") {
                        model.downloads.downloadPlaylist(playlist.downloadedCopy)
                    }
                    Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                        model.player.playNext(playlist.entry ?? [])
                    }
                    if canEdit {
                        Button("Rename", systemImage: "pencil") { name = playlist.name; renaming = true }
                        Button("Reorder Tracks", systemImage: "list.number") { reorder = true }
                            .disabled((playlist.entry ?? []).count < 2)
                        Button("Delete Playlist", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    }
                }
            } label: { Image(systemName: "ellipsis") }
            .disabled(saving || (playlist == nil && downloaded == nil))
        }
        .alert("Rename Playlist", isPresented: $renaming) {
            TextField("Playlist Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return }
                write { try await $0.renamePlaylist(id, name: title) }
            }
        }
        .alert("Couldn’t Update Playlist", isPresented: Binding(
            get: { writeError != nil }, set: { if !$0 { writeError = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(writeError ?? "") }
        .confirmationDialog("Delete this playlist?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) {
                write(delete: true) { try await $0.deletePlaylist(id) }
            }
        }
        .sheet(isPresented: $reorder) {
            if let playlist {
                PlaylistOrderEditor(playlist: playlist) { updated in self.playlist = updated }
            }
        }
        .task(id: id) { await load() }
    }

    private func onlinePlaylist(_ playlist: PlaylistDetail) -> some View {
        let songs = playlist.entry ?? []
        return List {
            if query.isEmpty {
                VStack(spacing: 10) {
                    Artwork(id: playlist.coverArt, size: 800, corner: 10)
                        .frame(width: 240)
                        .shadow(color: .black.opacity(0.2), radius: 18, y: 10)
                    Text(playlist.name).font(.title2.bold()).multilineTextAlignment(.center)
                    if let owner = playlist.owner { Text(owner).font(.headline).foregroundStyle(.tint) }
                    if let comment = playlist.comment, !comment.isEmpty {
                        Text(comment).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if let downloaded { OfflinePlaylistActions(playlist: downloaded, dismissAfterRemoval: false) }
                    PlayShuffleButtons(play: { model.playFromLibrary(songs) },
                                       shuffle: { model.playFromLibrary(songs, shuffled: true) })
                        .padding(.top, 6)
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            }
            let matches = songs.indices.filter { songs[$0].matchesDownloadSearch(query) }
            ForEach(matches, id: \.self) { i in
                SongRow(song: songs[i]) { model.playFromLibrary(songs, startAt: i) }
            }
            .onDelete(perform: canEdit && query.isEmpty && !saving ? remove : nil)
            if query.isEmpty {
                Text("\(songs.count) songs, \(songs.totalDuration / 60) minutes")
                    .font(.subheadline).foregroundStyle(.secondary).listRowSeparator(.hidden)
            } else if matches.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, prompt: "Find in Playlist")
        .refreshable { if !saving { await load() } }
    }

    private func load() async {
        loadFailed = false
        guard let client = model.client, let opened = try? await client.playlist(id) else {
            if !Task.isCancelled { loadFailed = true }
            return
        }
        guard !Task.isCancelled, model.client === client else { return }
        playlist = opened
        model.recordPlaylistOpen(id, using: client)
    }

    private func remove(_ offsets: IndexSet) {
        write { try await $0.removeFromPlaylist(id, indexes: Array(offsets)) }
    }

    private func write(delete: Bool = false, operation: @escaping (SubsonicClient) async throws -> Void) {
        guard !saving, let client = model.client else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await operation(client)
                if delete {
                    if model.pinnedPlaylistIDs.contains(id) { model.togglePlaylistPin(id) }
                    dismiss()
                } else {
                    await load()
                }
                await model.refreshPlaylists()
            } catch {
                writeError = error.localizedDescription
            }
        }
    }
}

private struct PlaylistOrderEditor: View {
    private struct Entry: Identifiable {
        let id: Int
        let song: Song
    }

    let playlist: PlaylistDetail
    let onSave: (PlaylistDetail) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [Entry]
    @State private var saving = false
    @State private var error: String?

    init(playlist: PlaylistDetail, onSave: @escaping (PlaylistDetail) -> Void) {
        self.playlist = playlist
        self.onSave = onSave
        _entries = State(initialValue: (playlist.entry ?? []).enumerated().map { Entry(id: $0.offset, song: $0.element) })
    }

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.secondary) }
                ForEach(entries) { entry in
                    LibraryItemTitle(title: entry.song.title, subtitle: entry.song.artist ?? "")
                }
                .onMove { entries.move(fromOffsets: $0, toOffset: $1) }
                .moveDisabled(saving)
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder Tracks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(saving || entries.map(\.id) == Array(entries.indices))
                }
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private func save() {
        guard !saving, let client = model.client else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                let original = (playlist.entry ?? []).map(\.id)
                let desired = entries.map { $0.song.id }
                guard let current = try await client.playlist(playlist.id) else {
                    error = "This playlist is no longer available."
                    return
                }
                let currentOrder = (current.entry ?? []).map(\.id)
                guard currentOrder == original || currentOrder == desired else {
                    error = "This playlist changed on the server. Close the editor and refresh before reordering."
                    return
                }
                let updated: PlaylistDetail?
                if currentOrder == desired {
                    updated = current
                } else {
                    updated = try await client.reorderPlaylist(playlist.id, songIDs: desired)
                }
                guard let updated, (updated.entry ?? []).map(\.id) == desired else {
                    error = "The server didn’t return the saved track order. Refresh the playlist before trying again."
                    return
                }
                onSave(updated)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Genre

struct GenreView: View {
    let genre: String
    @Environment(AppModel.self) private var model
    @State private var albums: [Album] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MixTile(title: "\(genre) Station", subtitle: "Station", systemImage: "dot.radiowaves.left.and.right", colors: Palette.stable(genre), width: nil, height: 120) {
                    model.router.go(.generated(.genre(genre)))
                }
                .padding(.horizontal)
                AlbumGrid(albums: albums)
            }
            .padding(.vertical)
        }
        .navigationTitle(genre)
        .task {
            guard albums.isEmpty else { return }
            albums = (try? await model.client?.albumList("byGenre", size: 200, genre: genre)) ?? []
        }
    }
}

struct AlbumGrid: View {
    let albums: [Album]
    var onLast: (() -> Void)? = nil

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14, alignment: .top), GridItem(.flexible(), spacing: 14, alignment: .top)], spacing: 18) {
            ForEach(albums) { album in
                GeometryReader { geo in
                    AlbumCard(album: album, width: geo.size.width)
                }
                .aspectRatio(0.78, contentMode: .fit)
                .onAppear { if album.id == albums.last?.id { onLast?() } }
            }
        }
        .padding(.horizontal)
    }
}

struct GeneratedPlaylistView: View {
    let playlist: GeneratedPlaylist
    @Environment(AppModel.self) private var model

    var body: some View {
        GeneratedPlaylistContent(playlist: playlist) { songs in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 16) {
                            Artwork(id: songs.first?.coverArt, size: 400, corner: 12)
                                .frame(width: 96, height: 96)
                            VStack(alignment: .leading, spacing: 6) {
                                Label(playlist.kind, systemImage: playlist.icon)
                                    .font(.headline)
                                Text("\(songs.count) tracks")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        PlayShuffleButtons(
                            play: { model.playFromLibrary(songs) },
                            shuffle: { model.playFromLibrary(songs, shuffled: true) }
                        )
                        SaveMixButton(title: playlist.title, songs: songs)
                    }
                    .padding(.bottom, 12)

                    ForEach(Array(songs.enumerated()), id: \.element.id) { i, song in
                        SongRow(song: song) { model.playFromLibrary(songs, startAt: i) }
                    }
                }
                .padding()
            }
        }
    }
}
