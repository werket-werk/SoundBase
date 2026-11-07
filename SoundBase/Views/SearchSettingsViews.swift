import SwiftUI

// MARK: - Search

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: SearchResult?
    @State private var genres: [Genre] = []
    @State private var searching = false

    var body: some View {
        ScrollView {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                GenreGrid(genres: genres, title: "Browse Categories").padding(.vertical)
            } else if let results {
                resultsView(results)
            } else if searching {
                ProgressView().padding(60)
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Artists, Albums, Songs")
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { results = nil; return }
            searching = true
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let r = try? await model.client?.search(q)
            guard !Task.isCancelled else { return }
            results = r
            searching = false
        }
        .task { if genres.isEmpty { genres = (try? await model.client?.genres()) ?? [] } }
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
                    ShelfHeader(title: "Songs")
                    ForEach(Array(songs.prefix(8).enumerated()), id: \.element.id) { i, song in
                        SongRow(song: song) { model.player.play(Array(songs), startAt: i) }.padding(.horizontal)
                    }
                }
            }
            AlbumShelf(title: "Albums", albums: r.album ?? [])
            ArtistShelf(title: "Artists", artists: Array((r.artist ?? []).dropFirst()))
        }
        .padding(.vertical)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Pref.maxBitRate) private var maxBitRate = 0
    @AppStorage(Pref.format) private var format = "raw"
    @AppStorage(Pref.replayGain) private var replayGain = 0
    @State private var confirmSignOut = false

    var body: some View {
        @Bindable var player = model.player
        NavigationStack {
            Form {
                Section("Server") {
                    LabeledContent("Address", value: model.credentials?.url.host ?? "")
                    LabeledContent("User", value: model.credentials?.username ?? "")
                    Button("Sign Out", role: .destructive) { confirmSignOut = true }
                }
                Section {
                    Picker("Streaming Quality", selection: $maxBitRate) {
                        Text("Original").tag(0)
                        Text("320 kbps").tag(320)
                        Text("256 kbps").tag(256)
                        Text("192 kbps").tag(192)
                        Text("128 kbps").tag(128)
                    }
                    Picker("Transcode To", selection: $format) {
                        Text("Original Format").tag("raw")
                        Text("AAC").tag("aac")
                        Text("Opus").tag("opus")
                        Text("MP3").tag("mp3")
                    }
                } header: { Text("Streaming") } footer: {
                    Text("Downloads are always stored in original quality. AAC transcoding needs Navidrome 0.64 or later.")
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
