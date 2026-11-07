import Foundation

// MARK: - Envelope

struct Envelope: Decodable {
    let response: Payload
    enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}

struct SubsonicError: Decodable {
    var code: Int?
    var message: String?
}

/// One payload type for every endpoint; only the relevant key is present per call.
struct Payload: Decodable {
    var status: String
    var error: SubsonicError?
    var albumList2: AlbumList?
    var album: AlbumDetail?
    var artists: ArtistsIndex?
    var artist: ArtistDetail?
    var artistInfo2: ArtistInfo?
    var albumInfo: AlbumInfo?
    var playlists: PlaylistsList?
    var playlist: PlaylistDetail?
    var searchResult3: SearchResult?
    var similarSongs: SongList?
    var similarSongs2: SongList?
    var topSongs: SongList?
    var randomSongs: SongList?
    var songsByGenre: SongList?
    var starred2: Starred?
    var genres: Genres?
    var lyricsList: LyricsList?
    var lyrics: PlainLyrics?
    var playQueue: PlayQueue?
    var internetRadioStations: RadioStations?
}

// MARK: - Library types

struct ReplayGain: Codable, Hashable {
    var trackGain: Double?
    var albumGain: Double?
    var trackPeak: Double?
    var albumPeak: Double?
}

struct Song: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var album: String? = nil
    var albumId: String? = nil
    var artist: String? = nil
    var artistId: String? = nil
    var track: Int? = nil
    var discNumber: Int? = nil
    var year: Int? = nil
    var genre: String? = nil
    var coverArt: String? = nil
    var duration: Int? = nil
    var bitRate: Int? = nil
    var suffix: String? = nil
    var size: Int? = nil
    var starred: String? = nil
    var playCount: Int? = nil
    var replayGain: ReplayGain? = nil

    var isLossless: Bool {
        ["flac", "alac", "wav", "aiff", "ape", "wv"].contains((suffix ?? "").lowercased())
    }
    var isRadio: Bool { id.hasPrefix("radio:") }
}

struct Album: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var artist: String? = nil
    var artistId: String? = nil
    var coverArt: String? = nil
    var songCount: Int? = nil
    var duration: Int? = nil
    var year: Int? = nil
    var genre: String? = nil
    var starred: String? = nil
    var playCount: Int? = nil
}

struct AlbumList: Decodable { var album: [Album]? }

struct AlbumDetail: Decodable, Identifiable {
    var id: String
    var name: String
    var artist: String?
    var artistId: String?
    var coverArt: String?
    var year: Int?
    var genre: String?
    var songCount: Int?
    var duration: Int?
    var starred: String?
    var song: [Song]?
}

struct Artist: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var coverArt: String? = nil
    var albumCount: Int? = nil
    var starred: String? = nil
    var artworkID: String { coverArt ?? "ar-\(id)" }
}

struct ArtistIndexEntry: Decodable { var name: String; var artist: [Artist]? }
struct ArtistsIndex: Decodable { var index: [ArtistIndexEntry]? }

struct ArtistDetail: Decodable, Identifiable {
    var id: String
    var name: String
    var coverArt: String?
    var starred: String?
    var album: [Album]?
    var artworkID: String { coverArt ?? "ar-\(id)" }
}

struct ArtistInfo: Decodable {
    var biography: String?
    var lastFmUrl: String?
    var similarArtist: [Artist]?
}

struct AlbumInfo: Decodable { var notes: String? }

struct Playlist: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var comment: String? = nil
    var owner: String? = nil
    var songCount: Int? = nil
    var duration: Int? = nil
    var coverArt: String? = nil
}

struct PlaylistsList: Decodable { var playlist: [Playlist]? }

struct PlaylistDetail: Decodable, Identifiable {
    var id: String
    var name: String
    var comment: String?
    var owner: String?
    var songCount: Int?
    var duration: Int?
    var coverArt: String?
    var entry: [Song]?
}

struct SearchResult: Decodable {
    var artist: [Artist]?
    var album: [Album]?
    var song: [Song]?
}

struct SongList: Decodable { var song: [Song]? }

struct Starred: Decodable {
    var artist: [Artist]?
    var album: [Album]?
    var song: [Song]?
}

struct Genre: Decodable, Identifiable, Hashable {
    var value: String
    var songCount: Int?
    var albumCount: Int?
    var id: String { value }
}
struct Genres: Decodable { var genre: [Genre]? }

struct LyricLine: Decodable, Hashable {
    var start: Int?
    var value: String
}
struct StructuredLyrics: Decodable {
    var lang: String?
    var synced: Bool
    var offset: Int?
    var line: [LyricLine]?
}
struct LyricsList: Decodable { var structuredLyrics: [StructuredLyrics]? }
struct PlainLyrics: Decodable { var value: String? }

struct PlayQueue: Decodable {
    var current: String?
    var position: Int?
    var entry: [Song]?
}

struct RadioStation: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var streamUrl: String
    var homePageUrl: String?
}
struct RadioStations: Decodable { var internetRadioStation: [RadioStation]? }

/// Lyrics in the shape the UI uses.
struct Lyrics {
    var synced: Bool
    var offset: Int
    var lines: [LyricLine]
}

extension String {
    /// Strips HTML tags and common entities (Last.fm biographies contain links).
    var strippingHTML: String {
        var s = replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (k, v) in ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "] {
            s = s.replacingOccurrences(of: k, with: v)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let s = Int(seconds)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}
