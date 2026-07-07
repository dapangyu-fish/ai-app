#!/usr/bin/env python3
"""Prepare Contra assets for the JSON-App port.
- sprite strips per animation (player 8, enemies 2, fire 2)
- contra.tmx: single tileset, typed entity objects, enemies snapped to ground
- tiles_out.tsx rewritten to sibling tiles_out.png
- audio: ogg via ffmpeg if present, else downsampled wav
Outputs to ~/contra/out/
"""
import os
import shutil
import subprocess
import xml.etree.ElementTree as ET
from PIL import Image

BASE = os.path.expanduser("~/contra")
OUT = os.path.join(BASE, "out")
G = os.path.join(BASE, "graphics")
for sub in ("sprites", "tiles", "sky", "audio"):
    os.makedirs(os.path.join(OUT, sub), exist_ok=True)


def strip(src_dir, dst, flip=False):
    files = sorted(os.listdir(src_dir), key=lambda f: int(f.split(".")[0]))
    imgs = [Image.open(os.path.join(src_dir, f)).convert("RGBA") for f in files]
    if flip:
        imgs = [im.transpose(Image.FLIP_LEFT_RIGHT) for im in imgs]
    w, h = imgs[0].size
    sheet = Image.new("RGBA", (w * len(imgs), h))
    for i, im in enumerate(imgs):
        assert im.size == (w, h)
        sheet.paste(im, (i * w, 0))
    sheet.save(dst)
    return len(imgs), w, h


specs = []
for anim in ("right", "left", "right_idle", "left_idle", "right_jump",
             "left_jump", "right_duck", "left_duck"):
    n, w, h = strip(f"{G}/player/{anim}", f"{OUT}/sprites/player_{anim}.png")
    specs.append(("player_" + anim, n, w, h))
for anim in ("right", "left"):
    n, w, h = strip(f"{G}/enemies/{anim}", f"{OUT}/sprites/enemy_{anim}.png")
    specs.append(("enemy_" + anim, n, w, h))
n, w, h = strip(f"{G}/fire", f"{OUT}/sprites/fire_right.png")
specs.append(("fire_right", n, w, h))
n, w, h = strip(f"{G}/fire", f"{OUT}/sprites/fire_left.png", flip=True)
specs.append(("fire_left", n, w, h))
for name, n, w, h in specs:
    print(f"strip {name}: {n} frames {w}x{h}")

# singles
for src, dst in (
    (f"{G}/bullet.png", f"{OUT}/sprites/bullet.png"),
    (f"{G}/health.png", f"{OUT}/sprites/health.png"),
    (f"{G}/platforms/p1.png", f"{OUT}/sprites/p1.png"),
    (f"{G}/platforms/p2.png", f"{OUT}/sprites/p2.png"),
    (f"{G}/sky/bg_sky.png", f"{OUT}/sky/bg_sky.png"),
    (f"{G}/sky/fg_sky.png", f"{OUT}/sky/fg_sky.png"),
    (f"{G}/tilesets/tiles_out.png", f"{OUT}/tiles/tiles_out.png"),
):
    shutil.copy(src, dst)

# ---- TMX rewrite -----------------------------------------------------------
tree = ET.parse(f"{BASE}/data/map.tmx")
root = tree.getroot()

# Level grid for enemy ground-snap
level_csv = None
for layer in root.findall("layer"):
    if layer.get("name") == "Level":
        level_csv = layer.find("data").text
cells = [int(v) for v in level_csv.replace("\n", "").split(",") if v.strip() != ""]
W = int(root.get("width")); H = int(root.get("height"))
assert len(cells) == W * H

def solid(col, row):
    if 0 <= col < W and 0 <= row < H:
        return cells[row * W + col] != 0
    return False

new = ET.Element("map", {k: root.get(k) for k in (
    "version", "orientation", "renderorder", "width", "height",
    "tilewidth", "tileheight", "infinite") if root.get(k)})
ET.SubElement(new, "tileset", {"firstgid": "1", "source": "tiles_out.tsx"})
maxgid = 0
for layer in root.findall("layer"):
    lyr = ET.SubElement(new, "layer", {k: layer.get(k) for k in (
        "id", "name", "width", "height")})
    data = ET.SubElement(lyr, "data", {"encoding": "csv"})
    data.text = layer.find("data").text
    maxgid = max(maxgid, max(int(v) for v in
                             layer.find("data").text.replace("\n", "").split(",")
                             if v.strip() != ""))
assert maxgid <= 325, f"tile gid {maxgid} outside tiles_out"

ents = ET.SubElement(new, "objectgroup", {"id": "7", "name": "Entities"})
enemy_positions = []
player_pos = None
for og in root.findall("objectgroup"):
    if og.get("name") != "Entities":
        continue
    for o in og.findall("object"):
        x = float(o.get("x")); y = float(o.get("y"))
        name = o.get("name")
        if name == "Player":
            player_pos = (round(x, 1), round(y, 1))
            ET.SubElement(ents, "object", {
                "id": o.get("id"), "name": "Player", "type": "Player",
                "x": str(round(x, 1)), "y": str(round(y, 1)),
                "width": "0", "height": "0"})
        elif name == "Enemy":
            # snap: enemy rect 96x112 topleft (x,y); midbottom -> tile top
            mx, my = x + 48, y + 112
            col, row = int(mx // 64), int(my // 64)
            ny = y
            if solid(col, row):
                ny = row * 64 - 112
            else:  # scan down a couple tiles (some floats sit just above)
                for r2 in (row + 1, row + 2):
                    if solid(col, r2):
                        ny = r2 * 64 - 112
                        break
            enemy_positions.append((round(x, 1), round(ny, 1)))
            ET.SubElement(ents, "object", {
                "id": o.get("id"), "name": "Enemy", "type": "Enemy",
                "x": str(round(x, 1)), "y": str(round(ny, 1)),
                "width": "0", "height": "0"})
ET.indent(new)
ET.ElementTree(new).write(f"{OUT}/tiles/contra.tmx", encoding="UTF-8",
                          xml_declaration=True)
print("player spawn:", player_pos)
print("enemies snapped:", len(enemy_positions))
for p in enemy_positions:
    print("   ", p)

# tsx: point image at sibling png
ts = ET.parse(f"{BASE}/data/tiles_out.tsx")
img = ts.getroot().find("image")
img.set("source", "tiles_out.png")
ts.write(f"{OUT}/tiles/tiles_out.tsx", encoding="UTF-8", xml_declaration=True)

# ---- audio -----------------------------------------------------------------
ff = shutil.which("ffmpeg")
if ff:
    subprocess.run([ff, "-y", "-loglevel", "error", "-i", f"{BASE}/audio/music.wav",
                    "-c:a", "libvorbis", "-q:a", "4", f"{OUT}/audio/music.ogg"],
                   check=True)
    print("music.ogg:", os.path.getsize(f"{OUT}/audio/music.ogg"))
else:
    import wave, audioop
    with wave.open(f"{BASE}/audio/music.wav", "rb") as r:
        params = r.getparams()
        frames = r.readframes(r.getnframes())
    mono = audioop.tomono(frames, params.sampwidth, 0.5, 0.5)
    conv, _ = audioop.ratecv(mono, params.sampwidth, 1, params.framerate, 22050, None)
    with wave.open(f"{OUT}/audio/music.wav", "wb") as wf:
        wf.setnchannels(1); wf.setsampwidth(params.sampwidth); wf.setframerate(22050)
        wf.writeframes(conv)
    print("music.wav (downsampled):", os.path.getsize(f"{OUT}/audio/music.wav"))
for f in ("bullet.wav", "hit.wav"):
    shutil.copy(f"{BASE}/audio/{f}", f"{OUT}/audio/{f}")
print("done")
