#!/usr/bin/env python3
"""Build a Mario level (background strip PNG + TMX) from a compact level JSON.

Self-contained pipeline for demo_mario_full's multi-level support (see
docs/mario-levels.md). Sprites are extracted at runtime from two reference
images — no binary assets live in the repo:
  --ref-strip  level_1.png from DaQinShgy/flutter_game (ground-truth overworld
               palette; strips we produce must be pixel-consistent with 1-1)
  --sheet      tiles.png from mx0c/super-mario-python (palette variants:
               underground blue, fortress gray — cells verified visually)

Coordinate model (calibrated against the working 1-1 strip + mario.tmx):
  strip is 224px tall; grid cell (c, r) sits at px (16*c, 8+16*r)  — note the
  8px vertical offset. Ground top = row 12 (y=200), floor band = 24px.
  TMX: tilewidth/height 8, width = length*2, height 28; object groups and
  object conventions copied 1:1 from the original mario.tmx (flagpole = 9 pole
  segments + finial + flag; koopa = 1x1 marker at x+8,y=201; castle flag at
  castle_px+33,y=120).

Usage:
  mario_level_build.py --ref-strip level_1.png --sheet tiles.png \
      build level.json --out-png out/level_2.png --out-tmx out/mario-1-2.tmx
Requires Pillow (run on the build host).
"""
from __future__ import annotations

import argparse
import json
import sys

from PIL import Image

SKY_OW = (107, 140, 255, 255)

# ---- sprite sources -------------------------------------------------------
# from the 1-1 strip: (name, cell_col, cell_row, w_cells, h_cells)
STRIP_SPRITES = [
    ("ground",     0, 12, 1, 1),
    ("stair",    134, 11, 1, 1),
    ("flagbase", 198, 11, 1, 1),
    ("pipe_head", 28, 10, 2, 1),
    ("pipe_body", 28, 11, 2, 1),
    ("bush_l",    11, 11, 1, 1),
    ("bush_m",    12, 11, 1, 1),
    ("bush_r",    15, 11, 1, 1),
    ("cloud_tl",  19,  1, 1, 1),
    ("cloud_tm",  20,  1, 1, 1),
    ("cloud_tr",  21,  1, 1, 1),
    ("cloud_bl",  19,  2, 1, 1),
    ("cloud_bm",  20,  2, 1, 1),
    ("cloud_br",  21,  2, 1, 1),
    ("hill_big",   0,  9, 5, 3),
    ("hill_small", 16, 10, 3, 2),
    ("castle",   202,  7, 5, 5),
]
# from the smp sheet (16px cells, raw palette): palette variants
SHEET_SPRITES = [
    ("ug_ground",   0, 2), ("ug_stair",   0, 3), ("ug_brick",   1, 2),
    ("gray_ground", 0, 4), ("gray_stair", 0, 5), ("gray_brick", 1, 4),
]
PALETTES = {  # palette -> (ground, stair, ceiling-brick) sprite names
    "overworld":   ("ground", "stair", "ground"),
    "underground": ("ug_ground", "ug_stair", "ug_brick"),
    "castle":      ("gray_ground", "gray_stair", "gray_brick"),
}


def cell_xy(c: int, r: int) -> tuple[int, int]:
    return 16 * c, 8 + 16 * r


def extract_sprites(ref_strip: str, sheet: str) -> dict[str, Image.Image]:
    strip = Image.open(ref_strip).convert("RGBA")
    sh = Image.open(sheet).convert("RGBA")
    lib: dict[str, Image.Image] = {"_refstrip": strip}
    for name, c, r, w, h in STRIP_SPRITES:
        x, y = cell_xy(c, r)
        lib[name] = strip.crop((x, y, x + 16 * w, y + 16 * h))
    for name, cx, cy in SHEET_SPRITES:
        cell = sh.crop((cx * 16, cy * 16, cx * 16 + 16, cy * 16 + 16))
        bg = Image.new("RGBA", (16, 16), (0, 0, 0, 255))  # sheet bg is transparent black
        bg.alpha_composite(cell)
        lib[name] = bg
    return lib


# ---- strip renderer -------------------------------------------------------

def paste(img, spr, x, y):
    img.alpha_composite(spr, (max(x, 0), max(y, 0)),
                        (max(-x, 0), max(-y, 0)))


def paste_cell(img, spr, c, r, dy=0):
    x, y = cell_xy(c, r)
    paste(img, spr, x, y + dy)


def render_strip(lv: dict, lib: dict) -> Image.Image:
    W = lv["length"] * 16
    sky = tuple(lv.get("sky", list(SKY_OW[:3]))) + (255,)
    img = Image.new("RGBA", (W, 224), sky)
    pal = PALETTES[lv.get("palette", "overworld")]
    ground, stair, ceil = (lib[n] for n in pal)

    # decor first (behind everything), in listed order — order handles overlaps
    for d in lv.get("decor", []):
        kind, args = d[0], d[1:]
        if kind == "hill_big":
            paste_cell(img, lib["hill_big"], args[0], 9)
        elif kind == "hill_small":
            paste_cell(img, lib["hill_small"], args[0], 10)
        elif kind == "bush":  # [x, mids]
            x, mids = args[0], args[1]
            paste_cell(img, lib["bush_l"], x, 11)
            for i in range(mids):
                paste_cell(img, lib["bush_m"], x + 1 + i, 11)
            paste_cell(img, lib["bush_r"], x + 1 + mids, 11)
        elif kind == "cloud":  # [x, mids, top_row, (dy_px)]
            x, mids, row = args[0], args[1], args[2]
            dy = args[3] if len(args) > 3 else 0
            for suf, rr in (("t", row), ("b", row + 1)):
                paste_cell(img, lib[f"cloud_{suf}l"], x, rr, dy)
                for i in range(mids):
                    paste_cell(img, lib[f"cloud_{suf}m"], x + 1 + i, rr, dy)
                paste_cell(img, lib[f"cloud_{suf}r"], x + 1 + mids, rr, dy)
        elif kind == "decal":  # [sx, sy, w, h, dx, dy] copied from ref strip
            sx, sy, w, h, dx, dyy = args
            paste(img, lib["_refstrip"].crop((sx, sy, sx + w, sy + h)), dx, dyy)

    # ground runs: row 12 full + row 13 top half (strip ends at 224)
    for a, b in lv.get("ground", []):
        for c in range(a, b):
            paste_cell(img, ground, c, 12)
            paste_cell(img, ground, c, 13)  # bottom-clipped to 8px by image edge
    # ceiling runs: rows -1..1 brick fill (top 40px, grid-aligned)
    for a, b in lv.get("ceiling", []):
        for c in range(a, b):
            for r in (-1, 0, 1):
                paste_cell(img, ceil, c, r)
    # stairs: [x, h, dir] pyramids of stair blocks rising from the ground
    for x, h, d in lv.get("stairs", []):
        for i in range(h):
            cols = range(x + i, x + h) if d == "up" else range(x, x + h - i)
            for c in cols:
                paste_cell(img, stair, c, 11 - i)
    # platforms: [x, row, w] floating rows of stair blocks
    for x, row, w in lv.get("platforms", []):
        for c in range(x, x + w):
            paste_cell(img, stair, c, row)
    # pipes: [x, top_row]
    for x, top in lv.get("pipes", []):
        paste_cell(img, lib["pipe_head"], x, top)
        for r in range(top + 1, 12):
            paste_cell(img, lib["pipe_body"], x, r)
    # flag base + castle
    if "flag" in lv:
        paste_cell(img, lib["flagbase"], lv["flag"], 11)
    if "castle" in lv:
        paste_cell(img, lib["castle"], lv["castle"], 7)
    # post decals: hand-authored strip quirks copied verbatim from the ref strip,
    # drawn over everything (used by the 1-1 reproduction proof; see docs)
    for sx, sy, w, h, dx, dy in lv.get("decor_post", []):
        paste(img, lib["_refstrip"].crop((sx, sy, sx + w, sy + h)), dx, dy)
    return img


# ---- TMX emitter ----------------------------------------------------------

def emit_tmx(lv: dict, png_name: str) -> str:
    W = lv["length"] * 16
    objs: dict[str, list[str]] = {g: [] for g in (
        "castle", "flagpole", "enemies", "question blocks",
        "grounds", "brick blocks", "collider")}
    oid = [100]

    def obj(group, x, y, w, h, typ=None):
        oid[0] += 1
        t = f' type="{typ}"' if typ else ""
        objs[group].append(
            f'  <object id="{oid[0]}"{t} x="{x}" y="{y}" width="{w}" height="{h}"/>')

    for a, b in lv.get("ground", []):
        obj("grounds", 16 * a, 200, 16 * (b - a), 24)
    for a, b in lv.get("ceiling", []):
        obj("collider", 16 * a, 0, 16 * (b - a), 40)
    for x, h, d in lv.get("stairs", []):
        for i, c in enumerate(range(x, x + h)):
            hh = (i + 1) if d == "up" else (h - i)
            obj("collider", 16 * c, 200 - 16 * hh, 16, 16 * hh)
    for x, row, w in lv.get("platforms", []):
        obj("collider", 16 * x, 8 + 16 * row, 16 * w, 16)
    for x, top in lv.get("pipes", []):
        y = 8 + 16 * top
        obj("collider", 16 * x, y, 32, 200 - y)
    for x, row, typ in lv.get("blocks", {}).get("question", []):
        obj("question blocks", 16 * x, 8 + 16 * row, 16, 16, typ)
    for x, row in lv.get("blocks", {}).get("brick", []):
        obj("brick blocks", 16 * x, 8 + 16 * row, 16, 16)
    for x, row in lv.get("enemies", {}).get("goomba", []):
        obj("enemies", 16 * x, 8 + 16 * row, 16, 16, "goomba")
    for spec in lv.get("enemies", {}).get("koopa", []):
        x = spec[0] if isinstance(spec, list) else spec
        obj("enemies", 16 * x + 8, 201, 1, 1, "koopa")
    if "flag" in lv:
        f = 16 * lv["flag"]
        for r in range(2, 11):
            obj("flagpole", f + 7, 8 + 16 * r, 2, 16, "pole")
        obj("flagpole", f + 4, 32, 8, 8, "finial")
        obj("flagpole", f - 9, 40, 16, 16, "flag")
        obj("collider", f, 184, 16, 16)  # flag base block
    if "castle" in lv:
        obj("castle", 16 * lv["castle"] + 33, 120, 14, 14, "flag")

    out = ['<?xml version="1.0" encoding="UTF-8"?>',
           f'<map version="1.10" orientation="orthogonal" renderorder="right-down"'
           f' width="{lv["length"] * 2}" height="28" tilewidth="8" tileheight="8"'
           f' infinite="0">',
           ' <imagelayer id="1" name="background">',
           f'  <image source="../images/mario/{png_name}" width="{W}" height="224"/>',
           ' </imagelayer>']
    for gid, (name, lines) in enumerate(objs.items(), start=2):
        out.append(f' <objectgroup id="{gid}" name="{name}">')
        out.extend(lines)
        out.append(' </objectgroup>')
    out.append('</map>')
    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref-strip", required=True)
    ap.add_argument("--sheet", required=True)
    ap.add_argument("cmd", choices=["build"])
    ap.add_argument("level")
    ap.add_argument("--out-png", required=True)
    ap.add_argument("--out-tmx", required=True)
    args = ap.parse_args()

    lv = json.load(open(args.level, encoding="utf-8"))
    lib = extract_sprites(args.ref_strip, args.sheet)
    img = render_strip(lv, lib)
    img.save(args.out_png)
    png_name = args.out_png.rsplit("/", 1)[-1]
    with open(args.out_tmx, "w", encoding="utf-8") as f:
        f.write(emit_tmx(lv, png_name))
    n = sum(len(v) for v in lv.get("blocks", {}).values()) + \
        sum(len(v) for v in lv.get("enemies", {}).values())
    print(f"built {lv.get('id')}: strip {img.size[0]}x224 -> {args.out_png}; "
          f"tmx -> {args.out_tmx} ({n} blocks+enemies)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
