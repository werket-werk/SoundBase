# SoundBase library management for Navidrome

SoundBase for iPhone and Mac can edit tracks, albums, and artists in a
Navidrome library when this optional helper is installed. The actions appear
in track, album, and artist menus for Navidrome administrators connected
over HTTPS.

## Set up the helper

1. Use a Navidrome version that supports **Report Real Path**. Set
   `ND_SUBSONIC_DEFAULTREPORTREALPATH=true` before the helper first connects.
   If the helper already has a player entry, enable **Report Real Path**
   on that SoundBase entry in Navidrome. Look for the Python user agent.
2. Run the helper with Python 3.11 or later. Give its service account write
   access to the music files and their parent directories. Use the same
   absolute music paths Navidrome reports, including inside container mounts.
   Configure one music root and a private recovery directory on the same
   filesystem, outside every folder Navidrome scans.
3. Run this from the repository on the server. If Navidrome has a base path,
   append it to the internal URL in `--navidrome`.

   ```sh
   python3 -m venv .venv
   .venv/bin/pip install -r server/library/requirements.txt
   .venv/bin/python server/library/manager.py \
     --navidrome http://127.0.0.1:4533 \
     --music /srv/music \
     --recovery /srv/soundbase-recovery
   ```

4. Route `/soundbase-library/v1/` on the same HTTPS origin as Navidrome to
   the helper at `127.0.0.1:4534`. For example, add this location to the
   existing nginx HTTPS virtual host:

   ```nginx
   location /soundbase-library/v1/ {
       proxy_pass http://127.0.0.1:4534;
       client_max_body_size 3m;
       proxy_read_timeout 300s;
   }
   ```

   For a Navidrome base path such as `/music`, match
   `/music/soundbase-library/v1/` and use
   `proxy_pass http://127.0.0.1:4534/soundbase-library/v1/;` to strip the
   base path before forwarding. The helper listens on loopback and checks
   the existing SoundBase account with Navidrome for each request. Keep
   request bodies out of proxy logs because they contain Subsonic credentials.

## Keep the helper running

For a Linux host, create a systemd service after installing the helper in
`/opt/soundbase-library`. Replace `music` with the service account that
owns your files and replace the three paths with your actual paths.

```ini
[Unit]
Description=SoundBase library helper
After=network-online.target
Wants=network-online.target

[Service]
User=music
Group=music
WorkingDirectory=/opt/soundbase-library
ExecStart=/opt/soundbase-library/.venv/bin/python /opt/soundbase-library/manager.py --music /srv/music --recovery /srv/soundbase-recovery --recovery-days 30
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

Save it as `/etc/systemd/system/soundbase-library.service`, then run
`sudo systemctl enable --now soundbase-library`.

For Docker, use the supplied `Dockerfile` and `compose.example.yml`.
Create the recovery directory first and make it writable by the configured
UID/GID. Change the paths, user ID, and external network to match your
Navidrome setup. Run `docker compose -f compose.example.yml up -d --build`
from the helper directory. Put Navidrome, the helper and the HTTPS proxy
on the same Docker network. In the proxy example above, replace the
upstream address with `http://soundbase-library:4534`.
Docker mounts must preserve the absolute paths returned by Navidrome.

## Check the installation

1. Confirm the helper is running with `systemctl status soundbase-library`
   or `docker compose -f compose.example.yml logs soundbase-library`.
2. Reopen a SoundBase build that includes library editing and sign in as a
   Navidrome administrator using your HTTPS address.
3. Look for **Edit Track**, **Edit Album**, and **Edit Artist** in their menus.
4. Try a metadata edit on a test track and wait for the scan. Check it in
   both SoundBase and Navidrome.
5. Check that the recovery folder contains the original file and a
   `.soundbase-completed` marker in the operation directory.

The app’s editing menus require the updated SoundBase build. Server setup
can be completed before that build is installed.

## Changes and recovery

Open **Edit Track**, **Edit Album**, or **Edit Artist** from the item’s menu.
Enter values for the tags you want to change. The genre picker uses the
library’s existing genres. Typing a new genre writes it to the selected
files and makes it available after scanning.

- **Tracks** support title, track artist, album, album artist, release date,
  track and disc numbers, genre, artwork, and a separate audio filename
  rename. File renames preserve the folder and extension.
- **Albums** support title, album artist, release date, genre, and artwork.
  Changes apply to the album’s indexed tracks.
- **Artists** support name and genre changes in matching tracks from albums
  returned for that artist. Name changes replace exact values in Artist and
  Album Artist tags, including the plural variants. Combined credits written
  as a single tag value are preserved. Artist removal moves tracks from
  albums credited solely to that album artist.

For track and album artwork, import an image or choose a release from
MusicBrainz and the Cover Art Archive. The helper embeds the new cover in
FLAC, MP3, or M4A. If Navidrome uses folder images before embedded art, put
`embedded` first in `CoverArtPriority` to display the embedded covers.
For artist artwork, configure Navidrome’s `ArtistImageFolder`, include
`image-folder` in `ArtistArtPriority`, and pass the same folder with
`--artist-images`. Keep that folder on the same filesystem as recovery.
Existing uploaded artist artwork may take precedence. Navidrome’s
**Refresh Metadata** action can refresh cached artwork.

Metadata edits keep the original files under `<kind>-edit-*/originals/`.
Removal moves the affected audio files into `removed-<kind>-*/` and
preserves their relative paths. The helper requests a Navidrome scan after
each change. To undo an edit or removal, restore the files to their
original paths and scan again. The helper permanently purges completed
recovery operations after 30 days, checking at startup and hourly while it
runs. Use `--recovery-days N` to change the window or `--recovery-days 0`
to keep files indefinitely. It leaves manually added files and folders
from older helper versions for the administrator to review.

Navidrome keeps missing records by default so an administrator can recover
play counts, ratings, and playlist references. An administrator may still
see the removed album until they remove its records under **Settings →
Missing Files** in Navidrome. If you already use
`Scanner.PurgeMissing = "always"`, Navidrome clears those records after a
scan. That setting applies to every missing file in the library.

[Navidrome’s missing files documentation](https://navidrome.org/docs/usage/library/missing-files/)

[Navidrome artwork settings](https://www.navidrome.org/docs/usage/library/artwork/)
