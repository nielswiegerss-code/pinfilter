"""Maakt source.json: een SideStore/AltStore-bron zodat nieuwe versies als update in SideStore verschijnen.

Wordt in GitHub Actions aangeroepen na het bouwen; de uitkomst komt als bestand bij de Release.
Gebruik: python3 scripts/make_source.py <versie> <buildnummer> <pad/naar/PinFilter.ipa>

Wat SideStore in "Wat is nieuw" toont (localizedDescription van de versie), in deze volgorde:
1. scripts/release_notes.txt, als dat bestand bestaat (zet daar de tekst voor een grote release in
   en haal het bestand weg als de release uit is, anders blijft de tekst bij elke volgende versie staan);
2. anders de commit-tekst van de gebouwde commit (zonder Co-Authored-By-regels), max. 800 tekens.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

version, build, ipa = sys.argv[1], sys.argv[2], sys.argv[3]
if not re.fullmatch(r"[0-9]+(\.[0-9]+){1,2}", version):
    sys.exit(f"Ongeldige versie: {version!r} (verwacht 2.0 of 2.0.1)")
repo = os.environ.get("GITHUB_REPOSITORY", "nielswiegerss-code/pinfilter")
base = f"https://github.com/{repo}"
icon = f"https://raw.githubusercontent.com/{repo}/main/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"

# De download-URL komt uit de echte tag waarop gebouwd wordt, zodat hij altijd naar de Release wijst.
# Buiten een tag-build (handmatige test) bestaat er geen Release; dan is v<versie> een plaatsvervanger.
if os.environ.get("GITHUB_REF", "").startswith("refs/tags/"):
    tag = os.environ.get("GITHUB_REF_NAME", "")
    if tag != f"v{version}":
        sys.exit(f"Tag {tag!r} hoort niet bij versie v{version}")
else:
    tag = f"v{version}"
download = f"{base}/releases/download/{tag}/PinFilter.ipa"

size = os.path.getsize(ipa)
with open(ipa, "rb") as f:
    sha256 = hashlib.sha256(f.read()).hexdigest()  # dit is hetzelfde bestand als dat naar de Release gaat
date = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
description = "Pinterest schermvullend, zonder advertentie-pins."


def release_notes():
    here = os.path.dirname(os.path.abspath(__file__))
    try:
        with open(os.path.join(here, "release_notes.txt"), encoding="utf-8") as f:
            text = f.read().strip()
        if text:
            return text[:800]
    except OSError:
        pass
    try:
        text = subprocess.run(["git", "log", "-1", "--format=%B"], capture_output=True, text=True,
                              check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return ""
    lines = [l for l in text.splitlines() if not re.match(r"\s*(Co-Authored-By:|.*Generated with)", l, re.I)]
    return "\n".join(lines).strip()[:800]


notes = release_notes()

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
        "subtitle": "Pinterest zonder advertenties",
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
            "sha256": sha256,
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
if notes:
    source["apps"][0]["versions"][0]["localizedDescription"] = notes

with open("source.json", "w", encoding="utf-8") as f:
    json.dump(source, f, indent=2, ensure_ascii=False)
print(json.dumps(source, indent=2, ensure_ascii=False))
