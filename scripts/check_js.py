"""Controleert het JavaScript dat in de Swift-bestanden staat, vóór de (dure) macOS-build.

Waarom: de Swift-compiler kijkt niet in de scripts (Swift-raw-strings, #\"\"\" ... \"\"\"#). Een losse
komma of haakje betekent dat de WKUserScript op de iPad stilletjes niet werkt, en zonder Mac of iPad
merkt niemand dat. Dit script vangt dat in CI:

1. Het haalt elke raw string  #\"\"\" ... \"\"\"#  uit Sources/*.swift, zet hem in een functie en draait
   'node --check' (alleen syntaxis, er wordt niets uitgevoerd).
2. Het draait scripts/test_adfilter.js: een regressietest van het advertentiefilter (adFilterJS) in een
   node-vm met nagebootste browser-objecten.

Gebruik: python3 scripts/check_js.py [map met .swift-bestanden, standaard Sources]

Wat er niet-JavaScript kan zijn (CSS, HTML) en hoe je dat aangeeft
-----------------------------------------------------------------
- Strings die duidelijk CSS of HTML zijn worden automatisch overgeslagen (zie looks_like_css/html).
- Twijfel of foutalarm? Zet op de regel direct BOVEN de string een commentaar met 'not-js':
      // not-js
      let someCSS = #\"\"\"
  Dan wordt die string niet gecontroleerd.
- Heeft een script variabelen nodig die Swift er vóór plakt (zoals PF_APP_ZOOM voor columnsJS)?
  Dan komt PF_APP_ZOOM automatisch erbij; voor andere namen zet je boven de string:
      // check-js-prelude: const PF_ANDERE = 1;
- Gewone (niet-raw) Swift-strings met \\( ) worden niet gecontroleerd; gebruik voor scripts een raw string.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# Begin van een raw string: optionele tekst op dezelfde regel, dan #+""" en einde van de regel.
# Einde: een regel met alleen spaties + """ + evenveel #'s. Die inspringing bepaalt (zoals in Swift)
# hoeveel witruimte van elke regel af gaat.
RAW = re.compile(r'(?P<pre>[^\n]*?)(?P<hash>#+)"""[ \t]*\n(?P<body>.*?)\n(?P<cindent>[ \t]*)"""(?P=hash)', re.S)

# Vaste voorloop die Swift er vóór plakt (ColumnSetting.script): 'const PF_APP_ZOOM = ...;'
KNOWN_PRELUDE = {"PF_APP_ZOOM": "const PF_APP_ZOOM = 1;"}

HEADER = "(async function () {\n"  # async, zodat ook scripts met await gecontroleerd worden
HEADER_LINES = HEADER.count("\n")


def looks_like_css(text):
    body = re.sub(r"/\*.*?\*/", "", text, flags=re.S).strip()
    if not body or re.search(r"=>|\bfunction\b|\bconst\b|\blet\b|\bvar\b|\breturn\b|\(\s*\)\s*\(", body):
        return False
    # selector { eigenschap: waarde; } (eventueel @media/@keyframes met geneste blokken)
    return bool(re.match(r"^[@.#\w\[\]=\"'*>:,\s~+()-]+\{", body)) and ":" in body


def looks_like_html(text):
    return text.lstrip().startswith("<")


def dedent(body, cindent):
    out = []
    for line in body.split("\n"):
        out.append(line[len(cindent):] if line.startswith(cindent) else line.lstrip(" \t") if not line.strip() else line)
    return "\n".join(out)


def extract(path):
    with open(path, encoding="utf-8") as f:
        src = f.read()
    for m in RAW.finditer(src):
        line_no = src.count("\n", 0, m.start("hash")) + 1
        pre = m.group("pre")
        name_m = re.search(r"\b(?:let|var)\s+(\w+)", pre)
        name = name_m.group(1) if name_m else "(naamloos)"
        lines_before = src[: m.start("pre")].split("\n")
        # de regel(s) boven de string: hierin kunnen markers staan (de laatste regel is de begin van 'pre')
        prev = [l for l in lines_before[:-1] if l.strip()][-2:]
        marker_text = "\n".join(prev)
        body = dedent(m.group("body"), m.group("cindent"))
        # Swift-interpolatie \#( ... ) in een raw string: vervang door een neutrale waarde
        body = re.sub(r"\\#\([^)]*\)", "0", body)
        yield {
            "file": os.path.basename(path), "line": line_no + 1, "name": name,
            "body": body, "markers": marker_text,
        }


def build_source(item):
    body, prelude = item["body"], []
    for var, decl in KNOWN_PRELUDE.items():
        if var in body and not re.search(r"\b(?:const|let|var)\s+" + var + r"\b", body):
            prelude.append(decl)
    for m in re.finditer(r"check-js-prelude:\s*(.+)", item["markers"]):
        prelude.append(m.group(1).strip())
    pre = "".join(p + "\n" for p in prelude)
    return HEADER + pre + body + "\n})\n", HEADER_LINES + len(prelude)


def main():
    sys.stdout.reconfigure(line_buffering=True)  # volgorde met de uitvoer van node behouden
    src_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "Sources")
    node = shutil.which("node")
    if not node:
        print("FOUT: node niet gevonden (nodig voor 'node --check')")
        return 1

    items = []
    for fn in sorted(os.listdir(src_dir)):
        if fn.endswith(".swift"):
            items.extend(extract(os.path.join(src_dir, fn)))
    if not items:
        print("FOUT: geen enkele raw string gevonden; is de regex nog goed?")
        return 1

    failures, checked, adfilter = 0, 0, None
    tmp = tempfile.mkdtemp(prefix="pfjs-")
    try:
        for i, it in enumerate(items):
            label = f"{it['file']}:{it['line']} {it['name']}"
            if "not-js" in it["markers"]:
                print(f"  overgeslagen (not-js)  {label}")
                continue
            if looks_like_html(it["body"]) or looks_like_css(it["body"]):
                print(f"  overgeslagen (css/html) {label}")
                continue
            code, offset = build_source(it)
            path = os.path.join(tmp, f"s{i}.js")
            with open(path, "w", encoding="utf-8", newline="\n") as f:
                f.write(code)
            r = subprocess.run([node, "--check", path], capture_output=True, text=True)
            if r.returncode != 0:
                failures += 1
                err = r.stderr.strip()
                # regelnummer in de tijdelijke file terugrekenen naar de Swift-regel
                m = re.search(r"s%d\.js:(\d+)" % i, err)
                where = f" (Swift-regel ca. {it['line'] + int(m.group(1)) - offset - 1})" if m else ""
                print(f"FOUT   {label}{where}\n{err}\n")
            else:
                checked += 1
                print(f"  ok     {label}")
            if it["name"] == "adFilterJS":
                adfilter = os.path.join(tmp, f"adfilter.js")
                with open(adfilter, "w", encoding="utf-8", newline="\n") as f:
                    f.write(it["body"])

        print(f"\nSyntaxis: {checked} scripts ok, {failures} met fouten")

        if adfilter is None:
            print("FOUT: adFilterJS niet gevonden in Sources/ (regressietest kan niet draaien)")
            return 1
        print("\nRegressietest advertentiefilter:")
        r = subprocess.run([node, os.path.join(HERE, "test_adfilter.js"), adfilter])
        if r.returncode != 0:
            failures += 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
