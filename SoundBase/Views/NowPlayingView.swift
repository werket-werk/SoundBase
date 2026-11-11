import SwiftUI
import AVKit
import MediaPlayer

// MARK: - Mini player

struct MiniPlayerView: View {
    @Environment(Player.self) private var player
    @Environment(Router.self) private var router

    var body: some View {
        let macTitle = PhoneSession.shared.macPlaybackTitle
        HStack(spacing: 12) {
            if macTitle != nil {
                Image(systemName: "desktopcomputer").frame(width: 34, height: 34)
            } else {
                Artwork(id: player.current?.coverArt, size: 120, corner: 6)
                    .frame(width: 34, height: 34)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(macTitle ?? player.current?.title ?? "Not Playing")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let artist = macTitle == nil ? player.current?.artist : "Mac" {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if macTitle == nil {
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                        .contentTransition(.symbolEffect(.replace))
                }
                .disabled(player.current == nil)
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.body).frame(width: 32, height: 36)
                }
                .disabled(player.current == nil)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { router.showNowPlaying = true }
    }
}

// MARK: - Full player

struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    @Environment(Player.self) private var player
    @Environment(Router.self) private var router
    @Environment(CastManager.self) private var cast
    @Environment(\.dismiss) private var dismiss
    @State private var panel: Panel = .none
    @State private var showDevices = false

    enum Panel { case none, lyrics, queue }

    var body: some View {
        ZStack {
            NowPlayingBackground(image: player.artwork)
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.headline)
                            .frame(width: 44, height: 44)
                            .background(.white.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Minimise Now Playing")
                    Spacer()
                    Text("Now Playing").font(.headline)
                    Spacer()
                    devicesButton
                }
                .padding(.top, 4)
                if PhoneSession.shared.macPlaybackTitle == nil, let song = player.current {
                    if panel == .none {
                        Spacer(minLength: 12)
                        Artwork(id: song.coverArt, size: 1000, corner: 12)
                            .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
                            .scaleEffect(player.isPlaying ? 1 : 0.82)
                            .animation(.spring(response: 0.45, dampingFraction: 0.7), value: player.isPlaying)
                            .padding(.horizontal, 4)
                        Spacer(minLength: 20)
                        trackHeader(song)
                    } else {
                        compactHeader(song)
                        Group {
                            if panel == .lyrics { LyricsPanel(song: song) } else { QueuePanel() }
                        }
                        .frame(maxHeight: .infinity)
                    }
                    PlaybackIssueControls()
                    ScrubberView().padding(.top, 14)
                    TransportControls().padding(.vertical, 18)
                    VolumeRow()
                    if cast.isCasting {
                        Label("Casting to \(cast.deviceName ?? "TV")", systemImage: "tv.and.mediabox")
                            .font(.footnote.weight(.semibold))
                            .opacity(0.8)
                            .padding(.top, 10)
                    }
                    bottomBar.padding(.top, 18).padding(.bottom, 8)
                } else {
                    Spacer()
                    if let title = PhoneSession.shared.macPlaybackTitle {
                        Text(title).font(.title2.bold())
                        Label("On Mac", systemImage: "desktopcomputer").foregroundStyle(.secondary)
                    } else {
                        Text("Not Playing").font(.title2.bold())
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 28)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onAppear {
            if let p = router.initialNowPlayingPanel {
                panel = p == "queue" ? .queue : .lyrics
                router.initialNowPlayingPanel = nil
            }
        }
        .sheet(isPresented: $showDevices) { PlaybackDevicesView() }
        .sheet(isPresented: Binding(
            get: { router.playlistPickerSongs != nil },
            set: { if !$0 { router.playlistPickerSongs = nil } })) {
            PlaylistPicker()
        }
    }

    private func trackHeader(_ song: Song) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.title3.bold()).lineLimit(1)
                Button {
                    if let id = song.artistId { router.go(.artist(id)) }
                } label: {
                    Text(song.artist ?? "").font(.title3).opacity(0.7).lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            loveButton(song)
            Menu { SongMenu(song: song) } label: {
                Image(systemName: "ellipsis")
                    .font(.headline)
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.15), in: Circle())
            }
        }
    }

    private func compactHeader(_ song: Song) -> some View {
        HStack(spacing: 12) {
            Artwork(id: song.coverArt, size: 200, corner: 6)
                .frame(width: 64, height: 64)
                .shadow(radius: 6)
                .onTapGesture { withAnimation(.spring) { panel = .none } }
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.headline).lineLimit(1)
                Text(song.artist ?? "").font(.subheadline).opacity(0.7).lineLimit(1)
            }
            Spacer()
            loveButton(song)
            Menu { SongMenu(song: song) } label: {
                Image(systemName: "ellipsis").frame(width: 32, height: 32).background(.white.opacity(0.15), in: Circle())
            }
        }
        .padding(.vertical, 12)
    }

    private func loveButton(_ song: Song) -> some View {
        Button { model.toggleLove(song.id, kind: .song) } label: {
            Image(systemName: model.isLoved(song.id) ? "star.fill" : "star")
                .font(.headline)
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.15), in: Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .disabled(song.isRadio)
    }

    private var bottomBar: some View {
        HStack {
            Spacer()
            RepeatModeMenu().tint(.white)
            Spacer()
            panelButton(.lyrics, icon: "quote.bubble")
            Spacer()
            panelButton(.queue, icon: "list.bullet")
            Spacer()
        }
    }

    private var devicesButton: some View {
        Button { showDevices = true } label: {
            Image(systemName: "speaker.wave.2")
                .font(.headline)
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Playback Devices")
    }

    private func panelButton(_ target: Panel, icon: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { panel = panel == target ? .none : target }
        } label: {
            Image(systemName: panel == target && target == .lyrics ? icon + ".fill" : icon)
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(panel == target ? .white.opacity(0.2) : .clear, in: Circle())
        }
        .opacity(panel == target ? 1 : 0.7)
    }
}

private struct PlaybackDevicesView: View {
    @Environment(CastManager.self) private var cast
    @Environment(\.dismiss) private var dismiss
    private let session = PhoneSession.shared
    private let nearby = NearbyPlayback.shared

    var body: some View {
        NavigationStack {
            List {
                Section("Current Device") {
                    if cast.isCasting {
                        Label(cast.deviceName ?? "Cast Device", systemImage: "tv.and.mediabox")
                    } else if session.macPlaybackTitle != nil {
                        Label("Mac", systemImage: "desktopcomputer")
                    } else {
                        Label("This iPhone", systemImage: "iphone")
                    }
                }
                Section("Move Playback") {
                    if session.macAvailable {
                        if session.macPlaybackTitle != nil {
                            Button("Move to This iPhone", systemImage: "iphone") {
                                Task { await session.movePlayback(to: .phone) }
                            }
                        } else {
                            MoveToMacButton()
                        }
                    } else if nearby.connected {
                        Text("Sign in to the same server account on your Mac.")
                            .foregroundStyle(.secondary)
                    } else {
                        MacPairingControls()
                    }
                    if session.switchingDevices { ProgressView("Moving playback…") }
                    if let issue = session.deviceIssue { Text(issue).foregroundStyle(.secondary) }
                }
                .disabled(session.switchingDevices)

                Section("Audio Outputs") {
                    HStack {
                        Label("AirPlay", systemImage: "airplay.audio")
                        Spacer()
                        AirPlayButton().frame(width: 44, height: 36)
                            .accessibilityLabel("Choose AirPlay Output")
                    }
                    HStack {
                        Label("Cast", systemImage: "tv")
                        Spacer()
                        CastButton().frame(width: 44, height: 36)
                            .accessibilityLabel("Choose Cast Device")
                    }
                }
            }
            .navigationTitle("Devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

private struct MoveToMacButton: View {
    @Environment(Player.self) private var player

    var body: some View {
        Button("Move to Mac", systemImage: "desktopcomputer") {
            Task { await PhoneSession.shared.movePlayback(to: .mac) }
        }
        .disabled(player.current == nil || player.current?.isRadio == true || player.isCasting)
    }
}

// MARK: - Scrubber

struct ScrubberView: View {
    @Environment(Player.self) private var player
    @State private var drag: Double?

    var body: some View {
        let live = player.current?.isRadio == true
        let total = max(player.duration, 1)
        let value = drag ?? player.elapsed
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white.opacity(drag == nil ? 0.75 : 1))
                        .frame(width: live ? 0 : geo.size.width * CGFloat(min(value / total, 1)))
                }
                .frame(height: drag == nil ? 7 : 12)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard !live else { return }
                        drag = min(max(0, g.location.x / geo.size.width), 1) * total
                    }
                    .onEnded { _ in
                        if let drag { player.seek(to: drag) }
                        drag = nil
                    })
            }
            .frame(height: 20)
            .animation(.easeOut(duration: 0.15), value: drag == nil)
            HStack {
                Text(live ? "LIVE" : formatTime(value))
                Spacer()
                if let badge = qualityBadge {
                    Text(badge)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                }
                Spacer()
                Text(live ? "" : "-" + formatTime(max(0, total - value)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var qualityBadge: String? {
        guard let song = player.current, !song.isRadio else { return nil }
        if let local = player.downloads?.songs[song.id], player.downloads?.localURL(for: song.id) != nil {
            if local.isLossless { return "Lossless" }
            return local.suffix?.uppercased()
        }
        let format = player.streamingQuality.format
        if format != "raw" { return format.uppercased() }
        if song.isLossless { return "Lossless" }
        return song.suffix?.uppercased()
    }
}

// MARK: - Transport

struct TransportControls: View {
    @Environment(Player.self) private var player

    var body: some View {
        HStack {
            Spacer()
            Button { player.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 32)) }
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 52))
                    .frame(width: 70, height: 70)
                    .contentTransition(.symbolEffect(.replace))
            }
            Spacer()
            Button { player.next() } label: { Image(systemName: "forward.fill").font(.system(size: 32)) }
            Spacer()
        }
        .buttonStyle(PressScaleStyle())
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1)
            .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.15 : 0)).frame(width: 80, height: 80))
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct VolumeRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill").font(.caption).opacity(0.6)
            SystemVolumeSlider().frame(height: 30)
            Image(systemName: "speaker.wave.3.fill").font(.caption).opacity(0.6)
        }
    }
}

struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.tintColor = .white
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor.white.withAlphaComponent(0.7)
        view.activeTintColor = .white
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - Lyrics

struct LyricsPanel: View {
    let song: Song
    @Environment(AppModel.self) private var model
    @State private var lyrics: Lyrics?
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let lyrics, lyrics.synced {
                SyncedLyricsView(lyrics: lyrics)
            } else if let lyrics {
                ScrollView(showsIndicators: false) {
                    Text(lyrics.lines.map(\.value).joined(separator: "\n"))
                        .font(.title2.bold())
                        .lineSpacing(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 24)
                }
                .fadedEdges()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "quote.bubble").font(.largeTitle)
                    Text("Lyrics aren't available for this song.").font(.headline)
                }
                .opacity(0.6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: song.id) {
            loading = true
            lyrics = song.isRadio ? nil : await model.client?.lyrics(for: song)
            loading = false
        }
    }
}

struct SyncedLyricsView: View {
    let lyrics: Lyrics
    @Environment(Player.self) private var player

    var body: some View {
        let ms = Int(player.elapsed * 1000) + lyrics.offset
        let active = lyrics.lines.lastIndex { ($0.start ?? 0) <= ms } ?? -1
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { i, line in
                        Text(line.value.trimmingCharacters(in: .whitespaces).isEmpty ? "♪" : line.value)
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(.white.opacity(i == active ? 1 : 0.32))
                            .blur(radius: i == active || abs(i - active) == 1 ? 0 : 0.6)
                            .scaleEffect(i == active ? 1 : 0.97, anchor: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { player.seek(to: Double(line.start ?? 0) / 1000) }
                            .id(i)
                            .animation(.easeOut(duration: 0.35), value: active)
                    }
                }
                .padding(.vertical, 160)
            }
            .fadedEdges()
            .onChange(of: active) { _, new in
                withAnimation(.spring(response: 0.6, dampingFraction: 0.9)) {
                    proxy.scrollTo(max(new, 0), anchor: UnitPoint(x: 0.5, y: 0.3))
                }
            }
            .onAppear { proxy.scrollTo(max(active, 0), anchor: UnitPoint(x: 0.5, y: 0.3)) }
        }
    }
}

extension View {
    func fadedEdges() -> some View {
        mask(LinearGradient(stops: [
            .init(color: .clear, location: 0), .init(color: .black, location: 0.08),
            .init(color: .black, location: 0.88), .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom))
    }
}

// MARK: - Queue

struct QueuePanel: View {
    @Environment(Player.self) private var player
    @Environment(Router.self) private var router

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    toggle("shuffle", on: player.shuffle) { player.toggleShuffle() }
                    toggle("infinity", on: player.autoplay) { player.autoplay.toggle() }
                    toggle("clock.arrow.circlepath", on: false) { router.go(.history) }
                        .accessibilityLabel("Listening History")
                }
                .listRowBackground(Color.clear)
            }
            if !player.manualRange.isEmpty {
                Section {
                    upcomingRows(player.manualRange)
                } header: {
                    HStack {
                        Text("Queued Songs").font(.headline)
                        Spacer()
                        Button("Clear") { player.clearManualQueue() }.font(.subheadline)
                    }
                    .foregroundStyle(.white)
                    .textCase(nil)
                }
            }
            if !player.sourceRange.isEmpty {
                Section {
                    upcomingRows(player.sourceRange)
                } header: {
                    Text("From Current Selection").font(.headline).foregroundStyle(.white).textCase(nil)
                }
            }
            if player.autoplay && !player.autoplayRange.isEmpty {
                Section {
                    ForEach(Array(player.autoplayRange.prefix(25)), id: \.self) { i in
                        queueRow(i)
                    }
                    .deleteDisabled(true)
                    .moveDisabled(true)
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Autoplay").font(.headline)
                        Text("Similar music plays after your queue").font(.caption).opacity(0.6)
                    }
                    .foregroundStyle(.white)
                    .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(.active))
        .fadedEdges()
    }

    private func upcomingRows(_ range: Range<Int>) -> some View {
        ForEach(Array(range), id: \.self) { queueRow($0) }
            .onMove { player.moveUpcoming(in: range, from: $0, to: $1) }
            .onDelete { offsets in
                for offset in offsets.sorted(by: >) { player.remove(at: range.lowerBound + offset) }
            }
    }

    private func queueRow(_ i: Int) -> some View {
        let song = player.queue[i]
        return HStack(spacing: 12) {
            Artwork(id: song.coverArt, size: 120, corner: 4).frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).lineLimit(1)
                Text(song.artist ?? "").font(.subheadline).opacity(0.6).lineLimit(1)
            }
            Spacer()
        }
        .foregroundStyle(.white)
        .contentShape(Rectangle())
        .onTapGesture { player.jump(to: i) }
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(.white.opacity(0.15))
    }

    private func toggle(_ icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(on ? .white.opacity(0.9) : .white.opacity(0.12), in: Capsule())
                .foregroundStyle(on ? Color.black.opacity(0.75) : .white)
        }
        .buttonStyle(.plain)
    }
}
