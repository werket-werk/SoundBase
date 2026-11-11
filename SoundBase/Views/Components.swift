import SwiftUI

// MARK: - Artwork

struct Artwork: View {
    let id: String?
    var size: Int = 600
    var corner: CGFloat = 8
    var circle = false

    @Environment(AppModel.self) private var model
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        LinearGradient(colors: [Color(.systemGray4), Color(.systemGray5)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: circle ? "music.mic" : "music.note")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .clipShape(circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: corner, style: .continuous)))
            .overlay {
                (circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: corner, style: .continuous)))
                    .stroke(.primary.opacity(0.08), lineWidth: 0.5)
            }
            .task(id: id) {
                guard let id, let url = model.client?.coverURL(id, size: size) else { image = nil; return }
                if let hit = ImageLoader.shared.cached(url) { image = hit; return }
                image = nil
                image = await ImageLoader.shared.image(url)
            }
    }
}

// MARK: - Shelves

struct ShelfHeader: View {
    let title: String
    var subtitle: String? = nil
    var route: Route? = nil
    @Environment(Router.self) private var router

    var body: some View {
        Button {
            if let route { router.go(route) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                if let subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text(title).font(.title2.bold())
                    if case .searchResults? = route {
                        Spacer()
                        Text("See All").font(.subheadline).foregroundStyle(.tint)
                    } else if route != nil {
                        Image(systemName: "chevron.right").font(.title3.bold()).foregroundStyle(.secondary)
                    }
                }
            }
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(route != nil)
        .padding(.horizontal)
    }
}

struct AlbumCard: View {
    let album: Album
    var width: CGFloat = 160
    var listRow = false
    @Environment(Router.self) private var router
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { router.go(.album(album.id)) } label: {
            if listRow {
                HStack(spacing: 12) {
                    Artwork(id: album.coverArt, size: 120, corner: 6).frame(width: 48, height: 48)
                    LibraryItemTitle(title: album.name, subtitle: album.artist)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Artwork(id: album.coverArt, size: 400)
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                    Text(album.name).font(.subheadline).lineLimit(1).foregroundStyle(.primary)
                    Text(album.artist ?? "").font(.subheadline).lineLimit(1).foregroundStyle(.secondary)
                }
                .frame(width: width)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { Task { await model.playAlbum(album.id) } } label: { Label("Play", systemImage: "play.fill") }
            Button { Task { await model.playAlbum(album.id, shuffled: true) } } label: { Label("Shuffle", systemImage: "shuffle") }
            Button { Task { if let s = try? await model.client?.album(album.id)?.song { model.player.playNext(s) } } } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button { Task { if let s = try? await model.client?.album(album.id)?.song { model.player.addToQueue(s) } } } label: {
                Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
            Button { model.toggleLove(album.id, kind: .album) } label: {
                Label(model.isLoved(album.id) ? "Unfavourite" : "Favourite", systemImage: model.isLoved(album.id) ? "star.slash" : "star")
            }
            if let artistId = album.artistId {
                Button { router.go(.artist(artistId)) } label: { Label("Go to Artist", systemImage: "music.mic") }
            }
        } preview: {
            Artwork(id: album.coverArt, size: 600).frame(width: 300)
        }
    }
}

struct AlbumShelf: View {
    let title: String
    var subtitle: String? = nil
    let albums: [Album]
    var route: Route? = nil

    var body: some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ShelfHeader(title: title, subtitle: subtitle, route: route)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(albums) { AlbumCard(album: $0) }
                    }
                    .padding(.horizontal)
                }
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }
}

struct ArtistCard: View {
    let artist: Artist
    var width: CGFloat = 130
    @Environment(Router.self) private var router

    var body: some View {
        Button { router.go(.artist(artist.id)) } label: {
            VStack(spacing: 6) {
                Artwork(id: artist.artworkID, size: 400, circle: true)
                Text(artist.name).font(.subheadline).lineLimit(1).foregroundStyle(.primary)
            }
            .frame(width: width)
        }
        .buttonStyle(.plain)
    }
}

struct ArtistShelf: View {
    let title: String
    var subtitle: String? = nil
    let artists: [Artist]
    var route: Route? = nil

    var body: some View {
        if !artists.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ShelfHeader(title: title, subtitle: subtitle, route: route)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(artists) { ArtistCard(artist: $0) }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }
}

// MARK: - Songs

struct PlayingIndicator: View {
    var animating: Bool
    var body: some View {
        Image(systemName: "waveform")
            .symbolEffect(.variableColor.iterative, isActive: animating)
            .foregroundStyle(.tint)
    }
}

struct SongRow: View {
    let song: Song
    var number: Int? = nil
    var showArtwork = true
    var subtitle: String? = nil
    let action: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(Player.self) private var player
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        let isCurrent = player.current?.id == song.id
        HStack(spacing: 12) {
            Button(action: action) {
                HStack(spacing: 12) {
                    if let number {
                        Group {
                            if isCurrent { PlayingIndicator(animating: player.isPlaying) }
                            else { Text("\(number)").foregroundStyle(.secondary) }
                        }
                        .font(.subheadline)
                        .frame(width: 26)
                    } else if showArtwork {
                        Artwork(id: song.coverArt, size: 120, corner: 5)
                            .frame(width: 46, height: 46)
                            .overlay {
                                if isCurrent {
                                    RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.45))
                                    PlayingIndicator(animating: player.isPlaying).foregroundStyle(.white)
                                }
                            }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title)
                            .lineLimit(1)
                            .foregroundStyle(isCurrent && number != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        if let sub = subtitle ?? song.artist, number == nil || subtitle != nil {
                            Text(sub).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if model.isLoved(song.id) {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.tint)
                    }
                    if downloads.isDownloaded(song.id) {
                        Image(systemName: "arrow.down.circle.fill").font(.caption).foregroundStyle(.secondary)
                    } else if downloads.inProgress.contains(song.id) {
                        ProgressView().controlSize(.mini)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            QueueTrackButton(song: song)
            Menu { SongMenu(song: song) } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline)
                    .frame(width: 30, height: 36)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(.primary)
        }
        .padding(.vertical, 4)
        .contextMenu { SongMenu(song: song) }
    }
}

struct SongMenu: View {
    let song: Song
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        let downloads = model.downloads
        let player = model.player
        Button { player.playNext([song]) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { player.addToQueue([song]) } label: { Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") }
        Divider()
        Button { router.playlistPickerSongs = [song] } label: { Label("Add to Playlist…", systemImage: "text.badge.plus") }
        Button { model.toggleLove(song.id, kind: .song) } label: {
            Label(model.isLoved(song.id) ? "Unfavourite" : "Favourite", systemImage: model.isLoved(song.id) ? "star.slash" : "star")
        }
        if downloads.canRemoveTrack(song.id) {
            let saved = downloads.isDownloaded(song.id)
            if !saved && !downloads.inProgress.contains(song.id) {
                Button { downloads.download([song]) } label: { Label("Retry Download", systemImage: "arrow.clockwise") }
            }
            Button(role: .destructive) { downloads.remove(song.id) } label: {
                Label(saved ? "Remove Track Download" : "Cancel Track Download", systemImage: "trash")
            }
        } else if !song.isRadio {
            Button { downloads.download([song]) } label: {
                Label(downloads.isDownloaded(song.id) ? "Keep Track Downloaded" : "Download", systemImage: "arrow.down.circle")
            }
        }
        Divider()
        Button { router.go(.generated(.song(song))) } label: { Label("Create Station", systemImage: "dot.radiowaves.left.and.right") }
        if let albumId = song.albumId {
            Button { router.go(.album(albumId)) } label: { Label("Go to Album", systemImage: "square.stack") }
        }
        if let artistId = song.artistId {
            Button { router.go(.artist(artistId)) } label: { Label("Go to Artist", systemImage: "music.mic") }
        }
    }
}

struct PlayShuffleButtons: View {
    let play: () -> Void
    let shuffle: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: play) {
                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            Button(action: shuffle) {
                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
            }
        }
        .font(.headline)
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 12))
        .controlSize(.large)

    }
}

/// A gradient tile used for mixes, stations and genres.
struct MixTile: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String = "music.note"
    var colors: [Color]
    var width: CGFloat? = 260
    var height: CGFloat = 170
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: systemImage)
                    .font(.system(size: 70, weight: .bold))
                    .foregroundStyle(.white.opacity(0.18))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(14)
                VStack(alignment: .leading, spacing: 2) {
                    if let subtitle { Text(subtitle.uppercased()).font(.caption2.bold()).opacity(0.8) }
                    Text(title).font(.title3.bold()).multilineTextAlignment(.leading)
                }
                .foregroundStyle(.white)
                .padding(14)
            }
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

enum Palette {
    static let sets: [[Color]] = [
        [Color(red: 0.98, green: 0.18, blue: 0.28), Color(red: 0.55, green: 0.05, blue: 0.35)],
        [Color(red: 0.36, green: 0.30, blue: 0.95), Color(red: 0.10, green: 0.55, blue: 0.95)],
        [Color(red: 1.00, green: 0.55, blue: 0.10), Color(red: 0.90, green: 0.20, blue: 0.30)],
        [Color(red: 0.10, green: 0.70, blue: 0.55), Color(red: 0.05, green: 0.35, blue: 0.55)],
        [Color(red: 0.75, green: 0.25, blue: 0.85), Color(red: 0.35, green: 0.10, blue: 0.60)],
        [Color(red: 0.95, green: 0.75, blue: 0.15), Color(red: 0.85, green: 0.40, blue: 0.10)],
    ]
    static func colors(for key: String) -> [Color] {
        sets[abs(key.hashValue) % sets.count]
    }
    static func stable(_ key: String) -> [Color] {
        sets[key.unicodeScalars.reduce(0) { $0 + Int($1.value) } % sets.count]
    }
}

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    var message: String? = nil
    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: message.map { Text($0) })
    }
}

/// Simple async loader state.
enum Loadable<T> {
    case loading, loaded(T), failed(String)
}
