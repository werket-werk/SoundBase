# App Store submission guide

Everything App Store Connect asks for, ready to paste. One app record covers iPhone, Apple Watch and Mac (universal purchase: all three targets use the bundle ID `com.werket.soundbase`).

## 1. Before you submit

- [ ] Make the GitHub repo public (the app is open source and the website links to it).
- [ ] Turn on GitHub Pages: repo **Settings → Pages → Deploy from branch → `main` / `/docs`**. The site will be at `https://werket-werk.github.io/SoundBase/`. A custom domain can be set there too.
- [ ] In Xcode → Settings → Accounts, make sure your Apple Account is signed in for team **225KXPVW4C**.
- [ ] In App Store Connect → Apps → **+ New App**: platforms iOS + macOS, name below, bundle ID `com.werket.soundbase`, SKU `soundbase`.
- [ ] Run `./scripts/fetch-googlecast.sh` and `xcodegen generate`, then archive the **SoundBase** scheme (iOS + Watch) and the **SoundBaseMac** scheme, and upload both.
- [ ] Take screenshots (sizes in section 6).

## 2. Listing

| Field | Value |
|---|---|
| Name (30) | `SoundBase` (if taken: `SoundBase Music Player`) |
| Subtitle (30) | `Player for Navidrome` |
| Category | Music (secondary: none) |
| Price | Free |
| Promotional text (170) | `Your own music library, beautifully. Synced lyrics, mixes and stations, gapless playback, offline downloads, AirPlay and Google Cast, on iPhone, Apple Watch and Mac.` |
| Keywords (100) | `navidrome,subsonic,opensubsonic,self-hosted,music player,flac,lossless,lyrics,offline,streaming` |
| Support URL | `https://werket-werk.github.io/SoundBase/support.html` |
| Marketing URL | `https://werket-werk.github.io/SoundBase/` |
| Privacy Policy URL | `https://werket-werk.github.io/SoundBase/privacy.html` |
| Copyright | `2026 Erik Sawaya` |

### Description

```
SoundBase is a free, open-source music player for Navidrome and other OpenSubsonic servers. Bring your own music library and enjoy it with the listening experience you expect, on iPhone, Apple Watch and Mac.

MADE FOR YOU
• Favourites and Discovery mixes, artist stations and genre stations
• "You Might Also Like" suggestions from your library
• Recently played, recently added, most played and more

A PLAYER THAT FEELS AT HOME
• Time-synced lyrics that follow along. Tap a line to jump to it
• Gapless playback and an Up Next queue you can reorder
• Autoplay keeps similar music going when your queue ends
• Lock Screen, Control Center and Dynamic Island controls
• AirPlay and Google Cast (Chromecast, Google TV, Nest speakers)
• ReplayGain volume levelling and transcoding options

YOUR LIBRARY, ANYWHERE
• Download albums and playlists for offline listening
• Space-saving AAC downloads, or keep original lossless files
• Plays made offline are sent to your server when you reconnect
• Your play queue syncs across devices through your server

APPLE WATCH
• Download music to your Watch and listen with Bluetooth headphones, no iPhone needed
• Control what's playing on your iPhone from your wrist

MAC
• Sidebar library, song tables, lyrics and queue panel
• Menu bar mini player and keyboard shortcuts

MAKE IT YOURS
• Light and dark modes, 11 accent colours with matching app icons
• Choose your Now Playing background

PRIVATE BY DESIGN
SoundBase talks only to your server. No accounts, no ads, no tracking, and your password is never stored.

Requires a Navidrome server or any OpenSubsonic-compatible server.
```

## 3. App Privacy (nutrition label)

SoundBase itself collects nothing. The iPhone app includes the **Google Cast SDK**, whose privacy manifest declares the data below. Declare it for the app record:

- **Data used to track you:** None.
- **Data linked to you:** None.
- **Data not linked to you:**

| Category | Type | Purposes |
|---|---|---|
| Identifiers | Device ID | Analytics, App Functionality |
| Usage Data | Product Interaction | Analytics, App Functionality |
| Diagnostics | Other Diagnostic Data | Analytics, App Functionality |

If you ever remove Google Cast, change the answer to **Data Not Collected**.

## 4. App Review information

- **Sign-in required:** Yes. Reviewers need a server to connect to. Give them an account on your own server with a few albums (more reliable), or Navidrome's public demo server if it's still up when you submit (check navidrome.org for the current address and login).
- **Notes for reviewer** (paste and fill in):

```
SoundBase is a client for self-hosted Navidrome/OpenSubsonic music servers. It doesn't provide any music itself.

To test, sign in with:
Server: <your server address>
Username: <reviewer username>
Password: <reviewer password>

The Apple Watch app picks up the login from the iPhone automatically. Downloads on the Watch need Wi-Fi or a connected iPhone; playback on the Watch needs Bluetooth headphones.
Google Cast needs a Chromecast on the same network; AirPlay uses the standard system picker.
```

## 5. Other questionnaire answers

| Question | Answer |
|---|---|
| Export compliance | Uses only standard HTTPS. `ITSAppUsesNonExemptEncryption` is already set to `NO` in all three Info.plists, so you won't be asked each build. |
| Content rights | The app shows only content from the user's own server. It doesn't contain or provide third-party content. |
| Age rating | Answer "None" to every content question. The app provides no content itself, so it should be rated 4+. |
| Advertising identifier (IDFA) | No |
| Sign in with Apple | Not required (no third-party or social logins). |
| Encryption documentation | Not needed. |

## 6. Screenshots

| Device | Size (portrait) | Suggested shots |
|---|---|---|
| iPhone 6.9" (required) | 1320 × 2868 | Home, Now Playing, Lyrics, Album, Queue |
| Apple Watch (required for the Watch app) | 422 × 514 (Ultra) or 416 × 496 | Library, Downloads, Remote |
| Mac (required) | 2880 × 1800 | Home with sidebar, Album, Lyrics panel |

iPhone 6.9" screenshots are ready in `screenshots/iphone/` (1320 × 2868). They show an invented demo library with original generated artwork, so there's no third-party album art in the listing. Apple Watch screenshots (Ultra, 422 × 514) are in `screenshots/watch/`, retaken with `scripts/watch-screenshots.sh`. To retake them, run a local Navidrome with demo content and use `scripts/screenshots.sh` (it uses the debug-only screenshot mode in `ScreenshotDirector.swift`).

## 7. Open-source notes

- Licence: MIT (`LICENSE`). The Google Cast SDK is proprietary and not committed; `scripts/fetch-googlecast.sh` downloads it from Google with a pinned checksum.
- Distributing an MIT app on the App Store has no licence conflicts. Avoid adding GPL code, because the GPL's terms conflict with Apple's App Store terms.
