"""SoundBase library management. Run behind the Navidrome HTTPS reverse proxy."""

import argparse
import base64
from io import BytesIO
import json
import logging
import os
from pathlib import Path
import shutil
import tempfile
import time
import re
import stat
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener

from PIL import Image
from mutagen import File
from mutagen.flac import FLAC, Picture
from mutagen.id3 import APIC
from mutagen.mp3 import MP3
from mutagen.mp4 import MP4, MP4Cover
from mutagen.easyid3 import EasyID3
from mutagen.easymp4 import EasyMP4Tags


RECOVERY_MARKER = ".soundbase-completed"
RECOVERY_OPERATION = re.compile(r"(?:removed-(?:track|album|artist)|(?:track|album|artist)-edit)-[a-z0-9_]{8}")
SECONDS_PER_DAY = 86400
MAX_ARTWORK_BYTES = 2 * 1024 * 1024
EDITABLE_TAGS = {
    "track": {"title", "artist", "album", "albumartist", "genre", "date", "tracknumber", "discnumber"},
    "album": {"album", "albumartist", "genre", "date"},
    "artist": {"artist", "genre"},
}
ENDPOINTS = {"track": ("getSong", "song", "title"), "album": ("getAlbum", "album", "name"),
             "artist": ("getArtist", "artist", "name")}


def read_artwork(encoded):
    if encoded is None:
        return None
    try:
        data = base64.b64decode(encoded, validate=True)
        if len(data) > MAX_ARTWORK_BYTES:
            raise ValueError
        with Image.open(BytesIO(data), formats=["JPEG"]) as image:
            if max(image.size) > 1600:
                raise ValueError
            image.load()
        return data
    except (ValueError, TypeError, OSError, Image.DecompressionBombError) as error:
        raise LibraryError("Choose a JPEG image up to 1600 pixels and 2 MB.") from error


def embed_artwork(path, data):
    audio = File(path)
    if isinstance(audio, FLAC):
        pictures = [picture for picture in audio.pictures if picture.type != 3]
        audio.clear_pictures()
        for picture in pictures:
            audio.add_picture(picture)
        cover = Picture()
        cover.type, cover.mime, cover.data = 3, "image/jpeg", data
        audio.add_picture(cover)
    elif isinstance(audio, MP3):
        if audio.tags is None:
            audio.add_tags()
        for picture in audio.tags.getall("APIC"):
            if picture.type == 3:
                del audio.tags[picture.HashKey]
        description = "Front cover"
        while f"APIC:{description}" in audio.tags:
            description += " "
        audio.tags.add(APIC(mime="image/jpeg", type=3, desc=description, data=data))
    elif isinstance(audio, MP4):
        if audio.tags is None:
            audio.add_tags()
        audio.tags["covr"] = [MP4Cover(data, imageformat=MP4Cover.FORMAT_JPEG)]
    else:
        raise LibraryError("Artwork replacement supports FLAC, MP3 and M4A files.")
    audio.save()


ARTIST_TAGS = ("artist", "albumartist", "artists", "albumartists")
for tag in ARTIST_TAGS[2:]:
    EasyID3.RegisterTXXXKey(tag, tag.upper())
    EasyMP4Tags.RegisterFreeformKey(tag, tag.upper())


class LibraryError(Exception):
    pass


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class Library:
    def __init__(self, upstream, music, recovery, artist_images=None, recovery_days=30):
        self.recovery_days = recovery_days
        self.upstream = upstream.rstrip("/")
        self.music = music.resolve(strict=True)
        self.recovery = recovery.resolve()
        if self.recovery.is_relative_to(self.music) or self.music.is_relative_to(self.recovery):
            raise ValueError("Music and recovery must be separate directories.")
        self.recovery.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.artist_images = artist_images.resolve(strict=True) if artist_images else None
        if self.artist_images and (not self.artist_images.is_dir()
                                   or self.artist_images.stat().st_dev != self.recovery.stat().st_dev):
            raise ValueError("The artist images directory and recovery must be on the same filesystem.")
        self.opener = build_opener(NoRedirect())

    def purge_expired_recovery(self, now=None):
        if not self.recovery_days:
            return
        cutoff = (time.time() if now is None else now) - self.recovery_days * SECONDS_PER_DAY
        for operation in self.recovery.iterdir():
            if not RECOVERY_OPERATION.fullmatch(operation.name) or operation.is_symlink():
                continue
            try:
                if not operation.is_dir():
                    continue
                marker = (operation / RECOVERY_MARKER).lstat()
                if stat.S_ISREG(marker.st_mode) and marker.st_mtime <= cutoff:
                    shutil.rmtree(operation)
                    logging.info("Purged expired SoundBase recovery operation %s", operation.name)
            except FileNotFoundError:
                continue
            except OSError:
                logging.exception("Could not purge recovery operation %s", operation.name)

    def api(self, auth, endpoint, **params):
        request = Request(
            f"{self.upstream}/rest/{endpoint}",
            data=urlencode(dict(auth, **params, v="1.16.1", c="SoundBase", f="json")).encode(),
        )
        try:
            with self.opener.open(request, timeout=10) as response:
                payload = json.load(response)["subsonic-response"]
        except (OSError, ValueError, KeyError) as error:
            raise LibraryError("Could not contact Navidrome.") from error
        if payload.get("status") != "ok":
            raise LibraryError("Navidrome rejected the request.")
        return payload

    def item(self, auth, kind, item_id, expected_name=None):
        endpoint, key, name_key = ENDPOINTS[kind]
        item = self.api(auth, endpoint, id=item_id).get(key, {})
        if item.get("id") != item_id or (expected_name is not None and item.get(name_key) != expected_name):
            raise LibraryError(f"The {kind} has changed. Reopen it and try again.")
        return item

    def album_tracks(self, album):
        songs = album.get("song") or []
        if not songs or len(songs) != album.get("songCount", len(songs)):
            raise LibraryError("Navidrome did not return the complete album.")
        return songs

    def targets(self, auth, kind, item, removing=False):
        if kind == "track":
            return [item]
        if kind == "album":
            return self.album_tracks(item)
        songs = {}
        for entry in item.get("album", []):
            album = self.item(auth, "album", entry["id"])
            if removing:
                artist_ids = {artist.get("id") for artist in album.get("artists") or []}
                if not artist_ids:
                    artist_ids = {album.get("artistId")}
                if artist_ids != {item["id"]}:
                    continue
            for song in self.album_tracks(album):
                songs[song["id"]] = song
        if not songs:
            raise LibraryError("No tracks match this selection.")
        return songs.values()

    def path(self, song):
        source = Path(song.get("path") or "")
        if not source.is_absolute():
            raise LibraryError("Enable real paths for the SoundBase player in Navidrome.")
        path = source.resolve()
        if (source != path or not path.is_relative_to(self.music) or not path.is_file()
                or path.stat().st_size != song.get("size")):
            raise LibraryError("A track could not be matched to a file in the configured music folder.")
        if path.stat().st_dev != self.recovery.stat().st_dev:
            raise LibraryError("Music and recovery must be on the same filesystem.")
        return path

    def rename_file(self, item, name):
        source = self.path(item)
        if (not isinstance(name, str) or not name or name != name.strip()
                or name.endswith(".") or name.startswith(".")
                or any(ord(char) < 32 or char in '/\\:*?"<>|' for char in name)
                or len((name + source.suffix).encode()) > 255):
            raise LibraryError("Enter a valid filename without the extension.")
        destination = source.with_name(name + source.suffix)
        try:
            os.link(source, destination)
        except FileExistsError as error:
            raise LibraryError("A file with that name already exists.") from error
        try:
            source.unlink()
        except OSError:
            destination.unlink()
            raise

    def remove(self, auth, kind, item):
        paths = dict.fromkeys(self.path(song) for song in self.targets(auth, kind, item, removing=True))
        operation = Path(tempfile.mkdtemp(prefix=f"removed-{kind}-", dir=self.recovery))
        moved = []
        try:
            for path in paths:
                destination = operation / path.relative_to(self.music)
                destination.parent.mkdir(parents=True, exist_ok=True)
                path.rename(destination)
                moved.append((path, destination))
            (operation / RECOVERY_MARKER).touch(exist_ok=False)
        except OSError as error:
            self.rollback(moved, operation)
            raise LibraryError("Could not move the files. Completed moves were reverted.") from error
        return len(moved)

    def edit(self, auth, kind, item, tags, artwork):
        songs = self.targets(auth, kind, item) if tags or kind != "artist" else []
        paths = dict.fromkeys(self.path(song) for song in songs)
        operation = Path(tempfile.mkdtemp(prefix=f"{kind}-edit-", dir=self.recovery))
        staged = []
        committed = []
        try:
            for index, path in enumerate(paths):
                audio = File(path, easy=True) if tags else None
                if tags and audio is None:
                    raise LibraryError("A track has an unsupported tag format. No changes were saved.")
                changes = {key: [value] for key, value in tags.items()}
                if kind == "artist":
                    name = item["name"]
                    matches = {key: audio.get(key, []) for key in ARTIST_TAGS}
                    matches = {key: values for key, values in matches.items() if name in values}
                    if not matches:
                        continue
                    changes.pop("artist", None)
                    if "artist" in tags:
                        changes.update({key: [tags["artist"] if value == name else value for value in values]
                                        for key, values in matches.items()})
                else:
                    for singular, plural in zip(ARTIST_TAGS, ARTIST_TAGS[2:]):
                        if singular in changes and audio.get(plural):
                            changes[plural] = changes[singular]
                if not changes and artwork is None:
                    continue
                edited = operation / f"{index}{path.suffix}"
                shutil.copy2(path, edited)
                if changes:
                    copy = File(edited, easy=True)
                    if copy.tags is None:
                        copy.add_tags()
                    for key, values in changes.items():
                        copy[key] = values
                    copy.save()
                if artwork is not None and kind != "artist":
                    embed_artwork(edited, artwork)
                staged.append((path, edited, operation / "originals" / path.relative_to(self.music)))
            if kind == "artist" and tags and not staged:
                raise LibraryError("No exact Artist or Album Artist tags matched this name.")
            if kind == "artist" and artwork is not None:
                destination = self.artist_image_path(item, tags.get("artist"))
                edited = operation / "artist.jpg"
                edited.write_bytes(artwork)
                staged.append((destination, edited, operation / "original-artist.jpg"))
            for path, edited, backup in staged:
                previous = None
                if path.exists():
                    backup.parent.mkdir(parents=True, exist_ok=True)
                    os.link(path, backup)
                    previous = backup
                edited.replace(path)
                committed.append((path, previous))
            (operation / RECOVERY_MARKER).touch(exist_ok=False)
        except Exception as error:
            self.rollback(committed, operation)
            if isinstance(error, LibraryError):
                raise
            raise LibraryError("Could not save the changes. Completed edits were reverted.") from error
        return len(committed)

    def artist_image_path(self, artist, new_name):
        if self.artist_images is None:
            raise LibraryError("Artist artwork requires an artist image folder on the server.")
        name = artist.get("musicBrainzId") or new_name or artist["name"]
        if any(char in name for char in '/\\:*?"<>|') or name in (".", ".."):
            raise LibraryError("This artist name cannot be used as an image filename.")
        path = self.artist_images / f"{name}.jpg"
        if path.is_symlink() or (path.exists() and not path.is_file()):
            raise LibraryError("The artist image path is unavailable.")
        return path

    @staticmethod
    def rollback(moved, operation):
        try:
            for path, backup in reversed(moved):
                if backup is None:
                    path.unlink()
                else:
                    backup.replace(path)
        except OSError as error:
            raise LibraryError("Automatic recovery failed. Check the server’s recovery folder.") from error
        shutil.rmtree(operation, ignore_errors=True)


class Handler(BaseHTTPRequestHandler):
    timeout = 10

    def do_POST(self):
        prefix, _, action = self.path.rpartition("/")
        if prefix != "/soundbase-library/v1" or action not in ("status", "rename-artist", "remove-album", "edit", "remove", "rename-file"):
            return self.reply(404, "Unknown library action.")
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if self.headers.get_content_type() != "application/json" or not 0 < length <= MAX_ARTWORK_BYTES * 4 // 3 + 8192:
                return self.reply(400, "Expected a JSON request.")
            request = json.loads(self.rfile.read(length))
            auth = {key: request[key] for key in ("u", "t", "s")}
            if not all(isinstance(value, str) and value for value in auth.values()):
                return self.reply(400, "Invalid credentials.")
        except (ValueError, KeyError, TypeError, TimeoutError):
            return self.reply(400, "Invalid library request.")

        library = self.server.library
        try:
            user = library.api(auth, "getUser", username=auth["u"]).get("user", {})
            if user.get("adminRole") is not True or user.get("username") != auth["u"]:
                return self.reply(403, "Library changes require a Navidrome administrator.")
            if action == "status":
                return self.reply(200, "SoundBase library management", version=1, editor=True, artistArtwork=library.artist_images is not None, recoveryDays=library.recovery_days)
            item_id = request.get("id")
            name = request.get("name")
            if not all(isinstance(value, str) and value.strip() for value in (item_id, name)):
                return self.reply(400, "Missing track, album or artist.")
            kind = {"rename-artist": "artist", "remove-album": "album"}.get(action, request.get("kind"))
            if not isinstance(kind, str) or kind not in ENDPOINTS:
                return self.reply(400, "Unknown library item.")
            item = library.item(auth, kind, item_id, name)
            if action == "rename-file":
                if kind != "track":
                    return self.reply(400, "Select a track to rename its file.")
                library.rename_file(item, request.get("filename"))
                message = "Renamed the audio file."
            elif action in ("remove", "remove-album"):
                count = library.remove(auth, kind, item)
                message = (f"Moved {count} tracks to the server’s recovery folder. "
                           "Navidrome may keep missing entries visible to administrators.")
            else:
                raw_tags = request.get("tags", {}) if action == "edit" else {"artist": request.get("newName")}
                if not isinstance(raw_tags, dict):
                    return self.reply(400, "Invalid tags.")
                tags = {}
                for key, value in raw_tags.items():
                    if (key not in EDITABLE_TAGS[kind] or not isinstance(value, str)
                            or not 0 < len(value.strip()) <= 255 or any(ord(ch) < 32 for ch in value)):
                        return self.reply(400, "A tag value is invalid.")
                    tags[key] = value.strip()
                for key in ("tracknumber", "discnumber"):
                    if key in tags and (not tags[key].isascii() or not tags[key].isdigit()
                                        or not 0 < int(tags[key]) <= 9999):
                        return self.reply(400, "Track and disc numbers must be between 1 and 9999.")
                artwork = read_artwork(request.get("artwork"))
                if not tags and artwork is None:
                    return self.reply(400, "Choose a change to save.")
                count = library.edit(auth, kind, item, tags, artwork)
                message = f"Updated {count} files."
            if action != "rename-file" and library.recovery_days:
                message += f" Recovery files are kept for {library.recovery_days} days."
            try:
                library.api(auth, "startScan")
            except LibraryError:
                return self.reply(200, f"{message} Start a scan in Navidrome to update the library.")
            return self.reply(200, f"{message} The library updates when Navidrome finishes scanning.")
        except LibraryError as error:
            return self.reply(409, str(error))
        except OSError:
            return self.reply(500, "The server could not access the music or recovery folder.")

    def reply(self, status, message, **fields):
        data = json.dumps(dict(fields, message=message)).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class LibraryServer(HTTPServer):
    next_recovery_check = 0

    def service_actions(self):
        now = time.monotonic()
        if now >= self.next_recovery_check:
            self.next_recovery_check = now + 3600
            try:
                self.library.purge_expired_recovery()
            except OSError:
                logging.exception("Could not check the SoundBase recovery folder")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--navidrome", default="http://127.0.0.1:4533")
    parser.add_argument("--music", type=Path, required=True)
    parser.add_argument("--recovery", type=Path, required=True)
    parser.add_argument("--port", type=int, default=4534)
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--recovery-days", type=int, default=30,
                        help="Days to keep recovery files (0 disables automatic cleanup)")
    parser.add_argument("--artist-images", type=Path)
    args = parser.parse_args()
    if args.recovery_days < 0:
        parser.error("--recovery-days must be zero or positive")
    logging.basicConfig(level=logging.INFO)
    server = LibraryServer((args.bind, args.port), Handler)
    server.library = Library(args.navidrome, args.music, args.recovery, args.artist_images, args.recovery_days)
    server.serve_forever()


if __name__ == "__main__":
    main()
