#!/usr/bin/env python3
"""MetalSlugClone (Unity) -> JSON-App asset pipeline.

Parses Unity .meta sprite slices (+pivots) and .anim sprite curves directly —
no hand-copied frame tables. Builds per-animation strips with a UNIFIED cell
per character group (pivot-anchored, so switching animations never jitters),
copies the Mission1 atlas + needed slice rects, emits a terrain TMX, and
collects audio. Output: ~/mslug/out + manifest.json (consumed by
scripts/build_demo_metalslug.py).

Run on the build host (needs Pillow): repo synced at ~/mslug/repo.
"""
import json
import os
import shutil
import glob
import re
import yaml  # PyYAML available on build host
from PIL import Image

REPO = os.path.expanduser("~/mslug/repo")
A = REPO + "/Assets"
OUT = os.path.expanduser("~/mslug/out")
for d in ("sprites", "atlas", "tiles", "audio"):
    os.makedirs(f"{OUT}/{d}", exist_ok=True)

# ---------------- meta / anim parsing ----------------

_meta_cache = {}


def load_meta(tex_path):
    if tex_path in _meta_cache:
        return _meta_cache[tex_path]
    raw = open(tex_path + ".meta", encoding="utf-8").read()
    y = yaml.safe_load(raw)
    ti = y["TextureImporter"]
    fid2name = {int(k): str(v) for k, v in (ti.get("fileIDToRecycleName") or {}).items()}
    slices = {}
    for s in (ti.get("spriteSheet", {}) or {}).get("sprites", []) or []:
        r = s["rect"]
        pv = s.get("pivot") or {"x": 0.5, "y": 0.5}
        if s.get("alignment", 0) == 0:
            pv = {"x": 0.5, "y": 0.5}
        slices[str(s["name"])] = {
            "rect": (int(r["x"]), int(r["y"]), int(r["width"]), int(r["height"])),
            "pivot": (float(pv["x"]), float(pv["y"])),
        }
    img = Image.open(tex_path).convert("RGBA")
    single = str(ti.get("spriteMode")) == "1"
    _meta_cache[tex_path] = (img, fid2name, slices, single)
    return _meta_cache[tex_path]


GUID2TEX = {}
for m in glob.glob(A + "/Sprites/**/*.meta", recursive=True):
    tex = m[:-5]
    if not re.search(r"\.(png|gif|jpg)$", tex, re.I):
        continue
    g = re.search(r"guid: ([0-9a-f]{32})", open(m, encoding="utf-8").read())
    if g:
        GUID2TEX[g.group(1)] = tex


def crop(tex, fid=None, name=None):
    """-> (PIL image, pivot(px from bottom-left)) for a slice or whole image."""
    img, fid2name, slices, single = load_meta(tex)
    if single or (fid == 21300000):
        return img, (img.size[0] / 2, img.size[1] / 2)
    if name is None:
        name = fid2name[int(fid)]
    s = slices[str(name)]
    x, y, w, h = s["rect"]
    top = img.size[1] - (y + h)  # Unity rect is bottom-left origin
    return img.crop((x, top, x + w, top + h)), (w * s["pivot"][0], h * s["pivot"][1])


def parse_anim(path):
    """-> (fps, loop, [(guid, fileID), ...] in keyframe time order)"""
    raw = open(path, encoding="utf-8").read()
    fps = float(re.search(r"m_SampleRate: ([0-9.]+)", raw).group(1))
    loop = re.search(r"m_LoopTime: (\d)", raw)
    loop = bool(int(loop.group(1))) if loop else False
    frames = []
    m = re.search(r"m_PPtrCurves:\n(.*?)(?=\n  m_[A-Z])", raw, re.S)
    if not m:
        return fps, loop, frames
    # first sprite curve only (multi-target clips like DoorBoat are split upstream)
    block = m.group(1)
    first = re.split(r"\n  - curve:", block)
    seg = first[0] if "- time:" in first[0] else ("\n  - curve:" + first[1] if len(first) > 1 else first[0])
    for kf in re.finditer(r"time: ([0-9.eE+-]+)\s*\n\s*value: \{fileID: (-?\d+), guid: ([0-9a-f]{32})", seg):
        frames.append((float(kf.group(1)), kf.group(3), int(kf.group(2))))
    frames.sort(key=lambda t: t[0])
    return fps, loop, [(g, f) for _, g, f in frames]


ANIM_DIR = A + "/Animations"


def find_anim(rel):
    p = f"{ANIM_DIR}/{rel}.anim"
    assert os.path.exists(p), p
    return p


# ---------------- strip building ----------------

GROUPS = {
    # group -> {our_anim_name: anim path rel Animations/}
    "marco_top": {
        "p_idle": "Marco/Top/Pistol/Normal/PistolIdle",
        "p_walk": "Marco/Top/Pistol/Normal/PistolWalking",
        "p_fire": "Marco/Top/Pistol/Fire/PistolFire",
        "p_up": "Marco/Top/Pistol/Normal/PistolUp",
        "p_fire_up": "Marco/Top/Pistol/Fire/PistolFireUp_Firing",
        "p_jump_up": "Marco/Top/Pistol/Jump/PistolJumpUp",
        "p_jump_down": "Marco/Top/Pistol/Jump/PistolJumpDown",
        "melee": "Marco/Top/Melee/Fire/MeleeAttack",
        "throw": "Marco/ThrowingGranate",
        "m_idle": "Marco/Top/MachineGun/Idle",
        "m_fire": "Marco/Top/MachineGun/Fire",
        "m_melee": "Marco/Top/MachineGun/Melee",
        "m_throw": "Marco/Top/MachineGun/ThrowingGranate",
    },
    "marco_body": {
        "idle": "Marco/Bottom/LegsIdle",
        "walk": "Marco/Bottom/LegsWalk",
        "jump": "Marco/Bottom/Jump/LegsJumpIdle",
        "jump_walk": "Marco/Bottom/Jump/LegsJumpWalking",
        "death": "Marco/Bottom/MarcoDeath",
        "c_idle": "Marco/Crouch/CrouchIdle",
        "c_walk": "Marco/Crouch/CrouchWalking",
        "c_fire": "Marco/Crouch/CrouchFire",
        "c_melee": "Marco/Crouch/ChrouchMeleeAttack",
        "c_throw": "Marco/Crouch/ChrouchThrowingGranate",
    },
    "soldier": {
        "idle": "Enemies/Soldier/SolderIdle",
        "walk": "Enemies/Soldier/Walking",
        "knife": "Enemies/Soldier/SolderKnife",
        "throw": "Enemies/Soldier/SolderGranate",
        "die": "Enemies/Soldier/SoldierDying",
    },
    "crab": {
        "idle": "Enemies/Crab/Idle",
        "walk": "Enemies/Crab/Walking",
        "attack": "Enemies/Crab/Attack",
        "die": "Enemies/Crab/Dying",
    },
    "van": {
        "idle": "Enemies/Van/VanIdle",
        "fire": "Enemies/Van/VanFiring",
        "die": "Enemies/Van/VanDying",
    },
    "vanbomb": {
        "fly": "Missions/Mission1/Van/bombFlyingDown",
        "boom": "Missions/Mission1/Van/bombExploding",
    },
    "boss1": {
        "walk": "Enemies/Boss/Boss1/Walking",
        "walk_weapon": "Enemies/Boss/Boss1/WalkingWeapon",
        "open_weapon": "Enemies/Boss/Boss1/OpenWeapon",
        "die": "Enemies/Boss/Boss1/Dying",
        "spawn": "Enemies/Boss/Boss1/Water/WaterOnSpawn",
    },
    "bossbomb": {
        "fly": "Enemies/Boss/Boss1/NormalBombFlying",
        "boom": "Enemies/Boss/Boss1/NormalBombExplosion",
        "heavy_fly": "Enemies/Boss/Boss1/BombFlying",
        "heavy_boom": "Enemies/Boss/Boss1/HeavyBombExplosion",
    },
    "grenade": {
        "fly": "GranateAndWeapons/FlyingGranate",
        "boom": "GranateAndWeapons/Explosion",
    },
    "sgrenade": {
        "fly": "GranateAndWeapons/SoldierGranateFlying",
        "boom": "GranateAndWeapons/SoldierGranateExplosion",
    },
    "zombie1": {
        "idle": "Enemies/Zombies/Zombie1/Idle",
        "walk": "Enemies/Zombies/Zombie1/Walking",
        "attack": "Enemies/Zombies/Zombie1/Attack",
        "die": "Enemies/Zombies/Dying",
        "vomit": "Enemies/Zombies/Vomit",
    },
    "zombie2": {
        "idle": "Enemies/Zombies/Zombie2/Idle",
        "walk": "Enemies/Zombies/Zombie2/Walking",
        "attack": "Enemies/Zombies/Zombie2/Attack",
        "die": "Enemies/Zombies/Dying",
        "vomit": "Enemies/Zombies/Vomit",
    },
    "zombie3": {
        "idle": "Enemies/Zombies/Zombie3/Idle",
        "walk": "Enemies/Zombies/Zombie3/Walking",
        "attack": "Enemies/Zombies/Zombie3/Attack",
        "die": "Enemies/Zombies/Dying",
        "vomit": "Enemies/Zombies/Vomit",
    },
    "heli": {
        "idle": "Enemies/Heli/Idle",
        "fire": "Enemies/Heli/Fire",
    },
    "maggot": {
        "idle": "Enemies/Maggot/Idle",
        "walk": "Enemies/Maggot/Walking",
        "die": "Enemies/Maggot/Dying",
    },
    "caterpillar": {
        "idle": "Enemies/Caterpillar/Idle",
        "walk": "Enemies/Caterpillar/Walking",
        "attack": "Enemies/Caterpillar/Attack",
        "die": "Enemies/Caterpillar/Dying",
    },
    "rebelvan": {
        "spawn": "Enemies/RebelVan/Spawning",
        "spawn_soldier": "Enemies/RebelVan/SpawningSoldier",
        "damaged": "Enemies/RebelVan/Damaged",
        "die": "Enemies/RebelVan/Exploding",
    },
    "boss2": {
        "attack": "Enemies/Boss/Boss2/Top/AttackAnimation",
        "circle": "Enemies/Boss/Boss2/Circle/CircleAnimation",
        "dead": "Enemies/Boss/Boss2/Bottom/OnDead",
    },
    "boss2rock": {
        "fall": "Enemies/Boss/Boss2/Rock/RockAnimation",
    },
    "boss3": {
        "attack1": "Enemies/Boss/Boss3/Attack1/Attack1",
        "firing1": "Enemies/Boss/Boss3/Attack1/Firing",
        "end1": "Enemies/Boss/Boss3/Attack1/EndAttack",
        "attack2": "Enemies/Boss/Boss3/Attack2/Attack2",
        "firing2": "Enemies/Boss/Boss3/Attack2/Firing2",
        "end2": "Enemies/Boss/Boss3/Attack2/EndAttack2",
        "die": "Enemies/Boss/Boss3/Dying/Dying",
    },
    "m2light": {"flash": "Missions/Mission2/LightAnimation"},
    "m3lightning": {"bolt": "Missions/Mission3/Boss/Lightning"},
    "fx_huge": {"boom": "Explosions/hugeExplosion"},
    "fx_boat": {"boom": "Explosions/Boat/boatExplosions"},
    "fx_bridge": {"boom": "Missions/Mission1/BridgeExplosion"},
    "marcoboat": {"sail": "Missions/Mission1/MarcoBoat",
                  "die": "Missions/Mission1/MarcoBoatDying"},
    "seawaves": {"wave": "Missions/Mission1/SeaWaves"},
}

# clips whose Animations/ folder layout differs — resolve by glob search
def locate(rel):
    p = f"{ANIM_DIR}/{rel}.anim"
    if os.path.exists(p):
        return p
    base = rel.split("/")[-1]
    hits = glob.glob(f"{ANIM_DIR}/**/{base}.anim", recursive=True)
    assert len(hits) == 1, (rel, hits)
    return hits[0]


MIRROR_GROUPS = {"marco_top", "marco_body", "soldier", "crab"}
manifest = {"groups": {}}
for group, clips in GROUPS.items():
    parsed = {}
    for name, rel in clips.items():
        fps, loop, frames = parse_anim(locate(rel))
        imgs = []
        for gguid, fid in frames:
            if fid == 0:
                imgs.append(None)  # null-sprite keyframe
                continue
            tex = GUID2TEX[gguid]
            if fid == 21300000 and not load_meta(tex)[3]:
                continue  # whole-texture placeholder keyframe on a sliced sheet
            imgs.append(crop(tex, fid=fid))
        imgs = [im for im in imgs if im is not None]
        assert imgs, (group, name)
        parsed[name] = (fps, loop, imgs)
    # unified cell across the group's frames (pivot-anchored)
    AX = max(max(p[0] for _, p in v[2]) for v in parsed.values())
    RT = max(max(im.size[0] - p[0] for im, p in v[2]) for v in parsed.values())
    PTY = max(max(im.size[1] - p[1] for im, p in v[2]) for v in parsed.values())
    BB = max(max(p[1] for im, p in v[2]) for v in parsed.values())
    cw, ch = int(AX + RT + 1), int(PTY + BB + 1)
    ginfo = {"cell": [cw, ch], "anchor": [round(AX, 1), round(PTY, 1)], "anims": {}}
    for name, (fps, loop, imgs) in parsed.items():
        sheet = Image.new("RGBA", (cw * len(imgs), ch), (0, 0, 0, 0))
        for i, (im, (px, py)) in enumerate(imgs):
            pty = im.size[1] - py
            sheet.paste(im, (int(i * cw + AX - px), int(PTY - pty)))
        f = f"{group}_{name}.png"
        sheet.save(f"{OUT}/sprites/{f}")
        ginfo["anims"][name] = {"file": f, "frames": len(imgs),
                                "fps": fps, "loop": loop}
        if group in MIRROR_GROUPS:
            msheet = Image.new("RGBA", sheet.size, (0, 0, 0, 0))
            for i in range(len(imgs)):
                cell = sheet.crop((i * cw, 0, (i + 1) * cw, ch))
                msheet.paste(cell.transpose(Image.FLIP_LEFT_RIGHT), (i * cw, 0))
            mf = f"{group}_{name}_l.png"
            msheet.save(f"{OUT}/sprites/{mf}")
            ginfo["anims"][name + "_l"] = {"file": mf, "frames": len(imgs),
                                           "fps": fps, "loop": loop}
    manifest["groups"][group] = ginfo
    print(f"group {group}: cell {cw}x{ch}, {len(parsed)} anims")

# ---------------- statics ----------------
statics = {}


def save_static(key, tex, fid=None, name=None):
    im, _ = crop(tex, fid=fid, name=name)
    f = f"st_{key}.png"
    im.save(f"{OUT}/sprites/{f}")
    statics[key] = {"file": f, "size": list(im.size)}


ITEMS = A + "/Sprites/Items/39080.png"
EXPL = A + "/Sprites/Explosions/EXPLOSIONSANDGRANATE.png"
save_static("bullet", A + "/Sprites/Characters/Marco/fire.png")
save_static("grenade_icon", EXPL, fid=21300052)
save_static("hmg", ITEMS, fid=21300328)
# collectible variants override m_Sprite on base prefab cf910b (H) — read overrides
for key, prefab in (("ammo", "Ammo Variant"), ("medkit", "MedKit Variant")):
    raw = open(f"{A}/Prefabs/Collectibles/{prefab}.prefab", encoding="utf-8").read()
    m = re.search(r"propertyPath: m_Sprite\n\s+value:\s*\n\s+objectReference: \{fileID: (-?\d+), guid: ([0-9a-f]{32})", raw)
    assert m, prefab
    save_static(key, GUID2TEX[m.group(2)], fid=int(m.group(1)))
UFO = A + "/Sprites/Characters/Enemies/Boss/Monoeyes/ufo.png"
save_static("b2line", UFO, name="line")
save_static("b2circle", UFO, name="circle_1")
SOLDAE = A + "/Sprites/Characters/Enemies/Boss/SolDae/Neo Geo NGCD - Metal Slug 3 - Sol Dae Rokker.png"
save_static("b3tower", SOLDAE, name="Neo Geo NGCD - Metal Slug 3 - Sol Dae Rokker_13")
save_static("b3tower_near", SOLDAE, name="Neo Geo NGCD - Metal Slug 3 - Sol Dae Rokker_11")
save_static("lifebar", A + "/Sprites/HUD/Lifebar.png")
save_static("lifebar_border", A + "/Sprites/HUD/LifebarBorder.png")

# ---------------- Mission2 atlas + Mission3 strip ----------------
FG2 = A + "/Sprites/Missions/Mission2/foreground.png"
shutil.copy(FG2, f"{OUT}/atlas/m2_foreground.png")
img2, _, slices2, _ = load_meta(FG2)
m2_atlas = {"file": "m2_foreground.png", "h": img2.size[1], "slices": {}}
for n in ("background_1", "background _2", "foreground_0", "foreground_1",
          "foreground_2", "foreground_3", "foreground_4", "lights_out_1"):
    r = slices2[n]["rect"]
    x, y, w, h = r
    m2_atlas["slices"][n] = [x, img2.size[1] - (y + h), w, h]
manifest["m2_atlas"] = m2_atlas

M3STRIP = A + "/Sprites/Missions/Mission3/Neo Geo NGCD - Metal Slug 3 - Mission 4-4B.png"
im3, _, s3, _ = load_meta(M3STRIP)
r = s3[[k for k in s3][0]]["rect"]
x, y, w, h = r
im3.crop((x, im3.size[1] - (y + h), x + w, im3.size[1] - y)).save(f"{OUT}/atlas/m3_strip.png")
manifest["m3_strip"] = {"file": "m3_strip.png", "w": w, "h": h}

# ---------------- Mission1 atlas + slice manifest ----------------
FG = A + "/Sprites/Missions/Mission1/foreground.png"
shutil.copy(FG, f"{OUT}/atlas/foreground.png")
img, fid2name, slices, _ = load_meta(FG)
need_names = ["foreground_0", "foreground_2", "foreground_2_end",
              "foreground_tower_1", "foreground_tower_single", "foreground_boat",
              "foreground_boat_1", "foreground_door_1", "foreground_sea_orange",
              "foreground_dead_fish", "foreground_sea", "foreground_sea_end_0",
              "boat_1", "foreground_1", "foreground_cloud_forest", "sea_waves_1"]
need_fids = [21300166, 21300072, 21300084, 21300076, 21300088, 21300092,
             21300074, 21300110, 21300126, 21300026]
atlas = {"file": "foreground.png", "h": img.size[1], "slices": {}}
for n in need_names:
    s = slices[n]
    x, y, w, h = s["rect"]
    atlas["slices"][n] = [x, img.size[1] - (y + h), w, h]  # top-left origin
for fid in need_fids:
    n = fid2name[fid]
    s = slices[str(n)]
    x, y, w, h = s["rect"]
    atlas["slices"][f"fid_{fid}"] = [x, img.size[1] - (y + h), w, h]
manifest["atlas"] = atlas

# ---------------- terrain TMX (from scene extraction; Unity u -> px x100, y-flip) ----
# world y_px = -y_u*100 + 0  (we set world origin so unity y=+1.4 -> px 0)
Y0 = 1.4  # unity y that maps to px y=0 (top of play space)


def P(xu, yu):
    return round(xu * 100, 1), round((Y0 - yu) * 100, 1)


WALK1 = [(-1.68,-0.69),(-1.41,-0.71),(2.6,-0.67),(3.51,-0.65),(4.12,-0.58),(5.88,-0.3),(6.79,-0.14),(7.01,-0.45),(7.4,-0.63),(8.06,-0.7),(8.28,-0.71),(8.28,-0.53),(8.28,-0.35),(9.03,-0.48),(9.56,-0.64),(10.32,-0.81),(11.61,-0.76),(12.43,-0.74),(13.27,-0.62),(14.25,-0.57)]
WALK2 = [(14.23,-0.56),(14.23,-0.25),(14.67,-0.11),(14.67,0.0),(14.85,0.06),(15.14,0.18),(15.3,0.31),(15.98,0.3),(16.29,0.25),(16.64,0.21),(17.05,0.18),(17.25,0.13),(18.29,0.04),(18.99,-0.05),(19.58,-0.11),(20.1,-0.2),(20.87,-0.31),(21.56,-0.43),(22.31,-0.48),(24.57,-0.46),(25.76,-0.44),(26.72,-0.21)]
BOAT_ROOF = [(13.31,0.61),(14.5,0.72)]
BOXES1 = [(17.3,0.52),(18.39,0.49)]
BOXES2 = [(19.89,0.19),(20.92,0.15)]
WATER1 = [(26.69,-1.16),(46.41,-1.08)]
WATER2 = [(45.89,-1.35),(52.46,-1.35)]

objs = []
oid = [1]


def rect(x, y, w, h, typ, name=None):
    oid[0] += 1
    nm = f' name="{name}"' if name else ""
    objs.append(f'  <object id="{oid[0]}"{nm} type="{typ}" x="{round(x,1)}" y="{round(y,1)}" width="{round(w,1)}" height="{round(h,1)}"/>')


def polyline_solid(pts, typ="Solid", step=12, quant=4):
    """sample surface, quantize tops to `quant` px, merge equal-top runs"""
    slabs = []
    for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
        (px1, py1), (px2, py2) = P(x1, y1), P(x2, y2)
        if px2 <= px1:
            continue
        n = max(1, int((px2 - px1) // step))
        for i in range(n):
            fx = px1 + (px2 - px1) * i / n
            fw = (px2 - px1) / n
            fy = py1 + (py2 - py1) * (i + 0.5) / n
            slabs.append((fx, fw, round(fy / quant) * quant))
    merged = []
    for fx, fw, top in slabs:
        if merged and merged[-1][2] == top and abs(merged[-1][0] + merged[-1][1] - fx) < 1:
            merged[-1][1] += fw
        else:
            merged.append([fx, fw, top])
    for fx, fw, top in merged:
        rect(fx, top, fw + 0.5, 60, typ)


polyline_solid(WALK1)
polyline_solid(WALK2)
polyline_solid(BOAT_ROOF, typ="Platform")
polyline_solid(BOXES1, typ="Platform")
polyline_solid(BOXES2, typ="Platform")
# start-water left wall + level walls
rect(-190, -50, 20, 400, "Solid")
# hazard water strips
for pts in (WATER1, WATER2):
    (px1, py1), (px2, py2) = P(pts[0][0], pts[0][1]), P(pts[1][0], pts[1][1])
    rect(px1, min(py1, py2), px2 - px1, 120, "Hazard")
# boss bridge: removable segments x 46.30..52.30 (0.30u each) at walk height y=-0.891+0.0? bridge top ~ -0.86
bridge_ids = []
bx = 46.30
seg = 0
while bx < 52.3:
    px, py = P(bx, -0.86)
    oid[0] += 1
    objs.append(f'  <object id="{oid[0]}" name="bridge_{seg}" type="Solid" x="{round(px,1)}" y="{round(py,1)}" width="30" height="60"/>')
    bridge_ids.append({"seg": seg, "oid": oid[0], "xu": round(bx, 2)})
    bx += 0.30
    seg += 1
manifest["bridge_objects"] = bridge_ids

def polyline_ceiling(pts, objs_list, oid_ref, quant=4, step=12):
    """roof: rects extending UP 60px from the polyline"""
    slabs = []
    for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
        (px1, py1), (px2, py2) = P(x1, y1), P(x2, y2)
        if px2 <= px1:
            continue
        n = max(1, int((px2 - px1) // step))
        for i in range(n):
            fx = px1 + (px2 - px1) * i / n
            fw = (px2 - px1) / n
            fy = py1 + (py2 - py1) * (i + 0.5) / n
            slabs.append((fx, fw, round(fy / quant) * quant))
    merged = []
    for fx, fw, top in slabs:
        if merged and merged[-1][2] == top and abs(merged[-1][0] + merged[-1][1] - fx) < 1:
            merged[-1][1] += fw
        else:
            merged.append([fx, fw, top])
    for fx, fw, top in merged:
        oid_ref[0] += 1
        objs_list.append(f'  <object id="{oid_ref[0]}" type="Solid" x="{round(fx,1)}" y="{round(top-60,1)}" width="{round(fw+0.5,1)}" height="60"/>')


def write_tmx(fname, objs_list, w_px):
    tmx2 = ['<?xml version="1.0" encoding="UTF-8"?>',
            f'<map version="1.10" orientation="orthogonal" renderorder="right-down" width="{int(w_px)//8}" height="120" tilewidth="8" tileheight="8" infinite="0">',
            ' <objectgroup id="2" name="collision">'] + objs_list + [' </objectgroup>', '</map>']
    open(f"{OUT}/tiles/{fname}", "w").write("\n".join(tmx2))
    print(fname, "objects:", len(objs_list))


# Mission2 terrain
M2_W1 = [(-9.400,-0.953),(-8.556,-0.972),(-8.474,-0.960),(-8.393,-0.907),(-8.316,-0.850),(-7.349,-0.821),(-7.022,-0.900),(-6.814,-0.954),(-6.465,-0.973),(-5.714,-0.981),(-5.347,-0.984),(-5.220,-0.907),(-5.110,-0.818),(-4.015,-0.863),(-3.450,-0.995),(-2.211,-0.986),(-1.918,-0.939),(-1.592,-0.795),(-1.378,-0.724),(-1.336,-0.946),(-0.197,-0.846),(0.177,-0.886),(2.367,-0.924),(2.836,-0.809),(4.177,-0.467),(6.055,0.085),(7.407,0.377),(8.076,0.499),(6.410,-0.782),(10.984,-0.803),(11.915,-1.010)]
M2_W2 = [(11.956,-1.021),(13.548,-1.426),(14.524,-1.698),(15.381,-2.403),(15.602,-2.529),(16.803,-2.545),(18.105,-2.572),(18.711,-3.723),(18.887,-3.875),(19.126,-3.910),(19.810,-3.975),(21.347,-3.976),(21.834,-4.520),(22.330,-5.021),(22.713,-5.312),(23.473,-5.431),(28.278,-5.497),(35.057,-5.401),(39.997,-6.029)]
M2_W3 = [(39.971,-6.035),(41.738,-6.062),(43.181,-6.082),(45.382,-6.118)]
objs2 = []
oid2 = [1]
_objs_save, _oid_save = objs, oid
objs, oid = objs2, oid2
polyline_solid(M2_W1)
polyline_solid(M2_W2)
polyline_solid(M2_W3)
rect(-960, -200, 20, 900, "Solid")
rect(4548, 300, 20, 400, "Solid")   # right wall boss arena (45.48u)
objs, oid = _objs_save, _oid_save
write_tmx("mission2.tmx", objs2, 5600)

# Mission3 terrain (cave: floor + roof)
M3_WALK = [(-8.996,-0.991),(-4.264,-0.989),(-4.235,-0.488),(-4.003,-0.512),(-3.944,-0.019),(-3.444,-0.023),(-3.415,-0.969),(3.601,-1.007),(6.446,-0.982),(6.584,-0.872),(6.816,-0.681),(7.08,-0.437),(7.195,-0.358),(7.608,-0.217),(8.162,-0.267),(8.656,-0.6),(9.015,-0.727),(9.578,-0.616),(9.916,-0.541),(10.181,-0.356),(10.459,-0.335),(10.478,-0.947),(12.991,-0.982),(12.99,-0.518),(13.306,-0.451),(13.383,0.0),(16.16,0.015),(16.194,-0.974),(22.472,-1.015),(22.534,-0.466),(22.756,-0.475),(22.862,0.009),(23.357,-0.013),(23.41,-0.997),(32.334,-0.98),(38.764,-1.046),(47.602,-0.999),(54.383,-0.975)]
M3_ROOF = [(-8.423,0.83),(-8.443,-0.338),(-7.133,-0.392),(-7.065,-0.354),(-7.034,-0.734),(-5.899,-0.695),(-5.854,0.081),(-4.989,0.035),(-4.562,0.518),(-2.811,0.509),(-2.441,0.119),(1.177,0.119),(1.49,0.908),(1.491,0.102),(3.485,0.12),(3.617,-0.701),(4.544,-0.72),(4.851,0.907),(4.851,-0.724),(6.323,-0.627),(7.033,0.023),(7.545,0.142),(7.892,0.916),(7.891,0.146),(8.352,0.07),(8.848,-0.32),(9.22,-0.359),(9.564,0.911),(9.607,-0.229),(9.83,-0.198),(10.007,-0.071),(10.205,-0.003),(10.842,0.038),(12.046,0.043),(12.597,0.389),(13.012,0.552),(14.544,0.5),(16.355,0.5),(17.786,0.495),(18.227,0.428),(18.634,0.137),(18.982,0.939),(19.014,0.084),(20.125,0.146),(21.441,0.139),(22.1,0.272),(22.249,0.446),(23.087,0.472),(24.166,0.433),(24.388,0.197),(24.668,0.121),(32.381,0.106),(32.711,0.897),(32.786,0.073),(33.191,0.091),(33.54,0.878),(33.543,0.13),(34.044,0.126),(34.36,0.863),(34.393,0.127),(35.644,0.085),(35.874,0.913),(35.892,0.082),(36.425,0.115),(36.688,0.88),(36.651,0.136),(37.226,0.107),(37.576,0.9),(37.503,0.049),(54.371,0.048)]
objs3 = []
oid3 = [1]
objs, oid = objs3, oid3
polyline_solid(M3_WALK)
rect(-920, -100, 20, 400, "Solid")
objs, oid = _objs_save, _oid_save
polyline_ceiling(M3_ROOF, objs3, oid3)
write_tmx("mission3.tmx", objs3, 5600)

# Mission3Boss arena
M3B_WALK = [(-8.764,-0.912),(-8.331,-0.866),(-7.879,-0.833),(-7.653,-0.819),(-7.456,-0.815),(-7.391,-0.833),(-6.97,-0.834),(-6.672,-0.9),(-6.338,-0.912)]
objs3b = []
oid3b = [1]
objs, oid = objs3b, oid3b
polyline_solid(M3B_WALK)
# kill line below tower
rect(-909.3, 300.8, 307.1, 100, "Hazard")
objs, oid = _objs_save, _oid_save
write_tmx("mission3boss.tmx", objs3b, 1200)

W_PX = 5600
tmx = ['<?xml version="1.0" encoding="UTF-8"?>',
       f'<map version="1.10" orientation="orthogonal" renderorder="right-down" width="{W_PX//8}" height="60" tilewidth="8" tileheight="8" infinite="0">',
       ' <objectgroup id="2" name="collision">'] + objs + [' </objectgroup>', '</map>']
open(f"{OUT}/tiles/mission1.tmx", "w").write("\n".join(tmx))
print("tmx objects:", len(objs))

# ---------------- audio ----------------
AU = A + "/Audio"
AUDIO = {
    "m1_bgm.mp3": "BGM/03-blue water fangs (the island of dr. moreau).mp3",
    "boss_bgm.mp3": "BGM/06-steel beasts 6beets.mp3",
    "shot.mp3": "Effects/mslug3-84-normal-shot.mp3",
    "heavy_shot.mp3": "Effects/metal-slug-77-heavy-shot.mp3",
    "shot_hit.mp3": "Effects/mslug3-108d-shot-hit.mp3",
    "melee_hit.mp3": "Effects/mslug3-89-melee-hit.mp3",
    "grenade_hit.mp3": "Effects/mslu3-grenade-hit.mp3",
    "grab.mp3": "Effects/mslug3-93-collectible-grab.mp3",
    "equip.mp3": "Effects/mslug3-91-weapon-equip.mp3",
    "destroy1.mp3": "Effects/mslug3-56-destroy1.mp3",
    "destroy2.mp3": "Effects/mslug3-59-destroy2.mp3",
    "destroy3.mp3": "Effects/mslug3-62-destroy3.mp3",
    "marco_death.mp3": "Effects/mslug3-marco-death.mp3",
    "soldier_death.mp3": "Effects/mslug3-soldier-death-2.mp3",
    "crab_voice.mp3": "Effects/mslug3-1198-crab-voice.mp3",
    "mission1_start.wav": "Voices/mslug3-mission-1-start.wav",
    "m2_bgm.mp3": "BGM/07-the midnight wandering.mp3",
    "m3_bgm.mp3": "BGM/08-the magic lantern.mp3",
    "mission2_start.wav": "Voices/mslug3-mission-2-start.wav",
    "mission3_start.wav": "Voices/mslug3-mission-3-start.wav",
    "zombie_attack.mp3": "Effects/mslug3-zombie-strong-3.mp3",
    "zombie_vomit.mp3": "Effects/mslug3-zombie-vomit-1.mp3",
    "thunder.mp3": "Effects/mslug3-128-thunder.mp3",
    "missile_out.mp3": "Effects/mslug3-1062-missile-out.mp3",
    "mission_complete.wav": "Voices/mslug3-mission-complete.wav",
    "hmg_voice.wav": "Voices/mslug3-heavy-machine-gun.wav",
    "okay.wav": "Voices/mslug3-030-okay.wav",
}
audio_ok = {}
for dst, src in AUDIO.items():
    cands = glob.glob(f"{AU}/{src}") or glob.glob(f"{AU}/{src.split('/')[0]}/*{src.split('/')[-1].split('-')[-1]}")
    if not cands:
        print("AUDIO MISS:", src)
        continue
    shutil.copy(cands[0], f"{OUT}/audio/{dst}")
    audio_ok[dst] = os.path.getsize(cands[0])
manifest["audio"] = audio_ok

json.dump(manifest, open(f"{OUT}/manifest.json", "w"), indent=1)
print("statics:", list(statics))
manifest["statics"] = statics
json.dump(manifest, open(f"{OUT}/manifest.json", "w"), indent=1)
print("DONE")
