#!/usr/bin/env python3
"""super-mario-python level JSON  →  our TMX object-group draft.

Converts the open-source grid level data from mx0c/super-mario-python into a TMX
that follows demo_mario_full's schema (see docs/mario-levels.md): object groups
grounds / brick blocks / question blocks / enemies, with the right object `type`s.

This is a DRAFT: it maps the grid mechanically. You still must, in Tiled:
  1. add/point the `background` imagelayer at the level's strip PNG,
  2. add `collider` (pipes) + `flagpole` + `castle` object groups,
  3. calibrate coordinates against the actual background strip.

Usage:  smp_to_tmx.py <Level1-1.json> [--tile 16] > mario-1-1.tmx
Coordinate model: smp grid cell = --tile px (default 16). TMX tilewidth/height = 8,
so object px = grid * tile. Adjust --tile if your strip uses a different scale.
"""
from __future__ import annotations

import argparse
import json
import sys

# smp entity name -> (objectgroup name, object type or None; content-from-3rd-elem?)
ENTITY_MAP = {
    "CoinBox":   ("question blocks", "coin", False),
    "RandomBox": ("question blocks", None, True),   # 3rd elem is the content, e.g. "RedMushroom"
    "coinBrick": ("brick blocks", None, False),
    "coin":      ("question blocks", "coin", False),
    "Goomba":    ("enemies", "goomba", False),
    "Koopa":     ("enemies", "koopa", False),
}
CONTENT_MAP = {
    "RedMushroom": "red mushroom", "Mushroom": "red mushroom",
    "Flower": "mushroom flower", "Star": "star", "GreenMushroom": "green mushroom",
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("level")
    ap.add_argument("--tile", type=int, default=16)
    ap.add_argument("--tilesize", type=int, default=16, help="object w/h in px")
    args = ap.parse_args()
    data = json.load(open(args.level, encoding="utf-8"))
    L = data.get("level", data)
    T = args.tile
    sz = args.tilesize
    length = int(data.get("length", 0)) or max(
        (c[0] for grp in L.get("entities", {}).values() for c in grp), default=210)

    groups: dict[str, list[str]] = {}

    def add(group, x, y, typ):
        px, py = x * T, y * T
        attrs = f'x="{px}" y="{py}" width="{sz}" height="{sz}"'
        if typ:
            attrs = f'type="{typ}" ' + attrs
        groups.setdefault(group, []).append(f'  <object {attrs}/>')

    # ground fill rect -> grounds objectgroup as one strip per row range
    layers = L.get("layers", {})
    gl = layers.get("ground")
    if gl:
        x0, x1 = gl["x"]; y0, y1 = gl["y"]
        groups.setdefault("grounds", []).append(
            f'  <object x="{x0*T}" y="{y0*T}" width="{(x1-x0)*T}" height="{(y1-y0+1)*T}"/>')

    for name, coords in L.get("entities", {}).items():
        spec = ENTITY_MAP.get(name)
        if not spec:
            continue
        grp, typ, has_content = spec
        for c in coords:
            t = typ
            if has_content and len(c) >= 3:
                t = CONTENT_MAP.get(str(c[2]), "coin")
            add(grp, int(c[0]), int(c[1]), t)

    # pipes -> collider
    for p in L.get("objects", {}).get("pipe", []):
        x, y = int(p[0]), int(p[1])
        h = int(p[2]) if len(p) > 2 else 2
        groups.setdefault("collider", []).append(
            f'  <object x="{x*T}" y="{y*T}" width="{2*T}" height="{h*T}"/>')

    width_tiles = (length * T) // 8
    out = ['<?xml version="1.0" encoding="UTF-8"?>']
    out.append(f'<map version="1.10" orientation="orthogonal" renderorder="right-down" '
               f'width="{width_tiles}" height="28" tilewidth="8" tileheight="8" infinite="0">')
    out.append(' <imagelayer id="1" name="background" visible="0">')
    out.append(f'  <image source="../images/mario/level_TODO.png" width="{length*T}" height="224"/>')
    out.append(' </imagelayer>')
    gid = 2
    for grp in ("grounds", "collider", "brick blocks", "question blocks", "enemies", "flagpole", "castle"):
        objs = groups.get(grp, [])
        out.append(f' <objectgroup id="{gid}" name="{grp}">')
        out.extend(objs)
        out.append(' </objectgroup>')
        gid += 1
    out.append('</map>')
    print("\n".join(out))
    print(f"# draft: {sum(len(v) for v in groups.values())} objects across "
          f"{len(groups)} groups; SET the background strip + calibrate in Tiled",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
