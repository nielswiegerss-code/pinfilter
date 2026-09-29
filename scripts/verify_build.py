"""Controleert de gebouwde .ipa en source.json in CI, vóórdat er iets gepubliceerd wordt.

Waarom: zonder Mac of iPad merkt niemand een verkeerd pakket. Deze controles laten de build rood worden
in plaats van een kapotte of niet-updatebare versie te publiceren. Er wordt niets gewijzigd.

Gebruik: python3 scripts/verify_build.py <PinFilter.ipa> <source.json> <versie> <buildnummer> [tag]
  tag: de git-tag (bijv. v2.0); laat weg bij een handmatige test-build zonder Release.
"""
import hashlib
import json
import os
import plistlib
import sys
import zipfile

ipa, source_path, version, build = sys.argv[1:5]
tag = sys.argv[5] if len(sys.argv) > 5 else ""

errors = []


def check(ok, message):
    print(("  ok     " if ok else "FOUT   ") + message)
    if not ok:
        errors.append(message)


# 1. De .ipa: Payload/PinFilter.app moet in de root staan en de Info.plist moet kloppen
with zipfile.ZipFile(ipa) as z:
    names = z.namelist()
    check(all(n.startswith("Payload/") for n in names), "alles in de .ipa staat onder Payload/")
    plist_name = "Payload/PinFilter.app/Info.plist"
    check(plist_name in names, plist_name + " aanwezig")
    plist = plistlib.loads(z.read(plist_name)) if plist_name in names else {}

check(plist.get("CFBundleIdentifier") == "nl.niels.pinfilter",
      f"CFBundleIdentifier = {plist.get('CFBundleIdentifier')!r} (moet nl.niels.pinfilter zijn)")
check(plist.get("CFBundleDisplayName") == "Pins",
      f"CFBundleDisplayName = {plist.get('CFBundleDisplayName')!r} (moet Pins zijn)")
check(plist.get("CFBundleShortVersionString") == version,
      f"CFBundleShortVersionString = {plist.get('CFBundleShortVersionString')!r} (moet {version} zijn)")
check(plist.get("CFBundleVersion") == build,
      f"CFBundleVersion = {plist.get('CFBundleVersion')!r} (moet {build} zijn)")
check("audio" in (plist.get("UIBackgroundModes") or []),
      f"UIBackgroundModes = {plist.get('UIBackgroundModes')!r} (moet audio bevatten)")

# 2. source.json moet bij precies deze .ipa horen (anders weigert of herhaalt SideStore de update)
with open(source_path, encoding="utf-8") as f:
    source = json.load(f)
app = source["apps"][0]
v = app["versions"][0]
check(app["bundleIdentifier"] == "nl.niels.pinfilter", "source.json: bundleIdentifier klopt")
check(v["version"] == plist.get("CFBundleShortVersionString"), "source.json: version = versie in de .ipa")
check(v["buildVersion"] == plist.get("CFBundleVersion"), "source.json: buildVersion = build in de .ipa")
check(v["size"] == os.path.getsize(ipa), "source.json: size = grootte van de .ipa")
with open(ipa, "rb") as f:
    check(v.get("sha256") in (None, hashlib.sha256(f.read()).hexdigest()), "source.json: sha256 klopt")
if tag:
    check(v["downloadURL"].endswith(f"/releases/download/{tag}/PinFilter.ipa"),
          f"source.json: downloadURL wijst naar de release van {tag}")
check(app["downloadURL"] == v["downloadURL"], "source.json: oude en nieuwe downloadURL zijn gelijk")

sys.exit(1 if errors else 0)
