"""Maakt source.json: een SideStore/AltStore-bron zodat nieuwe versies als update in SideStore verschijnen.

Wordt in GitHub Actions aangeroepen na het bouwen; de uitkomst komt als bestand bij de Release.
Gebruik: python3 scripts/make_source.py <versie> <buildnummer> <pad/naar/PinFilter.ipa>
"""
import json
import os
import sys
from datetime import datetime, timezone

version, build, ipa = sys.argv[1], sys.argv[2], sys.argv[3]
repo = os.environ.get("GITHUB_REPOSITORY", "nielswiegerss-code/pinfilter")
base = f"https://github.com/{repo}"
icon = f"https://raw.githubusercontent.com/{repo}/main/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
download = f"{base}/releases/download/v{version}/PinFilter.ipa"
size = os.path.getsize(ipa)
date = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
description = "Pinterest schermvullend, zonder advertentie-pins."

source = {
    "name": "PinFilter",
    "identifier": "nl.niels.pinfilter.source",
    "sourceURL": f"{base}/releases/latest/download/source.json",
    "website": base,
    "iconURL": icon,
    "tintColor": "#1E6FA8",
    "apps": [{
        "name": "Pins",
        "bundleIdentifier": "nl.niels.pinfilter",
        "developerName": "Niels",
        "localizedDescription": description,
        "iconURL": icon,
        "tintColor": "#1E6FA8",
        "category": "lifestyle",
        "versions": [{
            "version": version,
            "buildVersion": build,
            "date": date,
            "downloadURL": download,
            "size": size,
            "minOSVersion": "17.0",
        }],
        # Oudere velden, voor SideStore-versies die 'versions' nog niet lezen
        "version": version,
        "versionDate": date,
        "downloadURL": download,
        "size": size,
        "appPermissions": {"entitlements": [], "privacy": {}},
    }],
    "news": [],
}

with open("source.json", "w", encoding="utf-8") as f:
    json.dump(source, f, indent=2, ensure_ascii=False)
print(json.dumps(source, indent=2, ensure_ascii=False))
