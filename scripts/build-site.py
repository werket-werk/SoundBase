#!/usr/bin/env python3
"""Generates the GitHub Pages site in docs/. Screenshot encoding requires cwebp."""
from pathlib import Path
from struct import unpack
from subprocess import run

REPO = "https://github.com/werket-werk/SoundBase"
EMAIL = "hello@werket.com.au"
UPDATED = "8 November 2026"
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs"


def screenshot(filename, alt):
    source = ROOT / "screenshots" / f"{filename}.png"
    asset = Path("assets/screenshots") / f"{filename}.webp"
    destination = OUT / asset
    destination.parent.mkdir(parents=True, exist_ok=True)
    run(["cwebp", "-quiet", "-q", "85", "-sharp_yuv", str(source), "-o", str(destination)], check=True)
    with source.open("rb") as png:
        png.seek(16)  # Width and height in the PNG IHDR chunk.
        width, height = unpack(">II", png.read(8))
    return f'<img src="{asset}" width="{width}" height="{height}" alt="{alt}" loading="lazy" decoding="async">'


def screenshot_group(platform, folder, screens):
    figures = []
    for filename, label in screens:
        preview = screenshot(f"{folder}/{filename}", f"{label} on {platform}")
        asset = f"assets/screenshots/{folder}/{filename}.webp"
        figures.append(f"""      <figure>
        <a href="{asset}" aria-label="Enlarge {label} on {platform}">{preview}</a>
        <figcaption>{label}</figcaption>
      </figure>""")
    overview = screenshot(f"{folder}-overview", f"Combined preview of SoundBase on {platform}")
    previews = "\n".join(figures)
    return f"""  <div class="screenshot-group">
    <h3>{platform}</h3>
    <div class="screenshot-grid screenshot-{folder}">
{previews}
    </div>
    <details class="screenshot-overview">
      <summary>View {platform} overview</summary>
      {overview}
    </details>
  </div>"""


SCREENSHOTS = "\n".join((
    screenshot_group("iPhone", "iphone", [
        ("01-home", "Home"),
        ("02-now-playing", "Now Playing"),
        ("03-lyrics", "Lyrics"),
        ("04-album", "Album"),
        ("05-queue", "Queue"),
        ("06-library", "Library"),
        ("07-playlist", "Playlist"),
        ("08-artist", "Artist"),
        ("09-search", "Search"),
    ]),
    screenshot_group("Apple Watch", "watch", [
        ("01-library", "Library"),
        ("02-remote", "Remote controls"),
        ("03-album", "Album"),
        ("04-downloaded", "Downloads"),
        ("05-now-playing", "Now Playing"),
    ]),
    screenshot_group("Mac", "mac", [
        ("01-home", "Home"),
        ("02-album-lyrics", "Album and lyrics"),
        ("03-artist", "Artist"),
        ("04-playlist-queue", "Playlist and queue"),
        ("05-albums", "Albums"),
    ]),
))

def page(slug, title, description, body):
    nav = f"""<header class="nav"><div class="wrap">
  <a class="brand" href="index.html"><img src="assets/icon.png" alt="">SoundBase</a>
  <nav class="links">
    <a href="index.html#features" class="hide-sm">Features</a>
    <a href="index.html#screenshots" class="hide-sm">Screenshots</a>
    <a href="support.html">Support</a>
    <a href="privacy.html">Privacy</a>
    <a href="{REPO}">GitHub</a>
  </nav>
</div></header>"""
    footer = f"""<footer><div class="wrap">
  <span>© 2026 SoundBase. Free and open source under the MIT License.</span>
  <span class="links"><a href="privacy.html">Privacy Policy</a><a href="terms.html">Terms of Use</a><a href="support.html">Support</a><a href="{REPO}">Source Code</a></span>
  <span class="fine">SoundBase is an independent project and is not affiliated with or endorsed by Navidrome, Subsonic, Apple or Google. Apple, iPhone, Apple Watch, Mac, AirPlay and App Store are trademarks of Apple Inc. Google Cast and Chromecast are trademarks of Google LLC.</span>
</div></footer>"""
    html = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<meta name="description" content="{description}">
<meta property="og:title" content="{title}">
<meta property="og:description" content="{description}">
<meta property="og:image" content="assets/icon.png">
<link rel="icon" href="assets/favicon.png">
<link rel="apple-touch-icon" href="assets/icon.png">
<link rel="stylesheet" href="assets/style.css">
</head>
<body>
{nav}
<main>
{body}
</main>
{footer}
</body>
</html>
"""
    (OUT / f"{slug}.html").write_text(html)

# ---------------------------------------------------------------- Home
page("index", "SoundBase — Your Navidrome music, beautifully",
     "A free, open-source music player for Navidrome and OpenSubsonic servers on iPhone, Apple Watch and Mac.", f"""
<section class="hero"><div class="wrap">
  <img class="app-icon" src="assets/icon.png" alt="SoundBase app icon">
  <h1>Your music.<br><span>Your server.</span></h1>
  <p class="lede">SoundBase is a free, open-source player for Navidrome and OpenSubsonic. It feels right at home on iPhone, Apple Watch and Mac.</p>
  <div class="buttons">
    <a class="btn primary" href="#download">Download on the App Store</a>
    <a class="btn secondary" href="{REPO}">View Source on GitHub</a>
  </div>
  <p class="platforms">iPhone (iOS 18+) · Apple Watch (watchOS 11+) · Mac (macOS 15+)</p>
  <a href="#screenshots">See screenshots ↓</a>
</div></section>

<section id="features" class="soft"><div class="wrap">
  <h2>Everything you love about a music app.</h2>
  <p class="section-lede">Your own library, with the listening experience you expect.</p>
  <div class="grid">
    <div class="card"><div class="ico">✦</div><h3>Made For You</h3><p>Favourites and Discovery mixes, artist and genre stations, and “You Might Also Like” suggestions from your own library.</p></div>
    <div class="card"><div class="ico">❝</div><h3>Time-synced lyrics</h3><p>Lyrics that follow along line by line. Tap any line to jump to it.</p></div>
    <div class="card"><div class="ico">∞</div><h3>Autoplay &amp; gapless</h3><p>Seamless track transitions, an Up Next queue you can reorder, and Autoplay that keeps similar music going.</p></div>
    <div class="card"><div class="ico">↓</div><h3>Offline downloads</h3><p>Download albums and playlists in space-saving AAC or original quality, and listen anywhere.</p></div>
    <div class="card"><div class="ico">◎</div><h3>AirPlay &amp; Google Cast</h3><p>Send music to AirPlay speakers, Chromecast, Google TV and Nest speakers.</p></div>
    <div class="card"><div class="ico">◐</div><h3>Make it yours</h3><p>Light and dark modes, 11 accent colours with matching app icons, and a choice of Now Playing backgrounds.</p></div>
  </div>
</div></section>

<section><div class="wrap">
  <h2>One app. Every Apple device.</h2>
  <p class="section-lede">Your queue syncs through your server, so you can pick up where you left off.</p>
  <div class="devices">
    <div class="device phone"><h3>iPhone</h3><ul><li>Home, New, Radio, Library and Search</li><li>Lock Screen, Control Center and Dynamic Island</li><li>AirPlay and Google Cast</li></ul></div>
    <div class="device watch"><h3>Apple Watch</h3><ul><li>Download music to your wrist</li><li>Play with Bluetooth headphones, no iPhone needed</li><li>Control what's playing on your iPhone</li></ul></div>
    <div class="device mac"><h3>Mac</h3><ul><li>Sidebar library and native song tables</li><li>Lyrics and queue side panel</li><li>Menu bar mini player and keyboard shortcuts</li></ul></div>
  </div>
</div></section>

<section id="screenshots" class="soft"><div class="wrap">
  <h2>SoundBase screenshots</h2>
  <p class="section-lede">Explore the app on iPhone, Apple Watch and Mac. Select any screenshot to enlarge it.</p>
{SCREENSHOTS}
</div></section>

<section class="soft"><div class="wrap privacy-banner">
  <div class="big">🔒</div>
  <div>
    <h2>Private by design.</h2>
    <p class="section-lede" style="margin:0">SoundBase talks only to the server you choose. No accounts, no ads, no tracking, and your password is never stored. <a href="privacy.html">Read the privacy policy →</a></p>
  </div>
</div></section>

<section id="download"><div class="wrap" style="text-align:center">
  <h2>Get SoundBase</h2>
  <p class="section-lede" style="margin:0 auto 28px">Free on the App Store. You'll need a <a href="https://www.navidrome.org">Navidrome</a> server or any OpenSubsonic-compatible server.</p>
  <div class="buttons">
    <a class="btn primary" href="#download">App Store: coming soon</a>
    <a class="btn secondary" href="{REPO}">Build it yourself</a>
  </div>
</div></section>
""")

# ---------------------------------------------------------------- Privacy
page("privacy", "Privacy Policy — SoundBase", "How SoundBase handles your information.", f"""
<article class="doc"><div class="wrap">
<h1>Privacy Policy</h1>
<p class="updated">Last updated {UPDATED}</p>

<div class="callout"><strong>In short:</strong> SoundBase has no accounts, no ads and no analytics of its own. It connects only to the music server you enter. The developer never receives your music, your listening history or your login. The one exception is Google Cast on iPhone, described below.</div>

<p>This policy explains how the SoundBase apps for iPhone, Apple Watch and Mac (“SoundBase”, “the app”) handle information. SoundBase is free, open-source software. You can check everything described here in the <a href="{REPO}">source code</a>.</p>

<h2>1. Information the app handles</h2>
<h3>Your server address and login</h3>
<p>To connect, you enter your server address, username and password. SoundBase does not store your password. It turns it into a salted token, the standard Subsonic authentication method, and stores only the server address, username and that token. They are kept on your device in the system Keychain on iPhone and Mac. They are shared with the SoundBase Apple Watch app over Apple's encrypted WatchConnectivity link so the Watch can sign in.</p>

<h3>Your music library and listening activity</h3>
<p>SoundBase sends requests directly from your device to your server to browse your library, stream and download music, fetch artwork and lyrics, save playlists and favourites, sync your play queue, and report plays (“scrobbles”). This information goes only to the server you chose. It is governed by that server's operator, who is usually you, and the developer never receives it.</p>

<h3>Data stored on your device</h3>
<p>Downloaded songs, cached artwork, your settings (for example theme and streaming quality) and a short list of plays waiting to be sent to your server while you're offline are stored only on your device. They are removed when you delete the app.</p>

<h2>2. Information the developer collects</h2>
<p><strong>None.</strong> The developer does not operate any servers for SoundBase and does not collect, store, sell or share personal information. SoundBase contains no advertising, analytics or tracking code written by the developer.</p>

<h2>3. Third-party services</h2>
<h3>Google Cast (iPhone only)</h3>
<p>The iPhone app includes Google's Cast SDK so you can play music on Chromecast, Google TV and Nest devices. To find and talk to Cast devices on your local network, the Cast SDK may collect and send to Google:</p>
<ul>
  <li>a device identifier</li>
  <li>diagnostic data, such as crash and performance information</li>
  <li>product interaction data, such as how Cast features are used</li>
</ul>
<p>Google says this data is used for app functionality and analytics. It is <strong>not linked to your identity</strong> and is <strong>not used for tracking</strong>. When you cast, the Cast device streams music directly from your server. Google's handling of this data is covered by the <a href="https://policies.google.com/privacy">Google Privacy Policy</a>. The Apple Watch and Mac apps don't include the Cast SDK.</p>

<h3>Your music server</h3>
<p>Your server may use other services, such as Last.fm or similar sources for artist images, biographies and similar songs. Those are configured and controlled on your server, not by SoundBase.</p>

<h3>Apple</h3>
<p>If you download SoundBase from the App Store, Apple may provide the developer with aggregated, anonymous statistics and crash reports, but only if you've chosen to share them with app developers. See <a href="https://www.apple.com/legal/privacy/">Apple's Privacy Policy</a>.</p>

<h2>4. Permissions</h2>
<table>
  <tr><th>Permission</th><th>Why</th></tr>
  <tr><td>Local Network (iPhone)</td><td>To find Chromecast and Google TV devices on your network when you want to cast.</td></tr>
  <tr><td>Background audio</td><td>To keep playing music when the app is in the background or the screen is locked.</td></tr>
  <tr><td>Network access</td><td>To connect to your music server.</td></tr>
</table>

<h2>5. Children</h2>
<p>SoundBase doesn't knowingly collect personal information from anyone, including children under 13 (or the equivalent age where you live).</p>

<h2>6. Your choices</h2>
<ul>
  <li>Sign out in Settings to remove your server login from the device.</li>
  <li>Delete downloads in Settings or Library › Downloaded.</li>
  <li>Don't use casting if you'd rather the Cast SDK didn't run. Deleting the app removes everything it stored.</li>
  <li>Data held by your music server can be managed or deleted by that server's administrator.</li>
</ul>

<h2>7. Security</h2>
<p>Use an <code>https://</code> server address so traffic between the app and your server is encrypted. SoundBase can connect to plain <code>http://</code> servers, for example on your home network, but that traffic isn't encrypted.</p>

<h2>8. Changes to this policy</h2>
<p>If this policy changes, the updated version will be posted on this page with a new “Last updated” date. Its history is also visible in the project's public repository.</p>

<h2>9. Contact</h2>
<p>Questions about privacy? Email <a href="mailto:{EMAIL}">{EMAIL}</a> or <a href="{REPO}/issues">open an issue on GitHub</a>.</p>
</div></article>
""")

# ---------------------------------------------------------------- Support
page("support", "Support — SoundBase", "Help with setting up and using SoundBase.", f"""
<article class="doc"><div class="wrap">
<h1>Support</h1>
<p class="updated">Need a hand? Start here.</p>

<div class="callout">Found a bug or have an idea? <a href="{REPO}/issues/new">Open an issue on GitHub</a>, or email <a href="mailto:{EMAIL}">{EMAIL}</a>. Please include your device, OS version, SoundBase version and server type and version (for example Navidrome 0.64).</div>

<h2>Getting started</h2>
<ol>
  <li>Set up <a href="https://www.navidrome.org/docs/installation/">Navidrome</a> or any OpenSubsonic-compatible server, and make sure you can reach it from your device.</li>
  <li>Open SoundBase and enter your server address (for example <code>music.example.com</code>), username and password.</li>
  <li>That's it. On Apple Watch, open SoundBase after signing in on your iPhone and it connects automatically.</li>
</ol>

<h2>Frequently asked questions</h2>
<details><summary>Which servers work with SoundBase?</summary><p>Navidrome is the main server it's tested with. Other servers that support the Subsonic or OpenSubsonic API should work, but some features (like synced lyrics) depend on the server supporting them.</p></details>
<details><summary>Why can't I sign in?</summary><p>Check the address includes the right port if your server uses one (for example <code>music.example.com:4533</code>), that the server is reachable from your device, and that your username and password work in the server's web interface. If your server is only on your home network, you need to be on that network or a VPN.</p></details>
<details><summary>Lyrics don't show up for a song.</summary><p>Lyrics come from your server. Navidrome reads lyrics embedded in your music files and from <code>.lrc</code> files next to them. Time-synced lyrics need a synced (LRC) source.</p></details>
<details><summary>“You Might Also Like”, similar songs and artist bios are empty.</summary><p>These come from your server's external info provider. In Navidrome, enable Last.fm integration (or another agent) so it can fetch similar artists and biographies.</p></details>
<details><summary>How do downloads work, and how much space do they use?</summary><p>By default, lossless songs are converted to AAC 256 kbps as they download (about 2 MB per minute). MP3 and AAC files that are already small are kept as they are. You can choose Original, 256, 192 or 128 kbps in Settings. Apple Watch downloads use AAC 128 kbps. AAC conversion needs Navidrome 0.64 or later.</p></details>
<details><summary>How do I listen on Apple Watch without my iPhone?</summary><p>On the Watch, open SoundBase and download a playlist or album while connected to Wi-Fi or your iPhone. Then pair Bluetooth headphones with your Watch and play from Downloaded.</p></details>
<details><summary>How do I cast to a Chromecast or Google TV?</summary><p>Make sure your iPhone and the Cast device are on the same Wi-Fi network and that you've allowed Local Network access for SoundBase (Settings › Privacy &amp; Security › Local Network). Then tap the Cast button in Now Playing. Your server must be reachable from the Cast device, and an <code>https://</code> address works best.</p></details>
<details><summary>Can I change the app icon?</summary><p>Yes. Pick a colour in Settings › Appearance and the icon changes to match, if “App Icon Matches Colour” is on.</p></details>
<details><summary>Is SoundBase really free?</summary><p>Yes. It's free, has no ads or in-app purchases, and the full source code is on <a href="{REPO}">GitHub</a> under the MIT License.</p></details>
<details><summary>Does SoundBase collect my data?</summary><p>No. The app talks only to your server. See the <a href="privacy.html">privacy policy</a> for details, including the Google Cast SDK on iPhone.</p></details>

<h2>Contributing</h2>
<p>SoundBase is open source. Pull requests, translations and bug reports are welcome on <a href="{REPO}">GitHub</a>.</p>
</div></article>
""")

# ---------------------------------------------------------------- Terms
page("terms", "Terms of Use — SoundBase", "Terms for using SoundBase.", f"""
<article class="doc"><div class="wrap">
<h1>Terms of Use</h1>
<p class="updated">Last updated {UPDATED}</p>

<h2>1. The software</h2>
<p>SoundBase is free, open-source software distributed under the <a href="{REPO}/blob/main/LICENSE">MIT License</a>. You may use, copy, modify and distribute it under that licence. If you got SoundBase from the App Store, Apple's <a href="https://www.apple.com/legal/internet-services/itunes/dev/stdeula/">Standard Licensed Application End User License Agreement</a> also applies. Where they conflict, the MIT License governs your rights to the source code.</p>

<h2>2. Your server and your content</h2>
<p>SoundBase is a client. It doesn't provide, host or sell any music. You're responsible for the server you connect to and for making sure you have the right to access and play the music on it.</p>

<h2>3. No warranty</h2>
<p>SoundBase is provided “as is”, without warranty of any kind, express or implied, including fitness for a particular purpose and non-infringement. To the maximum extent permitted by law, the authors are not liable for any claim, damages or other liability arising from use of the software. Nothing in these terms limits rights you have under consumer law that can't be excluded.</p>

<h2>4. Third-party services</h2>
<p>Features like Google Cast and AirPlay rely on services provided by third parties, under their own terms. SoundBase isn't affiliated with or endorsed by Navidrome, Subsonic, Apple or Google.</p>

<h2>5. Changes</h2>
<p>These terms may be updated from time to time. Changes will be posted on this page.</p>

<h2>6. Contact</h2>
<p><a href="mailto:{EMAIL}">{EMAIL}</a></p>
</div></article>
""")

(OUT / ".nojekyll").write_text("")
print("Site written to", OUT)
