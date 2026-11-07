import Foundation
import Security
import UIKit

// MARK: - Keychain-backed credential storage

enum CredentialStore {
    private static let service = "com.lunero.SoundBase.server"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "default"]
    }

    static func save(_ creds: ServerCredentials) {
        guard let data = try? JSONEncoder().encode(creds) else { return }
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load() -> ServerCredentials? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(ServerCredentials.self, from: data)
    }

    static func clear() { SecItemDelete(query as CFDictionary) }
}

// MARK: - Image loading with memory + URL disk cache

final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()
    private let cache = NSCache<NSURL, UIImage>()

    init() { cache.countLimit = 400 }

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    func image(_ url: URL) async -> UIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let image = UIImage(data: data)?.preparingForDisplay() ?? UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    func clear() {
        cache.removeAllObjects()
        URLCache.shared.removeAllCachedResponses()
    }
}

extension UIImage {
    func thumbnailJPEG(side: CGFloat, quality: CGFloat = 0.6) -> Data? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { _ in draw(in: CGRect(x: 0, y: 0, width: side, height: side)) }
            .jpegData(compressionQuality: quality)
    }
}

// MARK: - Settings keys

enum Pref {
    static let maxBitRate = "maxBitRate"      // Int, 0 = original
    static let format = "format"              // "raw", "aac", "opus", "mp3"
    static let replayGain = "replayGain"      // 0 off, 1 track, 2 album
    static let autoplay = "autoplay"
    static let lastServer = "lastServer"
    static let lastUser = "lastUser"
}

// MARK: - Offline scrobble queue

enum PendingScrobbles {
    private static let key = "pendingScrobbles"

    static func add(id: String, time: Date) {
        var all = UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []
        all.append(["id": id, "t": time.timeIntervalSince1970])
        UserDefaults.standard.set(Array(all.suffix(2000)), forKey: key)
    }

    static func flush(using client: SubsonicClient) async {
        let all = UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []
        guard !all.isEmpty else { return }
        var remaining: [[String: Any]] = []
        for entry in all {
            guard let id = entry["id"] as? String, let t = entry["t"] as? Double else { continue }
            do { try await client.scrobble(id, submission: true, time: Date(timeIntervalSince1970: t)) }
            catch { remaining.append(entry) }
        }
        UserDefaults.standard.set(remaining, forKey: key)
    }
}
