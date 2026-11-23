#!/usr/bin/env python3
"""Writes the AltStore / SideStore source (source.json) for a Kestrel build.

Usage: altstore-source.py VERSION BUILD IPA DOWNLOAD_URL NOTES_FILE OUT
The source lists one version: the newest build (AltStore offers it as an update when its
version and build number go up).
"""
import datetime
import json
import os
import sys

version, build, ipa, url, notes_file, out = sys.argv[1:7]
repo = os.environ.get("GITHUB_REPOSITORY", "westernpluto/Kestrel")
raw = f"https://raw.githubusercontent.com/{repo}/{os.environ.get('GITHUB_SHA', 'testing')}"
with open(notes_file, encoding="utf-8") as f:
    notes = f.read().strip() or "Latest build."

source = {
    "name": "Kestrel",
    "identifier": "com.kestrel.source",
    "subtitle": "Twitch, low latency, no ads",
    "description": "Kestrel: a Twitch player for iPhone and iPad with its own low-latency engine, chat and recordings.",
    "iconURL": f"{raw}/Resources/AppIcon-1024.png",
    "website": f"https://github.com/{repo}",
    "tintColor": "#1FB5A6",
    "apps": [
        {
            "name": "Kestrel",
            "bundleIdentifier": "com.kestrel.player",
            "developerName": repo.split("/")[0],
            "subtitle": "Twitch, low latency, no ads",
            "localizedDescription": "A Twitch player with its own low-latency engine, ad handling, chat with 7TV/BTTV/FFZ emotes, recordings, Picture in Picture and an Apple Watch app.",
            "iconURL": f"{raw}/Resources/AppIcon-1024.png",
            "tintColor": "#1FB5A6",
            "category": "entertainment",
            "screenshots": [],
            "versions": [
                {
                    "version": version,
                    "buildVersion": build,
                    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "localizedDescription": notes,
                    "downloadURL": url,
                    "size": os.path.getsize(ipa),
                    "minOSVersion": "16.0",
                }
            ],
            "appPermissions": {"entitlements": [], "privacy": {}},
        }
    ],
    "news": [],
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(source, f, indent=2)
