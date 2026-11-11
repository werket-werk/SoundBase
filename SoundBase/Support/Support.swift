import Foundation
import Security
import SwiftUI
#if canImport(UIKit)
import Network
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum LibraryLayout: String, CaseIterable {
    case grid, list

    var title: String { self == .grid ? "Grid" : "List" }
    var icon: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
}

struct LibraryLayoutMenu: View {
    @Binding var layout: LibraryLayout

    var body: some View {
        Menu {
            Picker("View", selection: $layout) {
                ForEach(LibraryLayout.allCases, id: \.self) { option in
                    Label(option.title, systemImage: option.icon).tag(option)
                }
            }
        } label: {
            Label("View Options", systemImage: layout.icon)
        }
        .labelStyle(.iconOnly)
        .accessibilityLabel("View Options")
        .accessibilityValue(layout.title)
    }
}

struct LibraryItemTitle: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(.primary)
            if let subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }
}

// MARK: - Keychain-backed credential storage

enum CredentialStore {
    private static let service = "com.werket.soundbase.server"
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
    private let cache = NSCache<NSURL, PlatformImage>()

    init() { cache.countLimit = 400 }

    func cached(_ url: URL) -> PlatformImage? { cache.object(forKey: url as NSURL) }

    func image(_ url: URL) async -> PlatformImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let image = Self.decode(data) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    private static func decode(_ data: Data) -> PlatformImage? {
        #if os(iOS)
        return UIImage(data: data)?.preparingForDisplay() ?? UIImage(data: data)
        #else
        return NSImage(data: data)
        #endif
    }

    func clear() {
        cache.removeAllObjects()
        URLCache.shared.removeAllCachedResponses()
    }
}

#if os(iOS)
extension UIImage {
    func thumbnailJPEG(side: CGFloat, quality: CGFloat = 0.6) -> Data? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { _ in draw(in: CGRect(x: 0, y: 0, width: side, height: side)) }
            .jpegData(compressionQuality: quality)
    }
}
#endif

// MARK: - Settings keys

enum Pref {
    static let maxBitRate = "maxBitRate"      // Int, 0 = original
    static let format = "format"              // "raw", "aac", "opus", "mp3"
    static let replayGain = "replayGain"      // 0 off, 1 track, 2 album
    static let downloadQuality = "downloadQuality" // Int kbps, 0 = original file
    static let downloadFormat = "downloadFormat"
    static let cellularBitRate = "cellularBitRate"  // -1 = use the Wi-Fi setting
    static let wifiOnlyDownloads = "wifiOnlyDownloads"
    static let defaultDownloadQuality = 256
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

// MARK: - Home layout

enum HomeSection: String, CaseIterable, Identifiable {
    case recentPlaylists, recent, history, similar, newest, frequent, favourites, rediscover, mixes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentPlaylists: "Recent Playlists"
        case .mixes: "Made For You"
        case .recent: "Recently Played"
        case .history: "Listening History"
        case .similar: "You Might Also Like"
        case .newest: "Recently Added"
        case .frequent: "Most Played"
        case .favourites: "Favourite Albums"
        case .rediscover: "Rediscover"
        }
    }

    static func order(from value: String) -> [Self] {
        var seen = Set<Self>()
        let saved = value.split(separator: ",").compactMap { Self(rawValue: String($0)) }
        // Put Recent Playlists first when upgrading a layout that predates it.
        let leading: [Self] = saved.contains(.recentPlaylists) ? [] : [.recentPlaylists]
        return (leading + saved + allCases).filter { seen.insert($0).inserted }
    }
}

enum HomeMix: String, CaseIterable, Identifiable {
    case favourites, discovery, artistStation, heavyRotation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .favourites: "Favourites Mix"
        case .discovery: "Discovery Mix"
        case .artistStation: "Artist Station"
        case .heavyRotation: "Heavy Rotation"
        }
    }

    static var available: [Self] {
        #if os(macOS)
        [.favourites, .discovery, .artistStation]
        #else
        allCases
        #endif
    }
}

struct HomeLayout {
    static let recentPlaylistsKey = "homeShowsRecentPlaylists"
    static let orderKey = "homeSectionOrder"
    static let hiddenSectionsKey = "homeHiddenSections"
    static let hiddenMixesKey = "homeHiddenMixes"

    static func toggle(_ id: String, visible: Bool, in value: String) -> String {
        var hidden = Set(value.split(separator: ",").map(String.init))
        if visible { hidden.remove(id) } else { hidden.insert(id) }
        return hidden.sorted().joined(separator: ",")
    }

    static func isVisible(_ id: String, in value: String) -> Bool {
        !value.split(separator: ",").contains(Substring(id))
    }
}

struct RecentPlaylistCards: View {
    let playlists: [Playlist]

    private var columns: [GridItem] {
        #if os(macOS)
        [GridItem(.adaptive(minimum: 165), spacing: 8)]
        #else
        Array(repeating: GridItem(.flexible(), spacing: 8), count: 2)
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            #if os(macOS)
            MacShelfHeader(title: HomeSection.recentPlaylists.title)
            #else
            ShelfHeader(title: HomeSection.recentPlaylists.title)
            #endif
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(playlists) { playlist in
                    NavigationLink(value: Route.playlist(playlist.id)) {
                        HStack(spacing: 8) {
                            Group {
                                #if os(macOS)
                                MacArtwork(id: playlist.coverArt, size: 128, corner: 0)
                                #else
                                Artwork(id: playlist.coverArt, size: 128, corner: 0)
                                #endif
                            }
                            .frame(width: 52, height: 52)
                            .accessibilityHidden(true)
                            Text(playlist.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                                .padding(.vertical, 4)
                                .padding(.trailing, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .foregroundStyle(.primary)
                        .background(.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
                        .clipShape(.rect(cornerRadius: 6))
                        .contentShape(.rect(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            #if os(macOS)
            .padding(.horizontal, 24)
            #else
            .padding(.horizontal)
            #endif
        }
    }
}

struct HomeLayoutSettings: View {
    @AppStorage(HomeLayout.recentPlaylistsKey) private var showRecentPlaylists = true
    @AppStorage(HomeLayout.orderKey) private var order = ""
    @AppStorage(HomeLayout.hiddenSectionsKey) private var hiddenSections = ""
    @AppStorage(HomeLayout.hiddenMixesKey) private var hiddenMixes = ""

    var body: some View {
        Form {
            Section("Home Sections") {
                let sections = HomeSection.order(from: order)
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    HStack {
                        Toggle(section.title, isOn: section == .recentPlaylists
                               ? $showRecentPlaylists : visibility(section.id, in: $hiddenSections))
                        Spacer()
                        moveButton(section, from: index, by: -1, in: sections)
                        moveButton(section, from: index, by: 1, in: sections)
                    }
                }
            }
            Section("Made For You Cards") {
                ForEach(HomeMix.available) { mix in
                    Toggle(mix.title, isOn: visibility(mix.id, in: $hiddenMixes))
                }
            }
            Button("Reset to Default") {
                showRecentPlaylists = true
                order = ""
                hiddenSections = ""
                hiddenMixes = ""
            }
            .disabled(showRecentPlaylists && order.isEmpty && hiddenSections.isEmpty && hiddenMixes.isEmpty)
        }
        .formStyle(.grouped)
        .navigationTitle("Customize Home")
    }

    private func visibility(_ id: String, in hidden: Binding<String>) -> Binding<Bool> {
        Binding {
            HomeLayout.isVisible(id, in: hidden.wrappedValue)
        } set: { visible in
            hidden.wrappedValue = HomeLayout.toggle(id, visible: visible, in: hidden.wrappedValue)
        }
    }

    private func moveButton(_ section: HomeSection, from index: Int, by offset: Int, in sections: [HomeSection]) -> some View {
        let target = index + offset
        let direction = offset < 0 ? "up" : "down"
        return Button {
            var updated = sections
            updated.swapAt(index, target)
            order = updated.map(\.rawValue).joined(separator: ",")
        } label: {
            Image(systemName: "arrow.\(direction)")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Move \(section.title) \(direction)")
        .disabled(!sections.indices.contains(target))
    }
}


// MARK: - Audio quality

enum DownloadFormat: String, CaseIterable, Identifiable {
    case original, aac, mp3, opus

    var id: String { rawValue }
    var title: String { self == .original ? "Original" : rawValue.uppercased() }

    static func selected(quality: Int, format: String) -> Self {
        guard quality > 0 else { return .original }
        guard let selected = Self(rawValue: format), selected != .original else { return .aac }
        return selected
    }
}

struct DownloadQualitySettings: View {
    @AppStorage(Pref.downloadQuality) private var quality = Pref.defaultDownloadQuality
    @AppStorage(Pref.downloadFormat) private var format = DownloadFormat.aac.rawValue

    private var selection: Binding<DownloadFormat> {
        Binding {
            DownloadFormat.selected(quality: quality, format: format)
        } set: { selected in
            if selected == .original {
                quality = 0
            } else {
                format = selected.rawValue
                if quality == 0 { quality = Pref.defaultDownloadQuality }
            }
        }
    }

    var body: some View {
        Picker("Download Format", selection: selection) {
            ForEach(DownloadFormat.allCases) { Text($0.title).tag($0) }
        }
        if quality > 0 {
            Picker("Download Quality", selection: $quality) {
                ForEach([320, 256, 192, 128, 96, 64], id: \.self) { rate in
                    Text("\(rate) kbps").tag(rate)
                }
            }
        }
    }
}

#if os(iOS)
@MainActor
final class StreamingConnection {
    static let shared = StreamingConnection()

    private let monitor = NWPathMonitor()
    var isCellular: Bool { monitor.currentPath.usesInterfaceType(.cellular) }

    private init() {
        monitor.start(queue: DispatchQueue(label: "SoundBase.StreamingConnection"))
    }
}
#endif
