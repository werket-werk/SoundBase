import GoogleCast
import Observation
import SwiftUI

/// Google Cast (Chromecast, Google TV, Nest speakers) using the Default Media Receiver.
/// While a session is active the Player forwards transport commands here, and the
/// receiver's status drives the Player's state (current song, position, play/pause).
@Observable @MainActor
final class CastManager: NSObject, GCKSessionManagerListener, GCKRemoteMediaClientListener {
    static let shared = CastManager()

    private(set) var isCasting = false
    private(set) var deviceName: String?

    @ObservationIgnored weak var player: Player?
    @ObservationIgnored private var lastWindowSongID: String?
    @ObservationIgnored private var lastPosition: Double = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var configured = false

    private var remote: GCKRemoteMediaClient? {
        GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient
    }

    func configure() {
        guard !configured else { return }
        configured = true
        let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        options.physicalVolumeButtonsWillControlDeviceVolume = true
        GCKCastContext.setSharedInstanceWith(options)
        GCKCastContext.sharedInstance().sessionManager.add(self)
    }

    // MARK: Commands from the Player

    /// Loads `songs` as the receiver's queue, starting with the first one.
    func load(_ songs: [Song], position: Double, autoplay: Bool) {
        guard let remote, let api = player?.client, !songs.isEmpty else { return }
        let items = songs.map { song -> GCKMediaQueueItem in
            let metadata = GCKMediaMetadata(metadataType: .musicTrack)
            metadata.setString(song.title, forKey: kGCKMetadataKeyTitle)
            metadata.setString(song.artist ?? "", forKey: kGCKMetadataKeyArtist)
            metadata.setString(song.album ?? "", forKey: kGCKMetadataKeyAlbumTitle)
            if let cover = song.coverArt {
                metadata.addImage(GCKImage(url: api.coverURL(cover, size: 800), width: 800, height: 800))
            }
            let (url, mime) = Self.media(for: song, api: api)
            let info = GCKMediaInformationBuilder(contentURL: url)
            info.contentID = song.id
            info.streamType = song.isRadio ? .live : .buffered
            info.contentType = mime
            info.metadata = metadata
            if let d = song.duration { info.streamDuration = TimeInterval(d) }
            let item = GCKMediaQueueItemBuilder()
            item.mediaInformation = info.build()
            item.autoplay = true
            item.preloadTime = 10
            return item.build()
        }
        let queue = GCKMediaQueueDataBuilder(queueType: .generic)
        queue.items = items
        queue.startIndex = 0
        let request = GCKMediaLoadRequestDataBuilder()
        request.queueData = queue.build()
        request.autoplay = NSNumber(value: autoplay)
        request.startTime = position
        remote.loadMedia(with: request.build())
        lastWindowSongID = songs.last?.id
        lastPosition = position
    }

    func play() { remote?.play() }
    func pause() { remote?.pause() }

    func seek(to seconds: Double) {
        let options = GCKMediaSeekOptions()
        options.interval = seconds
        remote?.seek(with: options)
        lastPosition = seconds
    }

    func stopCasting() {
        GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
    }

    /// Chromecast plays MP3, AAC, FLAC, Ogg and WAV directly; anything else is transcoded to MP3.
    private static func media(for song: Song, api: SubsonicClient) -> (URL, String) {
        if let radio = player(api: api, song: song) { return (radio, "audio/mpeg") }
        let suffix = (song.suffix ?? "").lowercased()
        let types = ["mp3": "audio/mpeg", "aac": "audio/aac", "m4a": "audio/mp4", "flac": "audio/flac",
                     "ogg": "audio/ogg", "opus": "audio/ogg", "oga": "audio/ogg", "wav": "audio/wav"]
        if let mime = types[suffix] {
            return (api.streamURL(song.id, maxBitRate: 0, format: "raw"), mime)
        }
        return (api.streamURL(song.id, maxBitRate: 320, format: "mp3"), "audio/mpeg")
    }

    private static func player(api: SubsonicClient, song: Song) -> URL? {
        song.isRadio ? CastManager.shared.player?.radioURLs[song.id] : nil
    }

    // MARK: Status

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let remote = self.remote, remote.mediaStatus != nil else { return }
                let position = remote.approximateStreamPosition()
                self.lastPosition = position
                self.player?.castTick(position: position)
            }
        }
    }

    private func sessionBegan(_ session: GCKCastSession, resumed: Bool) {
        session.remoteMediaClient?.add(self)
        isCasting = true
        deviceName = session.device.friendlyName
        startTimer()
        if !resumed { player?.castDidStart() }
    }

    private func sessionFinished() {
        guard isCasting else { return }
        timer?.invalidate()
        timer = nil
        isCasting = false
        deviceName = nil
        player?.castDidEnd(position: lastPosition)
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKCastSession) {
        MainActor.assumeIsolated { sessionBegan(session, resumed: false) }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didResumeCastSession session: GCKCastSession) {
        MainActor.assumeIsolated { sessionBegan(session, resumed: true) }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKCastSession, withError error: Error?) {
        MainActor.assumeIsolated { sessionFinished() }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didSuspend session: GCKCastSession, with reason: GCKConnectionSuspendReason) {
        MainActor.assumeIsolated { sessionFinished() }
    }

    nonisolated func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        MainActor.assumeIsolated {
            guard let status = mediaStatus else { return }
            let songID = status.mediaInformation?.contentID
            let playing = [.playing, .buffering, .loading].contains(status.playerState)
            let position = client.approximateStreamPosition()
            lastPosition = position
            player?.castStatus(songID: songID, playing: playing, position: position)
            if status.playerState == .idle, status.idleReason == .finished,
               songID == nil || songID == lastWindowSongID {
                player?.castQueueFinished()
            }
        }
    }
}

/// The standard Cast button (shows available devices, connect/disconnect).
struct CastButton: UIViewRepresentable {
    var tint: UIColor = .white

    func makeUIView(context: Context) -> GCKUICastButton {
        let button = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        button.tintColor = tint
        return button
    }

    func updateUIView(_ uiView: GCKUICastButton, context: Context) {
        uiView.tintColor = tint
    }
}
