import SwiftUI

// MARK: - Inspector (lyrics / up next)

enum MacInspectorTab: Hashable { case lyrics, queue }

struct MacInspector: View {
    @Binding var tab: MacInspectorTab?
    @Environment(Player.self) private var player

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: Binding(get: { tab ?? .lyrics }, set: { tab = $0 })) {
                Text("Lyrics").tag(MacInspectorTab.lyrics)
                Text("Playing Next").tag(MacInspectorTab.queue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            Divider()
            if tab == .queue {
                MacQueueView()
            } else if let song = player.current {
                MacLyricsView(song: song)
            } else {
                ContentUnavailableView("Not Playing", systemImage: "quote.bubble")
            }
        }
    }
}

struct MacLyricsView: View {
    let song: Song
    @Environment(AppModel.self) private var model
    @Environment(Player.self) private var player
    @State private var lyrics: Lyrics?
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let lyrics, lyrics.synced {
                synced(lyrics)
            } else if let lyrics {
                ScrollView {
                    Text(lyrics.lines.map(\.value).joined(separator: "\n"))
                        .font(.title3.bold())
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
            } else {
                ContentUnavailableView("No Lyrics", systemImage: "quote.bubble", description: Text("Lyrics aren't available for this song."))
            }
        }
        .task(id: song.id) {
            loading = true
            lyrics = song.isRadio ? nil : await model.client?.lyrics(for: song)
            loading = false
        }
    }

    private func synced(_ lyrics: Lyrics) -> some View {
        let ms = Int(player.elapsed * 1000) + lyrics.offset
        let active = lyrics.lines.lastIndex { ($0.start ?? 0) <= ms } ?? -1
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { i, line in
                        Text(line.value.trimmingCharacters(in: .whitespaces).isEmpty ? "♪" : line.value)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(i == active ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { player.seek(to: Double(line.start ?? 0) / 1000) }
                            .id(i)
                            .animation(.easeOut(duration: 0.3), value: active)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 120)
            }
            .onChange(of: active) { _, new in
                withAnimation(.easeInOut(duration: 0.5)) { proxy.scrollTo(max(new, 0), anchor: UnitPoint(x: 0.5, y: 0.35)) }
            }
        }
    }
}

struct MacQueueView: View {
    @Environment(Player.self) private var player

    var body: some View {
        @Bindable var player = player
        List {
            if let current = player.current {
                Section("Now Playing") { row(player.index, current) }
            }
            Section {
                ForEach(Array(player.upNextRange), id: \.self) { i in row(i, player.queue[i]) }
                    .onMove { player.moveUpNext(from: $0, to: $1) }
                    .onDelete { offsets in
                        let base = player.upNextRange.lowerBound
                        offsets.sorted(by: >).forEach { player.remove(at: base + $0) }
                    }
            } header: {
                HStack {
                    Text("Playing Next")
                    Spacer()
                    if !player.upNextRange.isEmpty { Button("Clear") { player.clearUpNext() }.buttonStyle(.link) }
                }
            }
            if player.autoplay && !player.autoplayRange.isEmpty {
                Section("Autoplay — similar music") {
                    ForEach(Array(player.autoplayRange.prefix(25)), id: \.self) { i in row(i, player.queue[i]) }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Toggle("Autoplay similar music when the queue ends", isOn: $player.autoplay)
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(10)
        }
    }

    private func row(_ i: Int, _ song: Song) -> some View {
        HStack(spacing: 10) {
            MacArtwork(id: song.coverArt, size: 100, corner: 3).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title).lineLimit(1)
                Text(song.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if i == player.index { MacPlayingIndicator(animating: player.isPlaying) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { player.jump(to: i) }
    }
}

// MARK: - Settings

struct MacSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(DownloadManager.self) private var downloads
    @AppStorage(Pref.maxBitRate) private var maxBitRate = 0
    @AppStorage(Pref.format) private var format = "raw"
    @AppStorage(Pref.replayGain) private var replayGain = 0
    @AppStorage(Pref.downloadQuality) private var downloadQuality = Pref.defaultDownloadQuality
    @AppStorage(AccentTheme.storageKey) private var accent = AccentTheme.fallback.rawValue
    @AppStorage(AppearanceMode.storageKey) private var appearance = AppearanceMode.system.rawValue
    private let nearby = NearbyPlayback.shared

    var body: some View {
        @Bindable var player = model.player
        TabView {
            Form {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.name).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Colour") {
                    HStack(spacing: 8) {
                        ForEach(AccentTheme.allCases) { theme in
                            Button { accent = theme.rawValue } label: {
                                Circle().fill(theme.color.gradient).frame(width: 20, height: 20)
                                    .overlay { if accent == theme.rawValue { Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white) } }
                            }
                            .buttonStyle(.plain)
                            .help(theme.name)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Appearance", systemImage: "paintpalette") }

            Form {
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
                Picker("Sound Check (ReplayGain)", selection: $replayGain) {
                    Text("Off").tag(0)
                    Text("Track").tag(1)
                    Text("Album").tag(2)
                }
                Toggle("Autoplay Similar Music", isOn: $player.autoplay)
            }
            .formStyle(.grouped)
            .tabItem { Label("Playback", systemImage: "play.circle") }

            Form {
                Toggle("Share playback with iPhone", isOn: Binding(
                    get: { nearby.sharingEnabled },
                    set: { nearby.setSharing($0) }
                ))
                if nearby.sharingEnabled {
                    LabeledContent("Pairing Code") {
                        Text(nearby.displayCode).monospaced().textSelection(.enabled)
                    }
                    Text("Enter this code in SoundBase on your iPhone under Settings → Playback Devices.")
                        .foregroundStyle(.secondary)
                    if nearby.connected { Label("iPhone connected", systemImage: "iphone") }
                    if let status = nearby.status { Text(status).foregroundStyle(.secondary) }
                    Button("Generate New Code") { nearby.regenerateCode() }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Devices", systemImage: "desktopcomputer") }

            Form {
                Picker("Download Quality", selection: $downloadQuality) {
                    Text("Original").tag(0)
                    Text("AAC 256 kbps").tag(256)
                    Text("AAC 192 kbps").tag(192)
                    Text("AAC 128 kbps").tag(128)
                }
                LabeledContent("Downloaded Songs", value: "\(downloads.songs.count)")
                LabeledContent("Space Used", value: ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file))
                Button("Remove All Downloads", role: .destructive) { downloads.removeAll() }
                Button("Clear Artwork Cache") { ImageLoader.shared.clear() }
            }
            .formStyle(.grouped)
            .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }

            Form {
                LabeledContent("Server", value: model.credentials?.url.absoluteString ?? "Not signed in")
                LabeledContent("User", value: model.credentials?.username ?? "")
                if model.client != nil {
                    Button("Sign Out", role: .destructive) { model.signOut() }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
        .frame(width: 520, height: 340)
    }
}

// MARK: - Login

struct MacLoginView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Pref.lastServer) private var server = ""
    @AppStorage(Pref.lastUser) private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.circle.fill").font(.system(size: 72)).foregroundStyle(.tint)
            Text("SoundBase").font(.largeTitle.bold())
            Text("Sign in to your Navidrome or OpenSubsonic server.").foregroundStyle(.secondary)
            Form {
                TextField("Server", text: $server, prompt: Text("music.example.com"))
                TextField("Username", text: $username)
                SecureField("Password", text: $password).onSubmit(signIn)
            }
            .formStyle(.grouped)
            .frame(width: 380)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            Button(action: signIn) {
                if busy { ProgressView().controlSize(.small) } else { Text("Sign In").frame(width: 120) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(busy || server.isEmpty || username.isEmpty || password.isEmpty)
            Text("Your password is never stored. SoundBase keeps only a salted token and talks only to your server.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
