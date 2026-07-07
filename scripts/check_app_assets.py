#!/usr/bin/env python3
"""Verify that EVERY asset a JSON-App references actually resolves (HTTP 200).

Catches the whole class of "migrated the game but dropped a file" bugs — including
the non-obvious ones that a naive `grep *.png` misses:
  - flame_game audio: base_url + each track/sound `src`
  - tiled_map entities: base_url + `source` (the .tmx), AND the tileset/image
    sources referenced *inside* the .tmx (resolved relative to the .tmx URL)
  - any bare http(s) URL string anywhere in the doc

Usage:
  python3 scripts/check_app_assets.py <app.json | app-url>   [--timeout N]
Exit 0 iff all referenced assets resolve; 1 if any is missing (prints them).
"""
from __future__ import annotations

import json
import re
import sys
import urllib.request
import urllib.parse
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor

URL_RE = re.compile(r'https?://[^\s"\'<>]+')
TIMEOUT = 15


def load(src: str) -> dict:
    if src.startswith("http"):
        with urllib.request.urlopen(src, timeout=TIMEOUT) as r:
            return json.loads(r.read())
    return json.loads(open(src, encoding="utf-8").read())


def head(url: str) -> int:
    try:
        req = urllib.request.Request(url, method="HEAD")
        return urllib.request.urlopen(req, timeout=TIMEOUT).getcode()
    except urllib.error.HTTPError as e:
        return e.code
    except Exception:
        return 0


def join(base: str, rel: str) -> str:
    if rel.startswith("http"):
        return rel
    return urllib.parse.urljoin(base if base.endswith("/") else base + "/", rel)


def find_flame_games(o, out):
    if isinstance(o, dict):
        if o.get("type") == "flame_game":
            out.append(o)
        for v in o.values():
            find_flame_games(v, out)
    elif isinstance(o, list):
        for v in o:
            find_flame_games(v, out)


def collect(doc: dict) -> tuple[set[str], list[str]]:
    """Return (asset_urls, notes)."""
    text = json.dumps(doc, ensure_ascii=False)
    urls = {u for u in URL_RE.findall(text) if not u.endswith('/')}  # skip base_url prefixes
    notes = []
    games = []
    find_flame_games(doc, games)
    for g in games:
        # audio: base_url + track/sound src
        a = g.get("audio") or {}
        base = a.get("base_url", "")
        for grp in ("tracks", "sounds"):
            for _, spec in (a.get(grp) or {}).items():
                src = (spec or {}).get("src")
                if src and base:
                    urls.add(join(base, src))
        # tiled_map entities: base_url + source, and the tmx's inner image refs
        def walk(o):
            if isinstance(o, dict):
                if o.get("kind") == "tiled_map" and o.get("source"):
                    tb = o.get("base_url", "")
                    tmx = join(tb, o["source"]) if tb else o["source"]
                    urls.add(tmx)
                    notes.append(f"tiled_map → {tmx}")
                    # fetch tmx, resolve inner <image source=..> / <tileset source=..>
                    try:
                        with urllib.request.urlopen(tmx, timeout=TIMEOUT) as r:
                            root = ET.fromstring(r.read())
                        for el in root.iter():
                            s = el.attrib.get("source")
                            if s and el.tag in ("image", "tileset"):
                                urls.add(join(tmx.rsplit("/", 1)[0] + "/", s))
                    except Exception as e:
                        notes.append(f"  (could not read tmx to check its images: {e})")
                for v in o.values():
                    walk(v)
            elif isinstance(o, list):
                for v in o:
                    walk(v)
        walk(g)
    return urls, notes


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    doc = load(sys.argv[1])
    urls, notes = collect(doc)
    for n in notes:
        print(n)
    urls = sorted(urls)
    with ThreadPoolExecutor(max_workers=8) as ex:
        codes = list(ex.map(head, urls))
    missing = [(u, c) for u, c in zip(urls, codes) if c != 200]
    print(f"\nchecked {len(urls)} distinct asset URLs")
    if not missing:
        print("✅ ALL assets resolve (HTTP 200)")
        return 0
    print(f"❌ {len(missing)} MISSING / unreachable:")
    for u, c in missing:
        print(f"   HTTP {c}: {u}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
