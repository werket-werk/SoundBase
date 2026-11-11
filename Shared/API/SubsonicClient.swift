import Foundation
import CryptoKit

struct ServerCredentials: Codable, Equatable, Sendable {
    var url: URL
    var username: String
    var salt: String
    var token: String

    var libraryKey: String {
        let identity = Data((url.absoluteString + "\n" + username).utf8)
        return SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }

    func downloadDirectory(in root: URL) -> URL {
        let folder = root.appendingPathComponent(libraryKey, isDirectory: true)
        let files = FileManager.default
        try? files.createDirectory(at: folder, withIntermediateDirectories: true)
        // The first account after an upgrade claims the former single-account cache.
        let owner = root.appendingPathComponent("legacy-owner")
        if !files.fileExists(atPath: owner.path) {
            try? libraryKey.write(to: owner, atomically: true, encoding: .utf8)
        }
        if (try? String(contentsOf: owner, encoding: .utf8)) == libraryKey,
           let entries = try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
            for entry in entries where entry != owner
                && (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                let destination = folder.appendingPathComponent(entry.lastPathComponent)
                if !files.fileExists(atPath: destination.path) { try? files.moveItem(at: entry, to: destination) }
            }
        }
        return folder
    }

}

enum SubsonicFailure: LocalizedError {
    case invalidURL
    case http(Int)
    case server(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "That server address doesn't look right."
        case .http(let code): "The server responded with HTTP \(code)."
        case .server(let message): message
        case .decoding(let detail): "Unexpected response from server. \(detail)"
        }
    }
}

/// OpenSubsonic API client (token auth; the password itself is never stored).
final class SubsonicClient: Sendable {
    static let clientName = "SoundBase"
    static let apiVersion = "1.16.1"

    let creds: ServerCredentials

    init(creds: ServerCredentials) { self.creds = creds }

    static func makeCredentials(url: URL, username: String, password: String) -> ServerCredentials {
        let salt = (0..<12).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let digest = Insecure.MD5.hash(data: Data((password + salt).utf8))
        let token = digest.map { String(format: "%02x", $0) }.joined()
        return ServerCredentials(url: url, username: username, salt: salt, token: token)
    }

    // MARK: URL building

    func url(_ endpoint: String, _ params: [(String, String)] = []) -> URL {
        var c = URLComponents(url: creds.url.appendingPathComponent("rest/\(endpoint)"), resolvingAgainstBaseURL: false)!
        let base: [(String, String)] = [
            ("u", creds.username), ("t", creds.token), ("s", creds.salt),
            ("v", Self.apiVersion), ("c", Self.clientName), ("f", "json"),
        ]
        c.queryItems = (base + params).map { URLQueryItem(name: $0.0, value: $0.1) }
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }

    func coverURL(_ id: String, size: Int = 600) -> URL {
        url("getCoverArt", [("id", id), ("size", "\(size)")])
    }

    func streamURL(_ id: String, maxBitRate: Int, format: String) -> URL {
        var p: [(String, String)] = [("id", id)]
        if maxBitRate > 0 { p.append(("maxBitRate", "\(maxBitRate)")) }
        if format != "raw" { p.append(("format", format)); p.append(("estimateContentLength", "true")) }
        return url("stream", p)
    }

    func downloadURL(_ id: String) -> URL { url("download", [("id", id)]) }

    // MARK: Transport

    @discardableResult
    func call(_ endpoint: String, _ params: [(String, String)] = [], formPost: Bool = false) async throws -> Payload {
        let endpointURL = url(endpoint, params)
        var request = URLRequest(url: endpointURL)
        if formPost, var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false),
           let query = components.percentEncodedQuery {
            components.query = nil
            if let destination = components.url {
                request.url = destination
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data(query.utf8)
            }
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SubsonicFailure.http(http.statusCode)
        }
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw SubsonicFailure.decoding("\(endpoint): \(error)") }
        guard envelope.response.status == "ok" else {
            throw SubsonicFailure.server(envelope.response.error?.message ?? "Unknown server error")
        }
        return envelope.response
    }

    // MARK: Endpoints

    func ping() async throws { try await call("ping") }

    func albumList(_ type: String, size: Int = 30, offset: Int = 0, genre: String? = nil) async throws -> [Album] {
        var p: [(String, String)] = [("type", type), ("size", "\(size)"), ("offset", "\(offset)")]
        if let genre { p.append(("genre", genre)) }
        return try await call("getAlbumList2", p).albumList2?.album ?? []
    }

    func album(_ id: String) async throws -> AlbumDetail? { try await call("getAlbum", [("id", id)]).album }
    func albumInfo(_ id: String) async throws -> AlbumInfo? { try await call("getAlbumInfo2", [("id", id)]).albumInfo }

    func artists() async throws -> [ArtistIndexEntry] { try await call("getArtists").artists?.index ?? [] }
    func artist(_ id: String) async throws -> ArtistDetail? { try await call("getArtist", [("id", id)]).artist }
    func artistInfo(_ id: String) async throws -> ArtistInfo? {
        try await call("getArtistInfo2", [("id", id), ("count", "15")]).artistInfo2
    }
    func topSongs(artist name: String, count: Int = 20) async throws -> [Song] {
        try await call("getTopSongs", [("artist", name), ("count", "\(count)")]).topSongs?.song ?? []
    }
    func similarSongs(_ id: String, count: Int = 40) async throws -> [Song] {
        try await call("getSimilarSongs", [("id", id), ("count", "\(count)")]).similarSongs?.song ?? []
    }
    func similarSongs2(artistId: String, count: Int = 40) async throws -> [Song] {
        try await call("getSimilarSongs2", [("id", artistId), ("count", "\(count)")]).similarSongs2?.song ?? []
    }
    func randomSongs(size: Int = 50, genre: String? = nil) async throws -> [Song] {
        var p: [(String, String)] = [("size", "\(size)")]
        if let genre { p.append(("genre", genre)) }
        return try await call("getRandomSongs", p).randomSongs?.song ?? []
    }
    func songsByGenre(_ genre: String, count: Int = 200) async throws -> [Song] {
        try await call("getSongsByGenre", [("genre", genre), ("count", "\(count)")]).songsByGenre?.song ?? []
    }
    func genres() async throws -> [Genre] {
        (try await call("getGenres").genres?.genre ?? []).sorted { ($0.songCount ?? 0) > ($1.songCount ?? 0) }
    }

    func search(_ query: String, artists: Int = 8, albums: Int = 12, songs: Int = 25,
                artistOffset: Int = 0, albumOffset: Int = 0, songOffset: Int = 0) async throws -> SearchResult {
        try await call("search3", [
            ("query", query), ("artistCount", "\(artists)"), ("albumCount", "\(albums)"),
            ("songCount", "\(songs)"), ("songOffset", "\(songOffset)"),
            ("artistOffset", "\(artistOffset)"), ("albumOffset", "\(albumOffset)"),
        ]).searchResult3 ?? SearchResult()
    }

    func starred() async throws -> Starred { try await call("getStarred2").starred2 ?? Starred() }

    enum StarKind { case song, album, artist }
    func setStar(_ id: String, kind: StarKind, on: Bool) async throws {
        let key = switch kind { case .song: "id"; case .album: "albumId"; case .artist: "artistId" }
        try await call(on ? "star" : "unstar", [(key, id)])
    }

    func scrobble(_ id: String, submission: Bool, time: Date? = nil) async throws {
        var p: [(String, String)] = [("id", id), ("submission", submission ? "true" : "false")]
        if let time { p.append(("time", "\(Int64(time.timeIntervalSince1970 * 1000))")) }
        try await call("scrobble", p)
    }

    func playlists() async throws -> [Playlist] { try await call("getPlaylists").playlists?.playlist ?? [] }
    func playlist(_ id: String) async throws -> PlaylistDetail? { try await call("getPlaylist", [("id", id)]).playlist }
    func createPlaylist(name: String, songIds: [String]) async throws {
        let parameters = [("name", name)] + songIds.map { ("songId", $0) }
        let needsForm = url("createPlaylist", parameters).absoluteString.utf8.count > 1_900
        try await call("createPlaylist", parameters, formPost: needsForm)
    }
    func renamePlaylist(_ id: String, name: String) async throws {
        try await call("updatePlaylist", [("playlistId", id), ("name", name)])
    }

    func reorderPlaylist(_ id: String, songIDs: [String]) async throws -> PlaylistDetail? {
        let parameters = [("playlistId", id)] + songIDs.map { ("songId", $0) }
        let needsForm = url("createPlaylist", parameters).absoluteString.utf8.count > 1_900
        let response = try await call("createPlaylist", parameters, formPost: needsForm)
        if let playlist = response.playlist { return playlist }
        return try await playlist(id)
    }

    func addToPlaylist(_ id: String, songIds: [String]) async throws {
        try await call("updatePlaylist", [("playlistId", id)] + songIds.map { ("songIdToAdd", $0) })
    }
    func removeFromPlaylist(_ id: String, indexes: [Int]) async throws {
        try await call("updatePlaylist", [("playlistId", id)] + indexes.map { ("songIndexToRemove", "\($0)") })
    }
    func deletePlaylist(_ id: String) async throws { try await call("deletePlaylist", [("id", id)]) }

    func lyrics(for song: Song) async -> Lyrics? {
        if let list = try? await call("getLyricsBySongId", [("id", song.id)]).lyricsList?.structuredLyrics,
           let best = list.first(where: { $0.synced && !($0.line ?? []).isEmpty }) ?? list.first(where: { !($0.line ?? []).isEmpty }) {
            return Lyrics(synced: best.synced, offset: best.offset ?? 0, lines: best.line ?? [])
        }
        guard let artist = song.artist,
              let text = try? await call("getLyrics", [("artist", artist), ("title", song.title)]).lyrics?.value,
              !text.isEmpty else { return nil }
        let lines = text.components(separatedBy: .newlines).map { LyricLine(start: nil, value: $0) }
        return Lyrics(synced: false, offset: 0, lines: lines)
    }

    func savePlayQueue(ids: [String], current: String?, positionMs: Int) async throws {
        var p = ids.map { ("id", $0) }
        if let current { p.append(("current", current)); p.append(("position", "\(positionMs)")) }
        try await call("savePlayQueue", p)
    }
    func playQueue() async throws -> PlayQueue? { try await call("getPlayQueue").playQueue }

    func radioStations() async throws -> [RadioStation] {
        try await call("getInternetRadioStations").internetRadioStations?.internetRadioStation ?? []
    }
}

extension SubsonicClient {
    struct LibraryManagementResponse: Decodable {
        let message: String
        let version: Int?
        let editor: Bool?
        let artistArtwork: Bool?
    }

    func libraryManagement(_ action: String, id: String? = nil, name: String? = nil,
                           kind: String? = nil, tags: [String: String] = [:], artwork: Data? = nil, filename: String? = nil) async throws -> LibraryManagementResponse {
        guard creds.url.scheme?.lowercased() == "https" else { throw SubsonicFailure.invalidURL }
        let url = creds.url.appendingPathComponent("soundbase-library/v1/\(action)")
        struct Body: Encodable {
            let u: String
            let t: String
            let s: String
            let id: String?
            let name: String?
            let kind: String?
            let tags: [String: String]
            let artwork: Data?
            let filename: String?
        }
        let fields = Body(u: creds.username, t: creds.token, s: creds.salt,
                          id: id, name: name, kind: kind, tags: tags, artwork: artwork, filename: filename)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = action == "status" ? 5 : 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(fields)
        let (data, response) = try await URLSession.shared.data(for: request, delegate: RejectLibraryRedirects())
        guard let http = response as? HTTPURLResponse else { throw SubsonicFailure.invalidURL }
        let result = try? JSONDecoder().decode(LibraryManagementResponse.self, from: data)
        guard (200..<300).contains(http.statusCode) else {
            if let result { throw SubsonicFailure.server(result.message) }
            throw SubsonicFailure.http(http.statusCode)
        }
        guard let result else { throw SubsonicFailure.server("Unexpected library management response.") }
        return result
    }
}

private final class RejectLibraryRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
