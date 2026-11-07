# SoundBase

A native iPhone and Apple Watch player for [Navidrome](https://www.navidrome.org) and any OpenSubsonic server, built in SwiftUI.

## Features

**iPhone**
- Home: Made For You mixes (Favourites, Discovery, artist station, Heavy Rotation), Recently Played, Recently Added, Most Played, Favourite Albums, Rediscover, and "You Might Also Like" similar artists
- New: latest addition hero, new releases, top rated, random picks, genres
- Radio: Discovery and Favourites stations, artist stations, genre stations, Navidrome internet radio
- Library: Playlists, Artists, Albums (sortable), Songs, Genres, Favourites, Downloaded
- Search with top result, songs, albums and artists
- Now Playing: blurred-artwork background, time-synced lyrics (tap a line to seek), Up Next with drag to reorder, shuffle, repeat, Autoplay similar music, AirPlay and Google Cast (Chromecast, Google TV, Nest speakers), lossless badge
- Gapless playback (AVQueuePlayer with preloading), ReplayGain, transcoding options
- Offline downloads with a space-saving AAC quality setting (Original, 256, 192 or 128 kbps), offline scrobble queue, play queue synced with the server across devices
- Lock screen and Control Center controls, favourites (stars), playlists (create, add, remove, delete)

**Apple Watch**
- Standalone: browse playlists, albums, favourites, and download music to the Watch (AAC 128 kbps) to play over Bluetooth headphones without the iPhone
- Remote: control what's playing on the iPhone, favourite songs, and see Up Next
- Signs in automatically using the iPhone's server login

## Building

Requires Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
./scripts/fetch-googlecast.sh   # downloads Google's Cast SDK (~140 MB, checksum-verified) into Vendor/
xcodegen generate
open SoundBase.xcodeproj
```

Passwords are never stored. The app keeps only the Subsonic salted token (in the Keychain on iPhone).
