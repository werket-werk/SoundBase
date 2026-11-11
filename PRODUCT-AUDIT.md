# SoundBase product audit — 10 November 2026

Reviewed the current iPhone, Mac and Apple Watch source, including the player, generated mix and queue changes shipped in iOS TestFlight 1.0 (5). This is a source audit with documented competitor comparisons; it does not establish device behavior or usage rates. Priorities reflect how often the workflow can matter, how much friction it removes, and how closely it fits a self-hosted music library.

| Priority | What to improve | Why it earns its place |
| --- | --- | --- |
| 1 | Give manually queued tracks their own section and playback priority | The new queue button is easy to use, but its tracks can sit behind an entire album or mix. |
| 2 | Make all search matches reachable | Tracks can already be returned by the server and still be impossible to select from the iPhone results. |
| 3 | Make downloaded albums and playlists usable offline as collections | Downloading a playlist should let you find and play that playlist on a flight or when your server is unreachable. |
| 4 | Save a generated mix as a Navidrome playlist | A good set of recommendations is worth keeping. The new mix screen is the right place to save the exact songs shown. |

## 1. Give manually queued tracks priority

[Add to Queue](SoundBase/Player/Player.swift#L142) inserts before Autoplay but after the rest of the album, playlist or station. The [queue panel](SoundBase/Views/NowPlayingView.swift#L456) presents the manual additions and source tracks together; Clear applies to the whole upcoming range. Play Next already handles a single priority insertion, but adding several tracks that way pushes each new addition to the front.

Spotify's [queue documentation](https://community.spotify.com/forum/en/kb/articles/807-how-does-the-play-queue-work) separates manual additions from the source and plays the manual section first. Keep SoundBase's one-tap button. Have Add to Queue append to the **manual** section, Play Next insert at its front, and Clear Queued Songs clear just that section. Keep the source album or playlist and Autoplay visible separately.

**Acceptance:** Start track 1 of an album, queue X and Y, and hear track 1 → X → Y → track 2. Clear the manual additions and the album continues. Verify shuffle, repeat, duplicate tracks, restore, and Cast before calling it done. The [current server snapshot](SoundBase/Player/Player.swift#L310) is a flat list; retain section identity locally and preserve playback order when sharing with clients that cannot represent the sections.

## 2. Make all search matches reachable

[iPhone Search](SoundBase/Views/SearchSettingsViews.swift#L24) requests up to 25 tracks and [shows only eight](SoundBase/Views/SearchSettingsViews.swift#L64), with no path to all matches. Tapping one starts playback from the returned list, which can include tracks the user never saw. [Mac Search](SoundBaseMac/MacScreens.swift#L181) shows the returned tracks but stops at one page. On iPhone a request error becomes a blank results area.

[Spotify search](https://support.spotify.com/us/article/search/) lets listeners narrow results by track, album or artist. Keep the overview, and give its result sections a **See All** path. Start with Songs and paginate through the [existing song offset](Shared/API/SubsonicClient.swift#L125). Show a retry state when the server is unreachable; a future Downloaded filter should query the local index directly.

**Acceptance:** With more than 25 matches, the ninth and twenty-sixth tracks are reachable from iPhone search. Tapping a result plays the visible selection or just that track, according to the chosen search behavior. An unreachable server produces a distinct retry state instead of an empty screen.

## 3. Keep downloaded playlists and albums intact offline

On [iPhone](SoundBase/Views/LibraryViews.swift#L339) and [Mac](SoundBaseMac/MacScreens.swift#L368), Downloads lists individual files sorted by artist and album. The [download index](SoundBase/Player/DownloadManager.swift#L16) stores track metadata and files; a playlist's title and ordered membership are not persisted. Its [normal detail page](SoundBase/Views/DetailViews.swift#L330) asks the server for the playlist. [Watch Downloads](SoundBaseWatch/WatchViews.swift#L223) already groups tracks by album, but not by downloaded playlist.

[Cassette](https://getcassette.app/#features), another Navidrome client, supports offline library browsing and search. [Plexamp](https://forums.plex.tv/t/plexamp-release-notes/221280?page=6) describes preserving a downloaded playlist's order and refreshing it after server edits.

Start with **Albums · Playlists · Songs** under Downloaded and a local filter. When a playlist is downloaded, retain its name and track order on that device. Show completion and a way to retry missing tracks. Automatic playlist refresh can follow after offline playback is dependable.

**Acceptance:** Download a playlist that spans albums and includes a deliberate repeat. Force quit, enable airplane mode, reopen, and play it in the original order. If a file failed to download, show the missing count. If two downloaded collections share a file, removing one collection should leave the other playable.

## 4. Save a generated mix as a real playlist

[Generated mixes and stations](SoundBase/Views/DetailViews.swift#L383) have Play and Shuffle, plus per-song actions. The displayed selection is held by the page; there is no action to save that exact list. SoundBase already has a [server playlist creation path](Shared/API/SubsonicClient.swift#L146) and an [add-to-playlist picker](SoundBase/Views/LibraryViews.swift#L246) that accepts multiple songs. [Plexamp's release notes](https://forums.plex.tv/t/plexamp-release-notes/221280/44) document the same action for Mixes For You.

Add **Save as Playlist…** to generated playlists, prefill a name, and save a snapshot of the displayed tracks in order. Make success visible only after the server confirms it. Leave live radio out: it has no fixed track list.

**Acceptance:** Save a discovery mix, navigate away, then open the saved playlist in Navidrome or SoundBase on another device. The songs and order match what was on screen, even if generating the mix again gives a different list.

## Playback check before the next beta

[Player initialization](SoundBase/Player/Player.swift#L74) observes the current item, buffering status and normal completion. I didn't find a user-facing terminal stream error with a Retry action. Confirm on hardware what happens when the server drops mid-track or returns an unplayable response. If it leaves the player silent or spinning, surface the error and offer Retry at the same position while retaining the queue. Apple documents [observing player-item failure and showing an appropriate state](https://developer.apple.com/documentation/avfoundation/controlling-the-transport-behavior-of-a-player).

**Suggested release scope:** Queue ordering and complete search results are the best next beta. Save Mix is a contained follow-up. Offline collection playback deserves a separate pass with airplane-mode tests. Defer extra recommendation shelves and audio effects: the audit found clearer user value in making the existing music easier to find, queue and keep.
