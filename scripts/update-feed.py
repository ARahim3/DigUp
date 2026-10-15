#!/usr/bin/env python3
"""Writes the update feed DigUp for Windows and Linux checks (plugins.updater.endpoints in shell/src-tauri/tauri.conf.json):
the newest release's version, notes, date, and for each platform the file to download and its signature.

    scripts/update-feed.py <folder> <updates/latest.json> [--notes notes.txt] [--tag v<version>]

<folder> holds the packages the release publishes with their .sig files, as the packages workflow makes them with the
signing key (DigUp_<version>_x64-setup.exe and DigUp_<version>_amd64.AppImage, each with a .sig): the Windows installer
and the AppImage update themselves; a .deb install is told of the update by the same entry and opens the release page.
Downloads point at GitHub Releases ($DOWNLOAD_BASE, by default https://github.com/ARahim3/DigUp/releases/download/<tag>/,
the tag v<version>). Notes are plain text, shown in the update's dialog. Publishing the packages and then the feed (in
that order: installed copies read the feed from the repository's main branch) is a separate step.
"""
import argparse
import datetime
import json
import os
import re
import sys
from pathlib import Path

# Platform keys the updater looks up: `{os}-{arch}` (a .deb install finds the AppImage's entry, reads only its version).
PLATFORMS = {
    "windows-x86_64": re.compile(r"^DigUp_(?P<version>[^_]+)_x64-setup\.exe$"),
    "linux-x86_64": re.compile(r"^DigUp_(?P<version>[^_]+)_amd64\.AppImage$"),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("folder")
    parser.add_argument("feed")
    parser.add_argument("--notes", help="a plain text file: what's new, for the update's dialog")
    parser.add_argument("--tag", help="the release's tag (default: v<version>)")
    args = parser.parse_args()

    folder = Path(args.folder)
    platforms, versions = {}, set()
    for key, pattern in PLATFORMS.items():
        found = [path for path in folder.iterdir() if pattern.match(path.name)]
        if len(found) != 1:
            sys.exit(f"update-feed: expected one {pattern.pattern} in {folder}, found {len(found)}")
        package = found[0]
        signature = package.with_name(package.name + ".sig")
        if not signature.is_file():
            sys.exit(f"update-feed: {package.name} has no {signature.name}: build the packages with the signing key")
        versions.add(pattern.match(package.name)["version"])
        platforms[key] = {"package": package.name, "signature": signature.read_text().strip()}
    if len(versions) != 1:
        sys.exit(f"update-feed: the packages are of different versions: {sorted(versions)}")
    version = versions.pop()
    tag = args.tag or f"v{version}"
    base = os.environ.get("DOWNLOAD_BASE", f"https://github.com/ARahim3/DigUp/releases/download/{tag}/")
    feed = {
        "version": version,
        "notes": Path(args.notes).read_text().strip() if args.notes else "",
        "pub_date": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "platforms": {key: {"signature": entry["signature"], "url": base + entry["package"]}
                      for key, entry in platforms.items()},
    }
    Path(args.feed).parent.mkdir(parents=True, exist_ok=True)
    Path(args.feed).write_text(json.dumps(feed, indent=2, ensure_ascii=False) + "\n")
    urls = ", ".join(f"{key} → {value['url']}" for key, value in feed["platforms"].items())
    print(f"{args.feed}: DigUp {version}, {urls}")


if __name__ == "__main__":
    main()
