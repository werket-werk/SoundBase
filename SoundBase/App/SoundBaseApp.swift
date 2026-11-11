import SwiftUI

@main
struct SoundBaseApp: App {
    @State private var model = AppModel()
    @AppStorage(AccentTheme.storageKey) private var accent = AccentTheme.fallback.rawValue
    @AppStorage(AppearanceMode.storageKey) private var appearance = AppearanceMode.system.rawValue

    init() {
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 1 << 30)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.player)
                .environment(model.router)
                .environment(model.downloads)
                .environment(CastManager.shared)
                .tint(AccentTheme.from(accent).color)
                .preferredColorScheme(AppearanceMode(rawValue: appearance)?.colorScheme)
                .onChange(of: accent) { _, _ in PhoneSession.shared.push() }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.client == nil {
                LoginView()
            } else {
                MainTabView()
            }
        }
        #if DEBUG
        .task { await ScreenshotDirector.run(model) }
        #endif
    }
}

struct MainTabView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                NavigationStack(path: $router.homePath) { HomeView().routes() }
            }
            Tab("New", systemImage: "square.grid.2x2.fill", value: AppTab.browse) {
                NavigationStack(path: $router.browsePath) { BrowseView().routes() }
            }
            Tab("Radio", systemImage: "dot.radiowaves.left.and.right", value: AppTab.radio) {
                NavigationStack(path: $router.radioPath) { RadioView().routes() }
            }
            Tab("Library", systemImage: "square.stack.fill", value: AppTab.library) {
                NavigationStack(path: $router.libraryPath) { LibraryView().routes() }
            }
            Tab(value: AppTab.search, role: .search) {
                NavigationStack(path: $router.searchPath) { SearchView().routes() }
            }
        }
        .miniPlayer(visible: model.player.current != nil)
        .fullScreenCover(isPresented: $router.showNowPlaying) {
            NowPlayingView()
        }
        .sheet(isPresented: $router.showSettings) { SettingsView() }
        .sheet(isPresented: Binding(
            get: { router.playlistPickerSongs != nil && !router.showNowPlaying },
            set: { if !$0 { router.playlistPickerSongs = nil } })) {
            PlaylistPicker()
        }
    }
}

extension View {
    @ViewBuilder
    func miniPlayer(visible: Bool) -> some View {
        if #available(iOS 26.1, *) {
            tabViewBottomAccessory(isEnabled: visible) { MiniPlayerView() }
        } else if #available(iOS 26.0, *) {
            if visible { tabViewBottomAccessory { MiniPlayerView() } }
            else { self }
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) {
                if visible {
                    MiniPlayerView()
                        .padding(.horizontal, 10)
                        .background(.bar, in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 8)
                        .padding(.bottom, 54)
                }
            }
        }
    }

    func routes() -> some View {
        navigationDestination(for: Route.self) { RouteView(route: $0) }
    }
}

struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case .album(let id): AlbumView(id: id)
        case .artist(let id): ArtistView(id: id)
        case .playlist(let id): PlaylistView(id: id)
        case .generated(let playlist): GeneratedPlaylistView(playlist: playlist)
        case .searchResults(let query, let category): SearchCategoryView(query: query, category: category)
        case .radio(let station): LiveRadioView(station: station)
        case .genre(let name): GenreView(genre: name)
        case .albums(let title, let type): AlbumGridView(title: title, type: type)
        case .artists: ArtistsListView()
        case .songs: SongsListView()
        case .playlists: PlaylistsView()
        case .genres: GenresView()
        case .loved: LovedView()
        case .downloads: DownloadsView()
        case .history: ListeningHistoryView()
        }
    }
}
