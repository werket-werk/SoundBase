import SwiftUI

// MARK: - Search

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: SearchResult?
    @State private var genres: [Genre] = []
    @State private var searching = false
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        ScrollView {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                GenreGrid(genres: genres, title: "Browse Categories").padding(.vertical)
            } else if let results {
                resultsView(results)
            } else if failed {
                ContentUnavailableView {
                    Label("Couldn’t Search", systemImage: "exclamationmark.circle")
                } actions: {
                    Button("Retry") { attempt += 1 }
                }
            } else if searching {
                ProgressView().padding(60)
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Artists, Albums, Songs")
        .task(id: SearchRequest(query: query, attempt: attempt)) {
            results = nil
            failed = false
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty, let client = model.client else { searching = false; return }
            searching = true
            do {
                try await Task.sleep(for: .milliseconds(300))
                let response = try await client.search(q)
                try Task.checkCancellation()
                results = response
                searching = false
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
                searching = false
            }
        }
        .task { if genres.isEmpty { genres = (try? await model.client?.genres()) ?? [] } }
        .onAppear {
            if let q = model.router.initialSearch { query = q; model.router.initialSearch = nil }
        }
    }

    @ViewBuilder
    private func resultsView(_ r: SearchResult) -> some View {
        let songs = r.song ?? []
        if (r.artist ?? []).isEmpty && (r.album ?? []).isEmpty && songs.isEmpty {
            EmptyStateView(title: "No Results", systemImage: "magnifyingglass", message: "Try a different search.")
                .padding(.top, 60)
        }
        LazyVStack(alignment: .leading, spacing: 26) {
            if let top = r.artist?.first {
                NavigationLink(value: Route.artist(top.id)) {
                    HStack(spacing: 14) {
                        Artwork(id: top.artworkID, size: 200, circle: true).frame(width: 72)
                        VStack(alignment: .leading) {
                            Text("TOP RESULT").font(.caption.bold()).foregroundStyle(.secondary)
                            Text(top.name).font(.title3.bold()).foregroundStyle(.primary)
                            Text("Artist").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                }
                .buttonStyle(.plain)
            }
            if !songs.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ShelfHeader(title: "Songs", route: resultRoute(.songs))
                    ForEach(songs.prefix(8)) { song in
                        SongRow(song: song) { model.playFromLibrary([song]) }.padding(.horizontal)
                    }
                }
            }
            AlbumShelf(title: "Albums", albums: r.album ?? [], route: resultRoute(.albums))
            ArtistShelf(title: "Artists", artists: r.artist ?? [], route: resultRoute(.artists))
        }
        .padding(.vertical)
    }
    private func resultRoute(_ category: SearchCategory) -> Route {
        .searchResults(query.trimmingCharacters(in: .whitespacesAndNewlines), category)
    }
}

struct SearchCategoryView: View {
    let query: String
    let category: SearchCategory
    @Environment(AppModel.self) private var model
    @State private var page = SearchPage()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                switch category {
                case .songs:
                    ForEach(page.results.song ?? []) { song in
                        SongRow(song: song) { model.playFromLibrary([song]) }
                    }
                case .albums:
                    AlbumGrid(albums: page.results.album ?? [])
                case .artists:
                    ForEach(page.results.artist ?? []) { artist in
                        NavigationLink(value: Route.artist(artist.id)) {
                            Label(artist.name, systemImage: "music.mic")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                        }
                    }
                }
                SearchPageFooter(page: page, load: load).padding(.vertical)
            }
            .padding(.horizontal)
        }
        .navigationTitle(category.rawValue)
        .task { if page.hasMore && page.results.song == nil && page.results.album == nil && page.results.artist == nil { await load() } }
    }

    private func load() async {
        await page.load(query: query, category: category, client: model.client)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Pref.maxBitRate) private var maxBitRate = 0
    @AppStorage(Pref.cellularBitRate) private var cellularBitRate = -1
    @AppStorage(Pref.wifiOnlyDownloads) private var wifiOnlyDownloads = false
    @AppStorage(Pref.format) private var format = "raw"
    @AppStorage(Pref.replayGain) private var replayGain = 0
    @AppStorage(AccentTheme.storageKey) private var accent = AccentTheme.fallback.rawValue
    @AppStorage(AppearanceMode.storageKey) private var appearance = AppearanceMode.system.rawValue
    @AppStorage(NowPlayingStyle.storageKey) private var nowPlayingStyle = NowPlayingStyle.blurredArtwork.rawValue
    @AppStorage(AppIconSwitcher.matchKey) private var iconMatchesAccent = true
    @State private var confirmSignOut = false
    @State private var macCode = ""
    private let nearby = NearbyPlayback.shared

    var body: some View {
        @Bindable var player = model.player
        NavigationStack {
            Form {
                Section {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppearanceMode.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                    AccentPicker(selection: $accent)
                    Toggle("App Icon Matches Colour", isOn: $iconMatchesAccent)
                    Picker("Now Playing Background", selection: $nowPlayingStyle) {
                        ForEach(NowPlayingStyle.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                } header: { Text("Appearance") } footer: {
                    Text("The home screen icon changes to match the colour you pick. iOS shows a short confirmation when it changes. The Apple Watch app uses the same colour, but watchOS doesn't allow changing its icon.")
                }
                Section("Home") {
                    NavigationLink("Customize Home") { HomeLayoutSettings() }
                }
                Section("Server") {
                    LabeledContent("Address", value: model.credentials?.url.host ?? "")
                    LabeledContent("User", value: model.credentials?.username ?? "")
                    Button("Sign Out", role: .destructive) { confirmSignOut = true }
                }
                Section("Playback Devices") {
                    if nearby.connected {
                        Label("Mac connected", systemImage: "desktopcomputer")
                    } else {
                        TextField("Mac pairing code", text: $macCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        Button("Pair Mac") {
                            nearby.pair(code: macCode)
                            macCode = ""
                        }
                        .disabled(macCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if let status = nearby.status { Text(status).foregroundStyle(.secondary) }
                    }
                    if !nearby.pairingCode.isEmpty {
                        Button("Forget Mac", role: .destructive) { nearby.forgetMac() }
                    }
                }
                Section {
                    Picker("Wi-Fi Quality", selection: $maxBitRate) {
                        Text("Original").tag(0)
                        Text("320 kbps").tag(320)
                        Text("256 kbps").tag(256)
                        Text("192 kbps").tag(192)
                        Text("128 kbps").tag(128)
                    }
                    Picker("Cellular Quality", selection: $cellularBitRate) {
                        Text("Same as Wi-Fi").tag(-1)
                        Text("Original").tag(0)
                        ForEach([320, 256, 192, 128, 96, 64], id: \.self) { rate in
                            Text("\(rate) kbps").tag(rate)
                        }
                    }
                    Picker("Transcode To", selection: $format) {
                        Text("Original Format").tag("raw")
                        Text("AAC").tag("aac")
                        Text("Opus").tag("opus")
                        Text("MP3").tag("mp3")
                    }
                } header: { Text("Streaming") } footer: {
                    Text("Quality changes apply to new streams. A cellular bitrate limit uses MP3 when Original Format is selected. AAC transcoding needs Navidrome 0.64 or later.")
                }
                Section {
                    DownloadQualitySettings()
                    Toggle("Download Over Wi-Fi Only", isOn: $wifiOnlyDownloads)
                    if let issue = downloads.downloadIssue { Text(issue).foregroundStyle(.secondary) }
                } header: { Text("Downloads") } footer: {
                    Text("Applies to new downloads. MP3 and Opus require server support. For Opus, use a server profile that sends Opus in MP4. Wi-Fi only prevents new downloads over cellular. Apple Watch uses its existing AAC 128 kbps download policy.")
                }
                Section {
                    Picker("Sound Check (ReplayGain)", selection: $replayGain) {
                        Text("Off").tag(0)
                        Text("Track").tag(1)
                        Text("Album").tag(2)
                    }
                    Toggle("Autoplay Similar Music", isOn: $player.autoplay)
                } header: { Text("Playback") }
                Section("Storage") {
                    LabeledContent("Downloaded Songs", value: "\(downloads.songs.count)")
                    LabeledContent("Space Used", value: ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file))
                    Button("Clear Artwork Cache") { ImageLoader.shared.clear() }
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .onChange(of: accent) { _, new in AppIconSwitcher.apply(AccentTheme.from(new)) }
            .onChange(of: iconMatchesAccent) { _, _ in AppIconSwitcher.apply(AccentTheme.from(accent)) }
            .confirmationDialog("Sign out of this server?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) {
                    dismiss()
                    model.signOut()
                }
            }
        }
    }
}

// MARK: - Login

struct LoginView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.lastServer) private var server = ""
    @AppStorage(Pref.lastUser) private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focus: Field?

    enum Field { case server, user, password }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 84))
                    .foregroundStyle(.tint)
                    .padding(.top, 60)
                VStack(spacing: 6) {
                    Text("SoundBase").font(.largeTitle.bold())
                    Text("Sign in to your Navidrome or OpenSubsonic server.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                VStack(spacing: 0) {
                    field("Server", text: $server, field: .server)
                        .keyboardType(.URL)
                    Divider().padding(.leading)
                    field("Username", text: $username, field: .user)
                    Divider().padding(.leading)
                    SecureField("Password", text: $password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit(signIn)
                        .padding()
                }
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))

                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }

                Button(action: signIn) {
                    Group {
                        if busy { ProgressView().tint(.white) } else { Text("Sign In").font(.headline) }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 14))
                .disabled(busy || server.isEmpty || username.isEmpty || password.isEmpty)

                Text("Your password is never stored. SoundBase keeps only a salted token, and talks only to your server.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func field(_ title: String, text: Binding<String>, field: Field) -> some View {
        TextField(title, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focus, equals: field)
            .submitLabel(.next)
            .onSubmit { focus = field == .server ? .user : .password }
            .padding()
    }

    private func signIn() {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            do {
                try await model.signIn(server: server, username: username, password: password)
                password = ""
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

// MARK: - Accent picker

struct AccentPicker: View {
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Colour")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 12) {
                ForEach(AccentTheme.allCases) { theme in
                    Button {
                        withAnimation(.snappy) { selection = theme.rawValue }
                    } label: {
                        Circle()
                            .fill(theme.color.gradient)
                            .frame(width: 36, height: 36)
                            .overlay {
                                if selection == theme.rawValue {
                                    Image(systemName: "checkmark").font(.footnote.bold()).foregroundStyle(.white)
                                }
                            }
                            .overlay {
                                Circle().stroke(theme.color, lineWidth: selection == theme.rawValue ? 2 : 0).padding(-4)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(theme.name)
                    .accessibilityAddTraits(selection == theme.rawValue ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 6)
    }
}
