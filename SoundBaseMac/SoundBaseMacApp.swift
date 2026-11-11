import SwiftUI

@main
struct SoundBaseMacApp: App {
    @State private var model = AppModel()
    @AppStorage(AccentTheme.storageKey) private var accent = AccentTheme.fallback.rawValue
    @AppStorage(AppearanceMode.storageKey) private var appearance = AppearanceMode.system.rawValue

    init() {
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 1 << 30)
    }

    var body: some Scene {
        WindowGroup("SoundBase", id: "main") {
            MacRootView()
                .environment(model)
                .environment(model.player)
                .environment(model.router)
                .environment(model.downloads)
                .tint(AccentTheme.from(accent).color)
                .preferredColorScheme(AppearanceMode(rawValue: appearance)?.colorScheme)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
        .commands { PlaybackCommands(player: model.player) }

        Settings {
            MacSettingsView()
                .environment(model)
                .environment(model.player)
                .environment(model.downloads)
                .tint(AccentTheme.from(accent).color)
                .preferredColorScheme(AppearanceMode(rawValue: appearance)?.colorScheme)
        }

        MenuBarExtra("SoundBase", systemImage: "waveform") {
            MenuBarPlayer()
                .environment(model)
                .environment(model.player)
                .tint(AccentTheme.from(accent).color)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menus

struct PlaybackCommands: Commands {
    let player: Player

    var body: some Commands {
        CommandMenu("Controls") {
            Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }
                .keyboardShortcut(.space, modifiers: [])
            Button("Next") { player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous") { player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Divider()
            Button(player.shuffle ? "Turn Off Shuffle" : "Shuffle") { player.toggleShuffle() }
                .keyboardShortcut("s", modifiers: .command)
            Button(player.repeatMode.title) { player.cycleRepeat() }
                .keyboardShortcut("r", modifiers: .command)
        }
    }
}

// MARK: - Root

enum MacSection: Hashable {
    case home, browse, radio, search
    case artists, albums, songs, genres, loved, downloads
    case playlists, playlist(String)
}

struct MacRootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.client == nil {
                MacLoginView()
            } else {
                MacMainView()
            }
        }
        #if DEBUG
        .task { await MacScreenshotDirector.run(model) }
        #endif
    }
}

struct MacMainView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var section: MacSection? = .home
    @State private var search = ""
    @State private var inspector: MacInspectorTab? = nil

    var body: some View {
        @Bindable var router = router
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            NavigationStack(path: $router.homePath) {
                sectionRoot
                    .macRoutes()
            }
        }
        .libraryEditor(model: model)
        .searchable(text: $search, placement: .sidebar, prompt: "Search")
        .onChange(of: search) { _, new in
            if section == .search { router.homePath = [] }
            if !new.isEmpty { section = .search }
        }
        .onChange(of: section) { _, _ in router.homePath = [] }
        .accessibilityHidden(router.showNowPlaying)
        .overlay {
            if router.showNowPlaying {
                MacNowPlayingView()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MacPlayerBar(inspector: $inspector)
        }
        .inspector(isPresented: Binding(get: { inspector != nil }, set: { if !$0 { inspector = nil } })) {
            MacInspector(tab: $inspector)
                .inspectorColumnWidth(min: 280, ideal: 340, max: 480)
        }
        .sheet(isPresented: Binding(
            get: { router.playlistPickerSongs != nil },
            set: { if !$0 { router.playlistPickerSongs = nil } })) {
            MacPlaylistPicker()
        }
        .task { router.tab = .home }
        .onChange(of: router.initialSection) { _, new in
            guard let new else { return }
            if new.hasPrefix("playlist:") { section = .playlist(String(new.dropFirst(9))) }
            else if new == "albums" { section = .albums }
            else if new == "radio" { section = .radio }
            else if new.hasPrefix("search:") { search = String(new.dropFirst(7)); section = .search }
            router.initialSection = nil
        }
        .onChange(of: router.initialNowPlayingPanel) { _, new in
            guard let new else { return }
            inspector = new == "queue" ? .queue : .lyrics
            router.initialNowPlayingPanel = nil
        }
    }

    private var sidebar: some View {
        List(selection: $section) {
            Section {
                Label("Home", systemImage: "house").tag(MacSection.home)
                Label("New", systemImage: "square.grid.2x2").tag(MacSection.browse)
                Label("Radio", systemImage: "dot.radiowaves.left.and.right").tag(MacSection.radio)
            }
            Section("Library") {
                Label("Artists", systemImage: "music.mic").tag(MacSection.artists)
                Label("Albums", systemImage: "square.stack").tag(MacSection.albums)
                Label("Songs", systemImage: "music.note").tag(MacSection.songs)
                Label("Genres", systemImage: "guitars").tag(MacSection.genres)
                Label("Favourites", systemImage: "star").tag(MacSection.loved)
                Label("Downloaded", systemImage: "arrow.down.circle").tag(MacSection.downloads)
                ForEach(model.pinnedPlaylistIDs, id: \.self) { id in
                    if let name = model.playlists.first(where: { $0.id == id })?.name
                        ?? model.downloads.playlistIndex.playlists[id]?.name {
                        Label(name, systemImage: "pin.fill").tag(MacSection.playlist(id))
                        .contextMenu {
                            Button("Unpin") { model.togglePlaylistPin(id) }
                        }
                    }
                }
            }
            Section("Playlists") {
                Label("All Playlists", systemImage: "music.note.list").tag(MacSection.playlists)
                ForEach(model.playlists.filter { !model.pinnedPlaylistIDs.contains($0.id) }) { playlist in
                    Label(playlist.name, systemImage: "music.note.list").tag(MacSection.playlist(playlist.id))
                        .contextMenu {
                            Button("Play") { Task { await playPlaylist(playlist.id, shuffled: false) } }
                            Button("Shuffle") { Task { await playPlaylist(playlist.id, shuffled: true) } }
                        }
                }
                Button { newPlaylist() } label: { Label("New Playlist…", systemImage: "plus") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var sectionRoot: some View {
        switch section ?? .home {
        case .home: MacHomeView()
        case .browse: MacBrowseView()
        case .radio: MacRadioView()
        case .search: MacSearchView(query: search)
        case .artists: MacArtistsView()
        case .albums: MacAlbumGridView(title: "Albums", type: "alphabeticalByName")
        case .songs: MacSongsView()
        case .genres: MacGenresView()
        case .loved: MacLovedView()
        case .downloads: MacDownloadsView()
        case .playlists: MacPlaylistsView()
        case .playlist(let id):
            MacPlaylistView(id: id) { section = .playlists }
                .id(id)
        }
    }

    private func playPlaylist(_ id: String, shuffled: Bool) async {
        guard let songs = try? await model.client?.playlist(id)?.entry else { return }
        model.playFromLibrary(songs, shuffled: shuffled)
    }

    private func newPlaylist() {
        let alert = NSAlert()
        alert.messageText = "New Playlist"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Playlist Name"
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        let name = field.stringValue
        Task {
            try? await model.client?.createPlaylist(name: name, songIds: [])
            await model.refreshPlaylists()
        }
    }
}

struct MacNowPlayingView: View {
    @Environment(Player.self) private var player
    @Environment(Router.self) private var router

    var body: some View {
        GeometryReader { proxy in
            let artworkSize = max(80, min(420, proxy.size.width - 80, proxy.size.height - 170))
            VStack(spacing: 14) {
                HStack {
                    Button { router.showNowPlaying = false } label: {
                        Label("Back to Library", systemImage: "chevron.down")
                    }
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                    Text("Now Playing").font(.headline)
                }
                Spacer(minLength: 0)
                MacArtwork(id: player.current?.coverArt, size: 1000, corner: 14)
                    .frame(width: artworkSize, height: artworkSize)
                    .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
                VStack(spacing: 4) {
                    Text(player.current?.title ?? "Not Playing").font(.title.bold())
                    Text(player.current?.artist ?? "").font(.title3).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                PlaybackIssueControls()
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(\.colorScheme, .dark)
        .background { NowPlayingBackground(image: player.artwork) }
    }
}

// MARK: - Player bar

struct MacPlayerBar: View {
    @Binding var inspector: MacInspectorTab?
    @Environment(AppModel.self) private var model
    @Environment(Player.self) private var player
    @Environment(Router.self) private var router
    @State private var drag: Double?

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 14) {
                Button { player.toggleShuffle() } label: { Image(systemName: "shuffle") }
                    .foregroundStyle(player.shuffle ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title3) }
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title)
                        .frame(width: 30)
                        .contentTransition(.symbolEffect(.replace))
                }
                Button { player.next() } label: { Image(systemName: "forward.fill").font(.title3) }
                RepeatModeMenu().menuStyle(.borderlessButton).fixedSize()
            }
            .buttonStyle(.plain)
            .disabled(player.current == nil)

            // "LCD": artwork, title, scrubber
            HStack(spacing: 10) {
                Button { router.showNowPlaying.toggle() } label: {
                    MacArtwork(id: player.current?.coverArt, size: 120, corner: 4)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(player.current == nil)
                .help(router.showNowPlaying ? "Minimise Now Playing" : "Open Now Playing")
                VStack(spacing: 3) {
                    if let song = player.current {
                        Text(song.title).font(.callout.weight(.medium)).lineLimit(1)
                        Button {
                            if let id = song.artistId { router.go(.artist(id)) }
                        } label: {
                            Text([song.artist, song.album].compactMap { $0 }.joined(separator: " — "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        scrubber
                    } else {
                        Image(systemName: "waveform").font(.title2).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                if let song = player.current, !song.isRadio {
                    Button { model.toggleLove(song.id, kind: .song) } label: {
                        Image(systemName: model.isLoved(song.id) ? "star.fill" : "star")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.isLoved(song.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: 560)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 14) {
                inspectorButton(.lyrics, icon: "quote.bubble")
                inspectorButton(.queue, icon: "list.bullet")
                AirPlayRouteButton().frame(width: 22, height: 22)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var scrubber: some View {
        let total = max(player.duration, 1)
        let value = drag ?? player.elapsed
        return HStack(spacing: 6) {
            Text(formatTime(value)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            Slider(value: Binding(get: { value }, set: { drag = $0 }), in: 0...total) { editing in
                if !editing, let drag { player.seek(to: drag); self.drag = nil }
            }
            .controlSize(.mini)
            .disabled(player.current?.isRadio == true)
            Text("-" + formatTime(max(0, total - value))).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func inspectorButton(_ tab: MacInspectorTab, icon: String) -> some View {
        Button { inspector = inspector == tab ? nil : tab } label: { Image(systemName: icon) }
            .buttonStyle(.plain)
            .foregroundStyle(inspector == tab ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .help(tab == .lyrics ? "Lyrics" : "Playing Next")
    }
}

// MARK: - Menu bar mini player

struct MenuBarPlayer: View {
    @Environment(Player.self) private var player
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                MacArtwork(id: player.current?.coverArt, size: 160, corner: 6).frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.current?.title ?? "Not Playing").font(.headline).lineLimit(1)
                    Text(player.current?.artist ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            ProgressView(value: min(player.elapsed, max(player.duration, 1)), total: max(player.duration, 1))
            HStack(spacing: 24) {
                Button { player.previous() } label: { Image(systemName: "backward.fill") }
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                }
                Button { player.next() } label: { Image(systemName: "forward.fill") }
            }
            .buttonStyle(.plain)
            .disabled(player.current == nil)
            Button("Open SoundBase") {
                openWindow(id: "main")
                NSApp.activate()
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(14)
        .frame(width: 280)
    }
}
