#!/usr/bin/env python3
"""Adds a release to DigUp's Sparkle appcast, the feed the app checks for updates (SUFeedURL in Info.plist).

    scripts/appcast.py <DigUp-x.y.z.dmg> <appcast.xml> [--notes notes.html] [--key-file private-key.txt]

Signs the DMG with Sparkle's sign_update (the EdDSA key in your login keychain, or --key-file) and puts a new item
first in <appcast.xml>, which is made if it isn't there: the version and build of the app it was made from
(build.noindex/DigUp.app), the oldest macOS it runs on, its download URL on GitHub Releases ($DOWNLOAD_BASE, by
default https://github.com/ARahim3/DigUp/releases/download/v<version>/), and the notes if given (an HTML fragment
such as <ul><li>…</li></ul>, shown in the update window). An item of the same build is replaced. Publishing the DMG
and the appcast is a separate step.
"""
import argparse
import email.utils
import os
import plistlib
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIGN_UPDATE = os.path.join(ROOT, ".build/artifacts/sparkle/Sparkle/bin/sign_update")
SKELETON = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>DigUp</title>
  </channel>
</rss>
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("dmg")
    parser.add_argument("appcast")
    parser.add_argument("--notes", help="an HTML fragment for the update window")
    parser.add_argument("--key-file", help="Sparkle's private key in a file instead of the keychain")
    parser.add_argument("--app", default=os.path.join(ROOT, "build.noindex/DigUp.app"))
    args = parser.parse_args()

    with open(os.path.join(args.app, "Contents/Info.plist"), "rb") as f:
        info = plistlib.load(f)
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    minimum = info.get("LSMinimumSystemVersion", "14.0")
    if not os.path.basename(args.dmg).endswith(f"-{version}.dmg"):
        sys.exit(f"{args.dmg} doesn't look like the DMG of {version} (the app in {args.app})")

    command = [SIGN_UPDATE] + (["--ed-key-file", args.key_file] if args.key_file else []) + [args.dmg]
    signature = subprocess.run(command, check=True, capture_output=True, text=True).stdout.strip()
    if not re.fullmatch(r'sparkle:edSignature="[^"]+" length="\d+"', signature):
        sys.exit(f"sign_update said: {signature}")

    base = os.environ.get("DOWNLOAD_BASE", f"https://github.com/ARahim3/DigUp/releases/download/v{version}/")
    url = base.rstrip("/") + "/" + os.path.basename(args.dmg)
    notes = ""
    if args.notes:
        with open(args.notes) as f:
            notes = f"\n      <description><![CDATA[{f.read().strip()}]]></description>"
    item = f"""    <item>
      <title>{version}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{minimum}</sparkle:minimumSystemVersion>{notes}
      <enclosure url="{url}" {signature} type="application/octet-stream"/>
    </item>
"""

    feed = open(args.appcast).read() if os.path.exists(args.appcast) else SKELETON
    # Running a release again replaces its item.
    feed = re.sub(r"    <item>\n(?:(?!</item>).)*?<sparkle:version>" + re.escape(build) + r"</sparkle:version>.*?</item>\n",
                  "", feed, flags=re.S)
    # Newest first: after the channel's title.
    feed = re.sub(r"(<channel>\n\s*<title>[^<]*</title>\n)", lambda m: m.group(1) + item, feed, count=1)
    with open(args.appcast, "w") as f:
        f.write(feed)
    print(f"{args.appcast}: {version} ({build}) → {url}")


if __name__ == "__main__":
    main()
