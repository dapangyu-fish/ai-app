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
save_static("lifebar", A + "/Sprites/HUD/Lifebar.png")
save_static("lifebar_border", A + "/Sprites/HUD/LifebarBorder.png")

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
