#!/usr/bin/env python3
"""Build templates/demo_metalslug.json — MetalSlugClone Mission 1 port.

Every constant transcribed from the Unity project (see /home/fish/MetalSlugClone):
PPU=100 (1u=100px), gravity 9.81u/s², ortho 1.1 → viewport 392×220.
Reads assets/metalslug/manifest.json (strip cells/anchors/fps from the asset
pipeline). Coordinates: x_px = x_u*100 ; y_px = (1.4 - y_u)*100 (y-flip).
"""
import json
import os
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
MAN = json.load(open(os.path.join(HERE, "../assets/metalslug/manifest.json")))
BASE = "https://myapp-demo-de-oss-endpoint.dapangyu.work/json-app-assets/demo-metalslug/1.0.0/"
SPR, AUD = BASE + "sprites/", BASE + "audio/"
APPID = str(uuid.uuid5(uuid.NAMESPACE_DNS, "myapp-template:demo-metalslug"))

VW, VH = 392, 220
GRAV, MAXFALL = 981, 900
PSPEED, CSPEED, JUMP_VY = 120, 80, -400
FIRE_CD, BULLET_V, BULLET_DMG = 0.3, 300, 100
MELEE_R, MELEE_DMG = 45, 1000
GREN_V, GREN_G, GREN_DMG = 176.8, 490.5, 300
HP0, BOMBS0 = 100, 10


def X(u): return round(u * 100, 1)
def Y(u): return round((1.4 - u) * 100, 1)


V = lambda p: {"var": p}  # noqa: E731
def IF(c, t, e): return {"if": [c, t, e]}
def call(n, a=None, assign=None):
    c = {"call": n}
    if a is not None:
        c["args"] = a
    if assign:
        c["assign"] = assign
    return c
def gif(c, t, e=None):
    a = {"cond": c, "then": t}
    if e:
        a["else"] = e
    return call("@if", a)
def eset(i, f, v): return call("@entity.set", {"id": i, "field": f, "value": v})
def eadd(i, f, b, mn=None, mx=None):
    a = {"id": i, "field": f, "by": b}
    if mn is not None:
        a["min"] = mn
    if mx is not None:
        a["max"] = mx
    return call("@entity.add", a)
def vset(k, v): return call("@set", {"var": k, "value": v})
def SND(i): return call("@audio.play", {"id": i})


def G(group):
    return MAN["groups"][group]


def anims_of(group, names=None):
    g = G(group)
    out = {}
    for n, a in g["anims"].items():
        if names and n not in names and not (n.endswith("_l") and n[:-2] in names):
            continue
        out[n] = {"asset": SPR + a["file"], "frame_size": g["cell"],
                  "frames": a["frames"], "frames_per_row": a["frames"],
                  "step_time": round(1 / a["fps"], 4), "loop": a["loop"]}
    return out


def oneshot(group, name, pos, prio=60, idexpr=None, size=None):
    """spawn steps for a one-shot FX anim"""
    g = G(group)
    a = g["anims"][name]
    return call("@spawn", {
        "id": idexpr or f"fx_{{{{ vars.seq }}}}", "kind": "animated_sprite",
        "priority": prio, "asset": SPR + a["file"], "frame_size": g["cell"],
        "frames": a["frames"], "frames_per_row": a["frames"],
        "step_time": round(1 / a["fps"], 4), "loop": False,
        "position": pos, "size": size or g["cell"], "auto_update": True,
        "state": {"removeOnFinish": True, "assetLoadingOverlay": False}})


ATLAS = MAN["atlas"]
def atlas_ent(slice_key, xu, yu, prio, extra=None):
    r = ATLAS["slices"][slice_key]
    e = {"kind": "sprite", "priority": prio, "asset": BASE + "atlas/foreground.png",
         "src": r, "position": [X(xu) - r[2] / 2, Y(yu) - r[3] / 2],
         "size": [r[2], r[3]], "auto_update": False,
         "state": {"assetLoadingOverlay": False}}
    if extra:
        e.update(extra)
    return e


entities = {}

# ---------- level art (scene positions; priority by Unity sorting layer) ----------
ART = [  # (slice, xu, yu, prio)
    ("foreground_cloud_forest", 10.302, 0.43, -70),   # parallax layer (pinned in logic)
    ("foreground_0", 6.492, 0.01, -60),
    ("foreground_2", 29.307, -0.11, -58),
    ("fid_21300084", 46.378, -0.891, -58),            # BridgeEdge
    ("foreground_2_end", 46.531, -1.086, -60),
    ("foreground_tower_1", 6.41, -0.03, -55),
    ("foreground_boat", 13.132, -0.186, -55),
    ("foreground_boat_1", 13.532, 0.034, -54),
    ("foreground_door_1", 13.872, -0.126, -54),
    ("foreground_sea_orange", 43.507, -1.32, -55),
    ("foreground_dead_fish", 3.462, -0.59, -50),
    ("foreground_sea", 26.367, -1.39, -50), ("foreground_sea", 29.227, -1.39, -50),
    ("foreground_sea", 32.267, -1.39, -50), ("foreground_sea", 35.207, -1.39, -50),
    ("foreground_sea", 38.247, -1.39, -50), ("foreground_sea", 39.597, -1.39, -50),
    ("foreground_sea_orange", 43.507, -1.465, -49),
    ("foreground_sea_end_0", 46.611, -1.464, -50), ("foreground_sea_end_0", 46.611, -1.308, -50),
    ("foreground_sea_end_0", 51.732, -1.486, -50),
    ("fid_21300076", 36.182, -1.036, -52),            # VanBridge1
    ("fid_21300076", 40.432, -1.036, -52),            # VanBridge2 (same art)
    ("fid_21300074", 47.173, -0.871, -56),            # BossRoom pieces
    ("fid_21300110", 48.6, -0.871, -56),
    ("fid_21300126", 50.0, -0.871, -56),
    ("foreground_1", 18.637, -0.916, 70),             # occluder IN FRONT of player
]
for i, (sl, xu, yu, pr) in enumerate(ART):
    entities[f"art_{i}"] = atlas_ent(sl, xu, yu, pr)

# tower (destructible): normal + swapped sprite on death
entities["tower"] = atlas_ent("foreground_tower_single", 7.13, 0.33, -54)
entities["tower"]["state"].update({"hp": 1500})
TOWER_DESTROYED = ATLAS["slices"]["fid_21300026"]

# sea waves (animated)
g = G("seawaves")
a = g["anims"]["wave"]
entities["waves"] = {"kind": "animated_sprite", "priority": -49,
                     "asset": SPR + a["file"], "frame_size": g["cell"],
                     "frames": a["frames"], "frames_per_row": a["frames"],
                     "step_time": round(1 / a["fps"], 4),
                     "position": [X(1.272) - g["cell"][0] / 2, Y(-0.77) - g["cell"][1] / 2],
                     "size": g["cell"], "auto_update": True,
                     "state": {"assetLoadingOverlay": False}}

# bridge segments over boss water (removable by boss + heavy bombs)
BRIDGE = MAN["bridge_objects"]
bseg_r = ATLAS["slices"]["fid_21300072"]
for b in BRIDGE:
    entities[f"bseg_{b['seg']}"] = {
        "kind": "sprite", "priority": -52, "asset": BASE + "atlas/foreground.png",
        "src": bseg_r, "position": [X(b["xu"]) - 1, Y(-0.86) - 6],
        "size": [32, bseg_r[3] * 32 / bseg_r[2]], "auto_update": False,
        "state": {"assetLoadingOverlay": False}}

# ---------- terrain ----------
entities["map"] = {"kind": "tiled_map", "priority": -80,
                   "source": "tiles/mission1.tmx", "base_url": BASE, "scale": 1,
                   "solid_layers": ["collision"], "hazard_layers": [],
                   "collidable": True}

# ---------- player (legs/body = physics entity) + torso ----------
BODY, TOP = G("marco_body"), G("marco_top")
entities["player"] = {
    "kind": "animated_sprite", "priority": 40,
    "position": [X(-0.338) - 10.5, Y(0.504) - 19.5], "size": [21, 39],
    "velocity": [0, 0], "auto_update": False, "animation": "idle",
    "asset": SPR + BODY["anims"]["idle"]["file"], "frame_size": BODY["cell"],
    "frames": BODY["anims"]["idle"]["frames"], "frames_per_row": BODY["anims"]["idle"]["frames"],
    "step_time": 0.125, "animations": anims_of("marco_body"),
    "state": {"spriteW": BODY["cell"][0], "spriteH": BODY["cell"][1],
              "spriteOffsetX": 0, "spriteOffsetY": 0, "assetLoadingOverlay": False},
}
entities["torso"] = {
    "kind": "animated_sprite", "priority": 41, "position": [-500, -500],
    "size": [2, 2], "auto_update": False, "animation": "p_idle",
    "asset": SPR + TOP["anims"]["p_idle"]["file"], "frame_size": TOP["cell"],
    "frames": TOP["anims"]["p_idle"]["frames"], "frames_per_row": TOP["anims"]["p_idle"]["frames"],
    "step_time": 0.125, "animations": anims_of("marco_top"),
    "state": {"spriteW": TOP["cell"][0], "spriteH": TOP["cell"][1],
              "spriteOffsetX": 0, "spriteOffsetY": 0, "assetLoadingOverlay": False},
}

# ---------- marco boat ----------
MB = G("marcoboat")
entities["mboat"] = {
    "kind": "animated_sprite", "priority": -45,
    "asset": SPR + MB["anims"]["sail"]["file"], "frame_size": MB["cell"],
    "frames": MB["anims"]["sail"]["frames"], "frames_per_row": MB["anims"]["sail"]["frames"],
    "step_time": round(1 / MB["anims"]["sail"]["fps"], 4),
    "animations": anims_of("marcoboat"),
    "position": [X(27.664) - MB["cell"][0] / 2, Y(-0.706) - MB["cell"][1] / 2],
    "size": [140, 40], "auto_update": False, "animation": "sail",
    "state": {"spriteOffsetX": (MB["cell"][0] - 140) / -2 + 35, "spriteOffsetY": -30,
              "assetLoadingOverlay": False}}

# ---------- enemies: initial crabs + van/boat/boss ----------
CRABS = [(3.02, -0.28), (3.65, -0.343), (4.316, -0.28), (5.336, -0.194),
         (8.726, -0.204), (9.246, -0.264), (10.216, -0.594), (11.016, -0.644),
         (18.26, 0.212), (19.43, 0.057)]
CRAB_G, SOLD_G = G("crab"), G("soldier")


def crab_spec(xu, yu):
    return {"kind": "animated_sprite", "priority": 30,
            "asset": SPR + CRAB_G["anims"]["idle"]["file"], "frame_size": CRAB_G["cell"],
            "frames": CRAB_G["anims"]["idle"]["frames"],
            "frames_per_row": CRAB_G["anims"]["idle"]["frames"],
            "step_time": 0.125, "animation": "idle", "animations": anims_of("crab"),
            "position": [X(xu) - 20, Y(yu) - 17], "size": [40, 34],
            "velocity": [0, 0], "auto_update": False,
            "state": {"kind": "crab", "hp": 300, "spd": 100, "act": 200,
                      "meleeT": 0, "dieT": 0, "grp": "", "spriteW": CRAB_G["cell"][0],
                      "spriteH": CRAB_G["cell"][1], "spriteOffsetX": -19,
                      "spriteOffsetY": -19, "assetLoadingOverlay": False}}


def soldier_spec():  # spawned from logic with position set at spawn
    return {"kind": "animated_sprite", "priority": 30,
            "asset": SPR + SOLD_G["anims"]["idle"]["file"], "frame_size": SOLD_G["cell"],
            "frames": SOLD_G["anims"]["idle"]["frames"],
            "frames_per_row": SOLD_G["anims"]["idle"]["frames"],
            "step_time": 0.125, "animation": "idle", "animations": anims_of("soldier"),
            "size": [28, 39], "velocity": [0, 0], "auto_update": False,
            "state": {"kind": "soldier", "hp": 300, "spd": 50, "act": 300,
                      "meleeT": 0, "rangedT": 0, "dieT": 0, "grp": "",
                      "spriteW": SOLD_G["cell"][0], "spriteH": SOLD_G["cell"][1],
                      "spriteOffsetX": -12, "spriteOffsetY": -5,
                      "assetLoadingOverlay": False}}


for i, (xu, yu) in enumerate(CRABS):
    entities[f"en_c{i}"] = crab_spec(xu, yu)

VAN_G = G("van")
for vi, (xu, yu) in enumerate([(36.156, -0.507), (40.383, -0.523)]):
    entities[f"van{vi+1}"] = {
        "kind": "animated_sprite", "priority": 25,
        "asset": SPR + VAN_G["anims"]["idle"]["file"], "frame_size": VAN_G["cell"],
        "frames": VAN_G["anims"]["idle"]["frames"],
        "frames_per_row": VAN_G["anims"]["idle"]["frames"],
        "step_time": 0.1, "animation": "idle", "animations": anims_of("van"),
        "position": [X(xu) - 60, Y(yu) - 55], "size": [120, 110],
        "auto_update": False,
        "state": {"hp": 3000, "fireT": 3.0, "dead": False,
                  "spriteOffsetX": -10, "spriteOffsetY": -35, "assetLoadingOverlay": False}}

# enemy boat (destructible blocker) — art from atlas boat_1 slice
entities["eboat"] = atlas_ent("boat_1", 30.922, -0.806, -46)
entities["eboat"]["state"].update({"hp": 5000})

BOSS_G, BB_G = G("boss1"), G("bossbomb")
entities["boss"] = {
    "kind": "animated_sprite", "priority": 35,
    "asset": SPR + BOSS_G["anims"]["walk"]["file"], "frame_size": BOSS_G["cell"],
    "frames": BOSS_G["anims"]["walk"]["frames"],
    "frames_per_row": BOSS_G["anims"]["walk"]["frames"],
    "step_time": 0.084, "animation": "walk", "animations": anims_of("boss1"),
    "position": [X(45.043) - 115, Y(-2.643) - 100], "size": [230, 160],
    "velocity": [0, 0], "auto_update": False,
    "state": {"hp": 10000, "phase": 0, "fireT": 2.0, "sprintT": 5.0, "sprintPh": 0,
              "spd": 75, "spriteOffsetX": 0, "spriteOffsetY": -45,
              "assetLoadingOverlay": False}}

# ---------- collectibles ----------
for key, xu, yu in (("hmg", 8.951, -0.249), ("ammo", 14.779, 0.228), ("medkit", 18.24, 0.61)):
    st = MAN["statics"][key]
    entities[f"col_{key}"] = {"kind": "sprite", "priority": 20, "asset": SPR + st["file"],
                              "position": [X(xu) - st["size"][0] / 2, Y(yu) - st["size"][1] / 2],
                              "size": st["size"], "auto_update": False,
                              "state": {"assetLoadingOverlay": False}}

# ---------- camera target + HUD + title ----------
entities["cam"] = {"kind": "pixel", "priority": -100, "position": [X(3.172), Y(0.029)],
                   "size": [1, 1], "auto_update": False,
                   "render": {"shape": "rect", "color": "#000000"}}
entities["hud_hpb"] = {"kind": "pixel", "priority": 220, "position": [8, 8], "size": [114, 10],
                       "fixed_to_screen": True, "auto_update": False,
                       "render": {"shape": "rect", "color": "#222222"}}
entities["hud_hp"] = {"kind": "pixel", "priority": 221, "position": [10, 10], "size": [110, 6],
                      "fixed_to_screen": True, "auto_update": False,
                      "render": {"shape": "rect", "color": "#E03030"}}
entities["hud_score"] = {"kind": "pixel", "priority": 220, "position": [300, 8], "size": [1, 1],
                         "fixed_to_screen": True, "auto_update": False,
                         "render": {"shape": "text", "value": "0", "color": "#FFFFFF", "fontSize": 12}}
gi = MAN["statics"]["grenade_icon"]
entities["hud_gicon"] = {"kind": "sprite", "priority": 220, "asset": SPR + gi["file"],
                         "position": [8, 24], "size": [10, 12], "fixed_to_screen": True,
                         "auto_update": False, "state": {"assetLoadingOverlay": False}}
entities["hud_bombs"] = {"kind": "pixel", "priority": 220, "position": [22, 26], "size": [1, 1],
                         "fixed_to_screen": True, "auto_update": False,
                         "render": {"shape": "text", "value": "x 10", "color": "#FFFFFF", "fontSize": 11}}
entities["hud_ammo"] = {"kind": "pixel", "priority": 220, "position": [22, 40], "size": [1, 1],
                        "fixed_to_screen": True, "auto_update": False,
                        "render": {"shape": "text", "value": "oo", "color": "#FFD24A", "fontSize": 11}}
entities["title_bg"] = {"kind": "pixel", "priority": 230, "position": [0, 0], "size": [VW, VH],
                        "fixed_to_screen": True, "auto_update": False,
                        "render": {"shape": "rect", "color": "#101018"}}
entities["title_t"] = {"kind": "pixel", "priority": 231, "position": [78, 70], "size": [1, 1],
                       "fixed_to_screen": True, "auto_update": False,
                       "render": {"shape": "text", "value": "METAL SLUG — MISSION 1",
                                  "color": "#FFB020", "fontSize": 20}}
entities["title_s"] = {"kind": "pixel", "priority": 231, "position": [110, 120], "size": [1, 1],
                       "fixed_to_screen": True, "auto_update": False,
                       "render": {"shape": "text", "value": "TAP OR PRESS TO START",
                                  "color": "#FFFFFF", "fontSize": 12}}
entities["title_c"] = {"kind": "pixel", "priority": 231, "position": [46, 196], "size": [1, 1],
                       "fixed_to_screen": True, "auto_update": False,
                       "render": {"shape": "text",
                                  "value": "port of github.com/giacoballoccu/MetalSlugClone (fan project)",
                                  "color": "#8899AA", "fontSize": 8}}

# ---------- camera zones (confiner volumes -> cam-center clamp ranges) ----------
ZONES = [  # (vol_min_u, vol_max_u, cy_u)
    (0.42, 5.92, 0.029), (4.75, 12.57, 0.029), (11.94, 14.94, 0.114),
    (16.23, 21.52, 0.225), (21.86, 26.46, -0.055), (28.85, 34.99, -0.311),
    (30.82, 39.29, -0.311), (37.31, 45.30, -0.311), (46.97, 54.94, -0.311),
]
def zone_vars(i):
    mn, mx, cy = ZONES[i]
    lo, hi = X(mn) + VW / 2, X(mx) - VW / 2
    if hi < lo:
        lo = hi = (lo + hi) / 2
    return [vset("vars.cam_min", round(lo, 1)), vset("vars.cam_max", round(hi, 1)),
            vset("vars.cam_cy", Y(cy))]


# ---------- soldier / crab spawners ----------
SPAWNERS = [
    # (id, trigger_x_u, kind, [(x_u, y_u)...], delay_s, group)
    ("s_ch",  4.58, "crab", [(6.7, -0.03)] * 4, 1.0, ""),
    ("s_ub", 10.63, "crab", [(13.21, 0.665)] * 4, 1.0, ""),
    ("s_lf", 23.19, "soldier", [(23.67, 1.124), (23.77, 1.124), (23.87, 1.124), (23.97, 1.124)], 2.0, ""),
    ("s_rg", 24.93, "soldier", [(25.38, 1.124), (25.65, 1.124), (25.92, 1.124), (26.19, 1.124)], 2.05, ""),
    ("s_bt", 27.73, "soldier", [(30.27, 1.124), (30.43, 1.124), (30.59, 1.124)], 3.0, ""),
    ("s_v1", 33.55, "soldier", [(34.23, 1.124), (34.42, 1.124), (34.61, 1.124), (34.79, 1.124), (34.97, 1.124)], 2.5, ""),
    ("s_v2", 38.74, "soldier", [(38.67, 1.124), (38.86, 1.124), (39.04, 1.124), (39.23, 1.124), (39.41, 1.124)], 2.5, ""),
]
# sunk-boat door wave (fired by door trigger, tracked for zone switch)
DOOR_WAVE = [(13.81, -0.05)] * 3

VARS = {
    "state": "title", "hp": HP0, "score": 0, "bombs": BOMBS0, "mg": 0,
    "move": 0, "aimup": False, "duck": False, "was_duck": False,
    "jumpp": False, "firep": False, "grenp": False,
    "fire_cd": 0, "burst": 0, "burst_t": 0, "seq": 0,
    "grounded": False, "on_plat": False, "facing": 1,
    "cam_x": 238.0, "cam_min": 238.0, "cam_max": 396.0, "cam_cy": Y(0.029), "zone": 0,
    "autoscroll": False, "boat_started": False, "boat_stop": X(28.8),
    "eboat_dead": False, "van1_dead": False, "van2_dead": False,
    "door_opened": False, "door_kills": 0, "tower_dead": False,
    "boss_on": False, "boss_rising": False, "boss_dead": False, "boss_seg": 0,
    "throwT": 0, "meleeT": 0, "topanim": "p_idle", "bodyanim": "idle",
    "_h": None, "_h2": None, "_eid": "", "_ex": 0, "_ey": 0, "_d": 0,
    "won": False, "dieT": 0,
}
for sid, _, _, pts, _, _ in SPAWNERS:
    VARS[f"{sid}_on"] = False
    VARS[f"{sid}_n"] = 0
    VARS[f"{sid}_t"] = 0

# ================= INPUT =================
TITLE = {"==": [V("vars.state"), "title"]}
START = [vset("vars.state", "running"),
         call("@despawn", {"id": "title_bg"}), call("@despawn", {"id": "title_t"}),
         call("@despawn", {"id": "title_s"}), call("@despawn", {"id": "title_c"}),
         call("@audio.play", {"id": "bgm", "loop": True, "restart": True}),
         SND("v_start")]
INPUT = {
    "move_axis": [
        gif(TITLE, START),
        vset("vars.move", IF({">": [V("event.x"), 0.5]}, 1,
                             IF({"<": [V("event.x"), -0.5]}, -1, 0))),
        gif({">": [V("event.x"), 0.5]}, [vset("vars.facing", 1)]),
        gif({"<": [V("event.x"), -0.5]}, [vset("vars.facing", -1)]),
        vset("vars.aimup", {"<": [V("event.y"), -0.5]}),
        vset("vars.duck", {">": [V("event.y"), 0.5]}),
    ],
    "jump": [gif(TITLE, START, [vset("vars.jumpp", True)])],
    "jump_end": [vset("vars._h", None)],
    "attack": [gif(TITLE, START, [vset("vars.firep", True)])],
    "attack_end": [vset("vars._h", None)],
    "grenade": [gif(TITLE, START, [vset("vars.grenp", True)])],
    "tap": [gif(TITLE, START)],
}

# ================= FRAME LOGIC =================
PCX = {"+": [V("entities.player.x"), 10.5]}
PCY = {"+": [V("entities.player.y"), 19.5]}
RUN = {"==": [V("vars.state"), "running"]}
M = []

# --- timers
M += [vset("vars.fire_cd", {"max": [0, {"-": [V("vars.fire_cd"), V("event.dt")]}]})]

# --- movement
M += [
    eset("player", "vx", IF({"==": [V("vars.state"), "dead"]}, 0,
        IF({"and": [V("vars.duck"), {"or": [V("vars.grounded"), V("vars.on_plat")]}]},
           {"*": [V("vars.move"), CSPEED]},
           {"*": [V("vars.move"), PSPEED]}))),
    gif({"and": [V("vars.jumpp"), {"or": [V("vars.grounded"), V("vars.on_plat")]},
                 {"!": V("vars.duck")}, {"!=": [V("vars.state"), "dead"]}]},
        [eset("player", "vy", JUMP_VY), eadd("player", "y", -3), vset("vars.on_plat", False)]),
    vset("vars.jumpp", False),
    call("@platformer.step", {"id": "player", "map": "map", "dt": "{{ event.dt }}",
                              "gravity": GRAV, "max_fall": MAXFALL,
                              "one_way_types": ["platform"]}),
    vset("vars.grounded", V("entities.player.onGround")),
    gif({"and": [V("vars.grounded"), {"!=": [V("vars.move"), 0]},
                 {"or": [{"!!": V("entities.player.blockedRight")},
                         {"!!": V("entities.player.blockedLeft")}]}]},
        [eadd("player", "y", -5)]),
    vset("vars.on_plat", False),
]
# crouch hitbox 39 -> 18
M += [
    gif({"and": [V("vars.duck"), V("vars.grounded"), {"!": V("vars.was_duck")}]},
        [eset("player", "h", 18), eadd("player", "y", 21), vset("vars.was_duck", True)]),
    gif({"and": [{"!": V("vars.duck")}, V("vars.was_duck")]},
        [eset("player", "h", 39), eadd("player", "y", -21), vset("vars.was_duck", False)]),
]

# --- marco boat platform + movement
MBX, MBY = "entities.mboat.x", "entities.mboat.y"
M += [
    # carry
    gif({"and": [{">": [{"+": [V("entities.player.x"), 21]}, V(MBX)]},
                 {"<": [V("entities.player.x"), {"+": [V(MBX), 140]}]},
                 {">=": [{"+": [V("entities.player.y"), V("entities.player.h")]}, {"-": [V(MBY), 10]}]},
                 {"<=": [{"+": [V("entities.player.y"), V("entities.player.h")]}, {"+": [V(MBY), 22]}]},
                 {">=": [V("entities.player.vy"), 0]}]},
        [eset("player", "y", {"-": [V(MBY), V("entities.player.h")]}),
         eset("player", "vy", 0), vset("vars.on_plat", True),
         gif({"!": V("vars.boat_started")}, [vset("vars.boat_started", True)])]),
    # target progression
    vset("vars.boat_stop", IF({"!": V("vars.eboat_dead")}, X(28.8),
                          IF({"!": V("vars.van1_dead")}, X(34.05),
                          IF({"!": V("vars.van2_dead")}, X(38.28), X(45.13))))),
    gif({"and": [V("vars.boat_started"), {"<": [V(MBX), V("vars.boat_stop")]}]},
        [eadd("mboat", "x", {"*": [35, V("event.dt")]}),
         gif(V("vars.on_plat"), [eadd("player", "x", {"*": [35, V("event.dt")]})])]),
]

# --- fire / melee / grenade
def spawn_pbullet(rot):  # rot: 0 right/left(by facing), 1 up, 2 down
    st = MAN["statics"]["bullet"]
    if rot == 0:
        vel = [{"*": [V("vars.facing"), BULLET_V]}, 0]
        pos = [{"+": [PCX, {"-": [{"*": [V("vars.facing"), 14]}, 5]}]},
               {"+": [PCY, IF(V("vars.duck"), 2, -8)]}]
    elif rot == 1:
        vel = [0, -BULLET_V]
        pos = [{"+": [PCX, {"*": [V("vars.facing"), 4]}]}, {"-": [PCY, 22]}]
    else:
        vel = [0, BULLET_V]
        pos = [PCX, {"+": [PCY, 14]}]
    return call("@spawn", {"id": "pb_{{ vars.seq }}", "kind": "sprite", "priority": 45,
                           "asset": SPR + st["file"], "size": st["size"],
                           "flip_x": {"<": [V("vars.facing"), 0]},
                           "position": pos, "velocity": vel, "auto_update": True,
                           "state": {"ttl": 2.0, "dmg": BULLET_DMG, "assetLoadingOverlay": False}})


FIRE_STEPS = [
    vset("vars.seq", {"+": [V("vars.seq"), 1]}),
    gif(V("vars.aimup"), [spawn_pbullet(1)],
        [gif({"and": [{"!": V("vars.grounded")}, V("vars.duck")]}, [spawn_pbullet(2)],
             [spawn_pbullet(0)])]),
    gif({">": [V("vars.mg"), 0]},
        [SND("heavy_shot"), vset("vars.mg", {"max": [0, {"-": [V("vars.mg"), 3]}]}),
         vset("vars.burst", 2), vset("vars.burst_t", 0.05)],
        [SND("shot")]),
    vset("vars.fire_cd", FIRE_CD),
]
# melee first if enemy in range
M += [
    gif({"and": [RUN, V("vars.firep"), {"<=": [V("vars.fire_cd"), 0]}]}, [
        call("@collision.first", {"a": "player", "where_prefix": "en_"}, assign="vars._h"),
        gif({"!=": [V("vars._h"), None]},
            [  # melee
             vset("vars.fire_cd", FIRE_CD),
             eadd("{{ vars._h }}", "state.hp", -MELEE_DMG),
             vset("vars.score", {"+": [V("vars.score"), MELEE_DMG]}),
             SND("melee_hit"), vset("vars.meleeT", 0.5), vset("vars._h", None)],
            FIRE_STEPS),
    ]),
    vset("vars.firep", False),
    # MG burst continuation
    gif({">": [V("vars.burst"), 0]}, [
        vset("vars.burst_t", {"-": [V("vars.burst_t"), V("event.dt")]}),
        gif({"<=": [V("vars.burst_t"), 0]}, [
            vset("vars.seq", {"+": [V("vars.seq"), 1]}),
            gif(V("vars.aimup"), [spawn_pbullet(1)], [spawn_pbullet(0)]),
            vset("vars.burst", {"-": [V("vars.burst"), 1]}),
            vset("vars.burst_t", 0.05)])]),
    vset("vars.meleeT", {"max": [0, {"-": [V("vars.meleeT"), V("event.dt")]}]}),
]
# grenade
GREN_A = G("grenade")["anims"]["fly"]
M += [
    gif({"and": [RUN, V("vars.grenp"), {"<=": [V("vars.fire_cd"), 0]}, {">": [V("vars.bombs"), 0]}]}, [
        vset("vars.bombs", {"-": [V("vars.bombs"), 1]}),
        vset("vars.seq", {"+": [V("vars.seq"), 1]}),
        call("@spawn", {"id": "pg_{{ vars.seq }}", "kind": "animated_sprite", "priority": 45,
                        "asset": SPR + GREN_A["file"], "frame_size": G("grenade")["cell"],
                        "frames": GREN_A["frames"], "frames_per_row": GREN_A["frames"],
                        "step_time": 0.125, "position": [PCX, {"-": [PCY, 10]}],
                        "size": [14, 20], "auto_update": True,
                        "velocity": [{"*": [V("vars.facing"), GREN_V]}, -GREN_V],
                        "state": {"ttl": 4, "assetLoadingOverlay": False}}),
        vset("vars.fire_cd", FIRE_CD), vset("vars.throwT", 0.5)]),
    vset("vars.grenp", False),
    vset("vars.throwT", {"max": [0, {"-": [V("vars.throwT"), V("event.dt")]}]}),
]

# --- torso/body animation + pinning
AXB, PTYB = BODY["anchor"]
AXT, PTYT = TOP["anchor"]
CWB, CWT = BODY["cell"][0], TOP["cell"][0]
GROUNDED = {"or": [V("vars.grounded"), V("vars.on_plat")]}
M += [
    # body anim
    vset("vars.bodyanim", IF({"==": [V("vars.state"), "dead"]}, "death",
        IF({"and": [V("vars.duck"), GROUNDED]},
           IF({">": [V("vars.meleeT"), 0]}, "c_melee",
              IF({">": [V("vars.throwT"), 0]}, "c_throw",
                 IF({"!=": [V("entities.player.vx"), 0]}, "c_walk", "c_idle"))),
           IF({"!": GROUNDED},
              IF({"!=": [V("entities.player.vx"), 0]}, "jump_walk", "jump"),
              IF({"!=": [V("entities.player.vx"), 0]}, "walk", "idle"))))),
    vset("vars.bodyanim", IF({"==": [V("vars.facing"), 1]}, V("vars.bodyanim"),
                             {"cat": [V("vars.bodyanim"), "_l"]})),
    call("@animated_sprite.set_animation", {"id": "player", "animation": "{{ vars.bodyanim }}"}),
    eset("player", "state.spriteOffsetX",
         IF({"==": [V("vars.facing"), 1]}, round(10.5 - AXB, 1), round(10.5 - (CWB - AXB), 1))),
    eset("player", "state.spriteOffsetY", round(19.5 - PTYB, 1)),
    # torso anim (hidden while crouched/dead)
    gif({"or": [{"and": [V("vars.duck"), GROUNDED]}, {"==": [V("vars.state"), "dead"]}]},
        [eset("torso", "state.opacity", 0)],
        [eset("torso", "state.opacity", 1),
         vset("vars.topanim",
              IF({">": [V("vars.meleeT"), 0]}, IF({">": [V("vars.mg"), 0]}, "m_melee", "melee"),
              IF({">": [V("vars.throwT"), 0]}, IF({">": [V("vars.mg"), 0]}, "m_throw", "throw"),
              IF(V("vars.aimup"),
                 IF({">": [V("vars.fire_cd"), FIRE_CD - 0.15]}, "p_fire_up", "p_up"),
                 IF({"!": GROUNDED},
                    IF({"<": [V("entities.player.vy"), 0]}, "p_jump_up", "p_jump_down"),
                    IF({">": [V("vars.fire_cd"), FIRE_CD - 0.15]},
                       IF({">": [V("vars.mg"), 0]}, "m_fire", "p_fire"),
                       IF({">": [V("vars.mg"), 0]}, "m_idle",
                          IF({"!=": [V("entities.player.vx"), 0]}, "p_walk", "p_idle")))))))),
         vset("vars.topanim", IF({"==": [V("vars.facing"), 1]}, V("vars.topanim"),
                                 {"cat": [V("vars.topanim"), "_l"]})),
         call("@animated_sprite.set_animation", {"id": "torso", "animation": "{{ vars.topanim }}"}),
         eset("torso", "x", IF({"==": [V("vars.facing"), 1]},
                               {"+": [PCX, round(13.5 - AXT, 1)]},
                               {"+": [PCX, round(-13.5 - (CWT - AXT), 1)]})),
         eset("torso", "y", {"-": [PCY, round(PTYT, 1) + 6]})]),
]

# --- spawner triggers + one-shot camera gates
def spawn_enemy_steps(sid, kind, pts, grp):
    steps = []
    for j, (xu, yu) in enumerate(pts):
        spec = crab_spec(xu, yu) if kind == "crab" else soldier_spec()
        spec = dict(spec)
        spec["id"] = f"en_{sid}{j}"
        if kind == "soldier":
            spec["position"] = [X(xu) - 14, Y(yu) - 19]
        spec["state"] = dict(spec["state"], grp=grp)
        steps.append((j, call("@spawn", spec)))
    return steps


for sid, tx, kind, pts, delay, grp in SPAWNERS:
    per = spawn_enemy_steps(sid, kind, pts, grp)
    M += [gif({"and": [{"!": V(f"vars.{sid}_on")}, {">": [PCX, X(tx)]}]},
              [vset(f"vars.{sid}_on", True), vset(f"vars.{sid}_t", 0.01)]),
          gif({"and": [V(f"vars.{sid}_on"), {"<": [V(f"vars.{sid}_n"), len(pts)]}]}, [
              vset(f"vars.{sid}_t", {"-": [V(f"vars.{sid}_t"), V("event.dt")]}),
              gif({"<=": [V(f"vars.{sid}_t"), 0]},
                  [gif({"==": [V(f"vars.{sid}_n"), j]}, [st]) for j, st in per] +
                  [vset(f"vars.{sid}_n", {"+": [V(f"vars.{sid}_n"), 1]}),
                   vset(f"vars.{sid}_t", delay)])])]

# camera-gate triggers (cartels/mosquitos) + door trigger
M += [
    gif({"and": [{"==": [V("vars.zone"), 2]}, {">": [PCX, X(16.22)]}]},
        [vset("vars.zone", 3)] + zone_vars(3)),
    gif({"and": [{"==": [V("vars.zone"), 3]}, {">": [PCX, X(23.18)]}]},
        [vset("vars.zone", 4)] + zone_vars(4)),
    gif({"and": [{"==": [V("vars.zone"), 4]}, {">": [PCX, X(27.86)]}]},
        [vset("vars.zone", 5)] + zone_vars(5)),
    # zone 5->6->7 by van deaths; 1->2 by sunk-boat wave; 0->1 by tower
]
# door trigger + wave
door_steps = []
for j, (xu, yu) in enumerate(DOOR_WAVE):
    spec = dict(crab_spec(xu + j * 0.25, yu))
    spec["id"] = f"en_dw{j}"
    spec["state"] = dict(spec["state"], grp="dw")
    door_steps.append(call("@spawn", spec))
M += [gif({"and": [{"!": V("vars.door_opened")}, {">": [PCX, X(11.74)]}]},
          [vset("vars.door_opened", True)] + door_steps)]

# --- enemies AI
M += [call("@for_each_entity", {"where_prefix": "en_", "do": [
    vset("vars._eid", "{{ loop.id }}"),
    call("@entity.get", {"id": "{{ vars._eid }}", "field": "x"}, assign="vars._ex"),
    call("@entity.get", {"id": "{{ vars._eid }}", "field": "y"}, assign="vars._ey"),
    call("@entity.get", {"id": "{{ vars._eid }}", "field": "state.hp"}, assign="vars._d"),
    gif({"<=": [V("vars._d"), 0]}, [
        # dying
        call("@entity.get", {"id": "{{ vars._eid }}", "field": "state.dieT"}, assign="vars._d"),
        gif({"==": [V("vars._d"), 0]}, [
            call("@animated_sprite.set_animation", {"id": "{{ vars._eid }}",
                "animation": IF({"<": [PCX, V("vars._ex")]}, "die_l", "die")}),
            SND("soldier_death")]),
        eadd("{{ vars._eid }}", "state.dieT", V("event.dt")),
        eset("{{ vars._eid }}", "vx", 0),
        call("@entity.get", {"id": "{{ vars._eid }}", "field": "state.dieT"}, assign="vars._d"),
        gif({">": [V("vars._d"), 1.2]}, [
            call("@entity.get", {"id": "{{ vars._eid }}", "field": "state.grp"}, assign="vars._h2"),
            gif({"==": [V("vars._h2"), "dw"]}, [vset("vars.door_kills", {"+": [V("vars.door_kills"), 1]})]),
            call("@despawn", {"id": "{{ vars._eid }}"})]),
    ], [
        # alive: gravity step
        call("@platformer.step", {"id": "{{ vars._eid }}", "map": "map",
                                  "dt": "{{ event.dt }}", "gravity": GRAV, "max_fall": MAXFALL,
                                  "one_way_types": ["platform"]}),
        gif({"and": [{"!!": {"call": "@entity.get", "args": {"id": "{{ vars._eid }}", "field": "onGround"}}},
                     {"or": [{"!!": {"call": "@entity.get", "args": {"id": "{{ vars._eid }}", "field": "state.blockedRight"}}},
                             {"!!": {"call": "@entity.get", "args": {"id": "{{ vars._eid }}", "field": "state.blockedLeft"}}}]}]},
            [eadd("{{ vars._eid }}", "y", -5)]),
        # facing + activation (signed distance quirk: active when ex - px < act)
        vset("vars._d", {"-": [V("vars._ex"), PCX]}),
        gif({"<": [V("vars._d"), {"call": "@entity.get", "args": {"id": "{{ vars._eid }}", "field": "state.act"}}]}, [
            # active: melee ladder
            gif({"<": [{"max": [V("vars._d"), {"*": [-1, V("vars._d")]}]}, 50]}, [
                # melee range: stop + tick
                eset("{{ vars._eid }}", "vx", 0),
                call("@animated_sprite.set_animation", {"id": "{{ vars._eid }}",
                    "animation": IF({"<": [PCX, {"+": [V("vars._ex"), 20]}]},
                                    IF({"==": [{"call": "@entity.get", "args": {"id": "{{ vars._eid }}", "field": "state.kind"}}, "crab"]}, "attack_l", "knife_l"),
                                    IF({"==": [{"call": "@entity.get", "args": {"id": "{{ vars._eid }}", "field": "state.kind"}}, "crab"]}, "attack", "knife"))}),
                eadd("{{ vars._eid }}", "state.meleeT", V("event.dt")),
                call("@entity.get", {"id": "{{ vars._eid }}", "field": "state.meleeT"}, assign="vars._h2"),
                gif({">": [V("vars._h2"), 0.5]}, [
                    eset("{{ vars._eid }}", "state.meleeT", 0),
                    gif({"and": [{"<": [{"max": [V("vars._d"), {"*": [-1, V("vars._d")]}]}, 55]},
                                 {"!=": [V("vars.state"), "dead"]}]},
                        [vset("vars.hp", {"-": [V("vars.hp"), 10]}), SND("melee_hit")])])],
                [  # chase
                 eset("{{ vars._eid }}", "vx",
                      IF({"<": [PCX, V("vars._ex")]},
                         {"*": [-1, {"call": "@entity.get", "args": {"id": "{{ vars._eid }}", "field": "state.spd"}}]},
                         {"call": "@entity.get", "args": {"id": "{{ vars._eid }}", "field": "state.spd"}})),
                 call("@animated_sprite.set_animation", {"id": "{{ vars._eid }}",
                     "animation": IF({"<": [PCX, V("vars._ex")]}, "walk_l", "walk")})]),
        ], [eset("{{ vars._eid }}", "vx", 0),
            call("@animated_sprite.set_animation", {"id": "{{ vars._eid }}",
                "animation": IF({"<": [PCX, V("vars._ex")]}, "idle_l", "idle")})]),
    ]),
]})]

# --- player bullets
M += [call("@for_each_entity", {"where_prefix": "pb_", "do": [
    vset("vars._eid", "{{ loop.id }}"),
    eadd("{{ vars._eid }}", "state.ttl", {"*": [-1, V("event.dt")]}),
    call("@entity.get", {"id": "{{ vars._eid }}", "field": "state.ttl"}, assign="vars._d"),
    gif({"<=": [V("vars._d"), 0]}, [call("@despawn", {"id": "{{ vars._eid }}"})], [
        call("@tiled.has_collision_type", {"map": "map", "entity": "{{ vars._eid }}", "type": "solid"}, assign="vars._h"),
        gif({"!": V("vars._h")}, [call("@tiled.has_collision_type", {"map": "map", "entity": "{{ vars._eid }}", "type": "platform"}, assign="vars._h")]),
        gif(V("vars._h"), [call("@despawn", {"id": "{{ vars._eid }}"})], [
            call("@collision.first", {"a": "{{ vars._eid }}", "where_prefix": "en_"}, assign="vars._h"),
            gif({"!=": [V("vars._h"), None]}, [
                eadd("{{ vars._h }}", "state.hp", -BULLET_DMG),
                vset("vars.score", {"+": [V("vars.score"), BULLET_DMG]}),
                SND("shot_hit"), call("@despawn", {"id": "{{ vars._eid }}"}),
                vset("vars._h", None)],
                [
                # structures: tower / enemy boat / vans / boss / vanbombs
                call("@collide.rect", {"a": "{{ vars._eid }}", "b": "tower"}, assign="vars._h"),
                gif({"and": [V("vars._h"), {"!": V("vars.tower_dead")}]}, [
                    eadd("tower", "state.hp", -BULLET_DMG),
                    vset("vars.score", {"+": [V("vars.score"), BULLET_DMG]}),
                    call("@despawn", {"id": "{{ vars._eid }}"}), SND("shot_hit")]),
                call("@collide.rect", {"a": "{{ vars._eid }}", "b": "eboat"}, assign="vars._h"),
                gif({"and": [V("vars._h"), {"!": V("vars.eboat_dead")}]}, [
                    eadd("eboat", "state.hp", -BULLET_DMG),
                    call("@despawn", {"id": "{{ vars._eid }}"}), SND("shot_hit")]),
                call("@collide.rect", {"a": "{{ vars._eid }}", "b": "van1"}, assign="vars._h"),
                gif({"and": [V("vars._h"), {"!": V("vars.van1_dead")}]}, [
                    eadd("van1", "state.hp", -BULLET_DMG),
                    vset("vars.score", {"+": [V("vars.score"), BULLET_DMG]}),
                    call("@despawn", {"id": "{{ vars._eid }}"}), SND("shot_hit")]),
                call("@collide.rect", {"a": "{{ vars._eid }}", "b": "van2"}, assign="vars._h"),
                gif({"and": [V("vars._h"), {"!": V("vars.van2_dead")}]}, [
                    eadd("van2", "state.hp", -BULLET_DMG),
                    vset("vars.score", {"+": [V("vars.score"), BULLET_DMG]}),
                    call("@despawn", {"id": "{{ vars._eid }}"}), SND("shot_hit")]),
                gif({"and": [V("vars.boss_on"), {"!": V("vars.boss_dead")}]}, [
                    call("@collide.rect", {"a": "{{ vars._eid }}", "b": "boss"}, assign="vars._h"),
                    gif(V("vars._h"), [
                        eadd("boss", "state.hp", -BULLET_DMG),
                        vset("vars.score", {"+": [V("vars.score"), BULLET_DMG]}),
                        call("@despawn", {"id": "{{ vars._eid }}"}), SND("shot_hit")])]),
                call("@collision.first", {"a": "{{ vars._eid }}", "where_prefix": "vb_"}, assign="vars._h"),
                gif({"!=": [V("vars._h"), None]}, [
                    call("@despawn", {"id": "{{ vars._h }}"}),
                    call("@despawn", {"id": "{{ vars._eid }}"}),
                    SND("grenade_hit"), vset("vars._h", None)]),
            ]),
        ]),
    ]),
]})]

# --- player grenades (arc + contact damage 300)
GB = G("grenade")["anims"]["boom"]
M += [call("@for_each_entity", {"where_prefix": "pg_", "do": [
    vset("vars._eid", "{{ loop.id }}"),
    eadd("{{ vars._eid }}", "vy", {"*": [GREN_G, V("event.dt")]}),
    eadd("{{ vars._eid }}", "state.ttl", {"*": [-1, V("event.dt")]}),
    call("@entity.get", {"id": "{{ vars._eid }}", "field": "x"}, assign="vars._ex"),
    call("@entity.get", {"id": "{{ vars._eid }}", "field": "y"}, assign="vars._ey"),
    call("@collision.first", {"a": "{{ vars._eid }}", "where_prefix": "en_"}, assign="vars._h"),
    call("@tiled.has_collision_type", {"map": "map", "entity": "{{ vars._eid }}", "type": "solid"}, assign="vars._h2"),
    gif({"!": V("vars._h2")}, [call("@tiled.has_collision_type", {"map": "map", "entity": "{{ vars._eid }}", "type": "platform"}, assign="vars._h2")]),
    call("@entity.get", {"id": "{{ vars._eid }}", "field": "state.ttl"}, assign="vars._d"),
    gif({"or": [{"!=": [V("vars._h"), None]}, {"!!": V("vars._h2")}, {"<=": [V("vars._d"), 0]}]}, [
        gif({"!=": [V("vars._h"), None]}, [
            eadd("{{ vars._h }}", "state.hp", -GREN_DMG),
            vset("vars.score", {"+": [V("vars.score"), GREN_DMG]})]),
        # splash vs structures
        gif({"and": [{"!": V("vars.van1_dead")}, {"<": [{"max": [{"-": [V("vars._ex"), X(36.156)]}, {"-": [X(36.156), V("vars._ex")]}]}, 90]}]},
            [eadd("van1", "state.hp", -GREN_DMG), vset("vars.score", {"+": [V("vars.score"), GREN_DMG]})]),
        gif({"and": [{"!": V("vars.van2_dead")}, {"<": [{"max": [{"-": [V("vars._ex"), X(40.383)]}, {"-": [X(40.383), V("vars._ex")]}]}, 90]}]},
            [eadd("van2", "state.hp", -GREN_DMG), vset("vars.score", {"+": [V("vars.score"), GREN_DMG]})]),
        gif({"and": [{"!": V("vars.eboat_dead")}, {"<": [{"max": [{"-": [V("vars._ex"), X(30.922)]}, {"-": [X(30.922), V("vars._ex")]}]}, 90]}]},
            [eadd("eboat", "state.hp", -GREN_DMG)]),
        gif({"and": [{"!": V("vars.tower_dead")}, {"<": [{"max": [{"-": [V("vars._ex"), X(7.13)]}, {"-": [X(7.13), V("vars._ex")]}]}, 60]}]},
            [eadd("tower", "state.hp", -GREN_DMG), vset("vars.score", {"+": [V("vars.score"), GREN_DMG]})]),
        gif({"and": [V("vars.boss_on"), {"!": V("vars.boss_dead")}]}, [
            call("@collide.rect", {"a": "{{ vars._eid }}", "b": "boss"}, assign="vars._h2"),
            gif(V("vars._h2"), [eadd("boss", "state.hp", -GREN_DMG),
                                vset("vars.score", {"+": [V("vars.score"), GREN_DMG]})])]),
        vset("vars.seq", {"+": [V("vars.seq"), 1]}),
        oneshot("grenade", "boom", [{"-": [V("vars._ex"), 22]}, {"-": [V("vars._ey"), 100]}], 62),
        SND("grenade_hit"),
        call("@despawn", {"id": "{{ vars._eid }}"}), vset("vars._h", None)]),
]})]

# --- vans
VB = G("vanbomb")
for vi, vx_u in ((1, 36.156), (2, 40.383)):
    vid = f"van{vi}"
    M += [gif({"and": [{"!": V(f"vars.van{vi}_dead")}]}, [
        gif({"<=": [{"call": "@entity.get", "args": {"id": vid, "field": "state.hp"}}, 0]}, [
            vset(f"vars.van{vi}_dead", True), SND("destroy1"),
            call("@animated_sprite.set_animation", {"id": vid, "animation": "die"}),
            vset("vars.seq", {"+": [V("vars.seq"), 1]}),
            # bridge collapse: swap art + camera zone advance
            gif({"==": [str(vi), "1"]},
                [vset("vars.zone", 6)] + zone_vars(6),
                [vset("vars.zone", 7)] + zone_vars(7)),
        ], [
            # active: bomb rain every 5s (4 bombs), gated on player proximity (signed)
            gif({"<": [{"-": [X(vx_u), PCX]}, 350]}, [
                eadd(vid, "state.fireT", {"*": [-1, V("event.dt")]}),
                gif({"<=": [{"call": "@entity.get", "args": {"id": vid, "field": "state.fireT"}}, 0]}, [
                    eset(vid, "state.fireT", 5.0),
                    call("@animated_sprite.set_animation", {"id": vid, "animation": "fire"})] + sum([[
                    vset("vars.seq", {"+": [V("vars.seq"), 1]}),
                    call("@spawn", {"id": f"vb_{{{{ vars.seq }}}}", "kind": "animated_sprite",
                                    "priority": 44, "asset": SPR + VB["anims"]["fly"]["file"],
                                    "frame_size": VB["cell"], "frames": VB["anims"]["fly"]["frames"],
                                    "frames_per_row": VB["anims"]["fly"]["frames"], "step_time": 0.125,
                                    "position": [{"+": [X(vx_u) - 21, {"call": "@random_int", "args": {"min": -100, "max": 100}}]}, Y(-0.1)],
                                    "size": [16, 28], "velocity": [0, 10], "auto_update": True,
                                    "state": {"ttl": 8, "assetLoadingOverlay": False}})] for _ in range(4)], [])),
            ]),
        ]),
    ])]

# van bombs: slow fall (gravityScale 0.01), hit player 15, terrain -> boom
M += [call("@for_each_entity", {"where_prefix": "vb_", "do": [
    vset("vars._eid", "{{ loop.id }}"),
    eadd("{{ vars._eid }}", "vy", {"*": [9.81, V("event.dt")]}),
    eadd("{{ vars._eid }}", "state.ttl", {"*": [-1, V("event.dt")]}),
    call("@entity.get", {"id": "{{ vars._eid }}", "field": "state.ttl"}, assign="vars._d"),
    call("@collide.rect", {"a": "{{ vars._eid }}", "b": "player"}, assign="vars._h"),
    call("@tiled.has_collision_type", {"map": "map", "entity": "{{ vars._eid }}", "type": "solid"}, assign="vars._h2"),
    gif({"!": V("vars._h2")}, [call("@tiled.has_collision_type", {"map": "map", "entity": "{{ vars._eid }}", "type": "platform"}, assign="vars._h2")]),
    gif({"or": [{"!!": V("vars._h")}, {"!!": V("vars._h2")}, {"<=": [V("vars._d"), 0]}]}, [
        gif({"and": [{"!!": V("vars._h")}, {"!=": [V("vars.state"), "dead"]}]},
            [vset("vars.hp", {"-": [V("vars.hp"), 15]}), SND("grenade_hit")]),
        call("@entity.get", {"id": "{{ vars._eid }}", "field": "x"}, assign="vars._ex"),
        call("@entity.get", {"id": "{{ vars._eid }}", "field": "y"}, assign="vars._ey"),
        vset("vars.seq", {"+": [V("vars.seq"), 1]}),
        oneshot("vanbomb", "boom", [{"-": [V("vars._ex"), 13]}, {"-": [V("vars._ey"), 30]}], 62),
        call("@despawn", {"id": "{{ vars._eid }}"}), vset("vars._h", None)]),
]})]

# --- tower / enemy boat deaths
M += [
    gif({"and": [{"!": V("vars.tower_dead")},
                 {"<=": [{"call": "@entity.get", "args": {"id": "tower", "field": "state.hp"}}, 0]}]}, [
        vset("vars.tower_dead", True), SND("destroy2"),
        eset("tower", "render.src", TOWER_DESTROYED) if False else vset("vars._h", None),
        # swap art: move destroyed crop entity in, hide tower
        eset("tower", "state.opacity", 0.35),
        vset("vars.zone", 1)] + zone_vars(1)),
    gif({"and": [{"!": V("vars.eboat_dead")},
                 {"<=": [{"call": "@entity.get", "args": {"id": "eboat", "field": "state.hp"}}, 0]}]}, [
        vset("vars.eboat_dead", True), SND("destroy2"),
        vset("vars.seq", {"+": [V("vars.seq"), 1]}),
        oneshot("fx_boat", "boom", [{"-": [V("entities.eboat.x"), 0]}, {"-": [V("entities.eboat.y"), 20]}], 62),
        eset("eboat", "state.opacity", 0.3)]),
    # sunk-boat wave cleared -> zone 1B->1C + explosion
    gif({"and": [{"==": [V("vars.zone"), 1]}, {">=": [V("vars.door_kills"), 3]}]}, [
        vset("vars.seq", {"+": [V("vars.seq"), 1]}),
        oneshot("fx_huge", "boom", [X(13.9) - 56, Y(-0.07) - 60], 62),
        SND("destroy2"), vset("vars.zone", 2)] + zone_vars(2)),
]

# --- boss ---
BOSS_SPAWN_X = X(46.333)
M += [
    gif({"and": [{"!": V("vars.boss_on")}, {">": [PCX, BOSS_SPAWN_X]}]}, [
        vset("vars.boss_on", True), vset("vars.boss_rising", True),
        call("@audio.stop", {"id": "bgm"}),
        call("@audio.play", {"id": "boss_bgm", "loop": True}),
        call("@animated_sprite.set_animation", {"id": "boss", "animation": "spawn"}),
        vset("vars.zone", 8)] + zone_vars(8) + [vset("vars.autoscroll", True)]),
    gif({"and": [V("vars.boss_rising"), {">": [V("entities.boss.y"), Y(-0.1) - 160]}]},
        [eadd("boss", "y", {"*": [-50, V("event.dt")]})],
        [gif(V("vars.boss_rising"),
             [vset("vars.boss_rising", False),
              call("@animated_sprite.set_animation", {"id": "boss", "animation": "walk"})])]),
    gif({"and": [V("vars.boss_on"), {"!": V("vars.boss_rising")}, {"!": V("vars.boss_dead")}]}, [
        # death check
        gif({"<=": [{"call": "@entity.get", "args": {"id": "boss", "field": "state.hp"}}, 0]}, [
            vset("vars.boss_dead", True), vset("vars.won", True), vset("vars.autoscroll", False),
            call("@animated_sprite.set_animation", {"id": "boss", "animation": "die"}),
            call("@audio.stop", {"id": "boss_bgm"}), SND("destroy3"), SND("v_complete"),
            call("@spawn", {"id": "win_t", "kind": "pixel", "priority": 232,
                            "position": [92, 90], "size": [1, 1], "fixed_to_screen": True,
                            "render": {"shape": "text", "value": "MISSION COMPLETE",
                                       "color": "#FFD24A", "fontSize": 22}}),
            call("@game_over", {})], [
            # sprint cycle
            eadd("boss", "state.sprintT", {"*": [-1, V("event.dt")]}),
            gif({"<=": [{"call": "@entity.get", "args": {"id": "boss", "field": "state.sprintT"}}, 0]}, [
                eadd("boss", "state.sprintPh", 1),
                gif({"==": [{"call": "@entity.get", "args": {"id": "boss", "field": "state.sprintPh"}}, 1]},
                    [eset("boss", "state.spd", 0), eset("boss", "state.sprintT", 1.5)]),
                gif({"==": [{"call": "@entity.get", "args": {"id": "boss", "field": "state.sprintPh"}}, 2]},
                    [eset("boss", "state.spd", 200), eset("boss", "state.sprintT", 1.2)]),
                gif({"==": [{"call": "@entity.get", "args": {"id": "boss", "field": "state.sprintPh"}}, 3]},
                    [eset("boss", "state.spd", 10), eset("boss", "state.sprintT", 1.0)]),
                gif({">=": [{"call": "@entity.get", "args": {"id": "boss", "field": "state.sprintPh"}}, 4]},
                    [eset("boss", "state.spd", 75), eset("boss", "state.sprintT", 5.0),
                     eset("boss", "state.sprintPh", 0)])]),
            eadd("boss", "x", {"*": [{"call": "@entity.get", "args": {"id": "boss", "field": "state.spd"}}, V("event.dt")]}),
            # bombs every 3s: normal above half hp, heavy below
            eadd("boss", "state.fireT", {"*": [-1, V("event.dt")]}),
            gif({"<=": [{"call": "@entity.get", "args": {"id": "boss", "field": "state.fireT"}}, 0]}, [
                eset("boss", "state.fireT", 3.0),
                vset("vars.seq", {"+": [V("vars.seq"), 1]}),
                vset("vars._h2", {">": [{"call": "@entity.get", "args": {"id": "boss", "field": "state.hp"}}, 5000]}),
                call("@spawn", {"id": "bb_{{ vars.seq }}", "kind": "animated_sprite", "priority": 44,
                                "asset": SPR + BB_G["anims"]["fly"]["file"], "frame_size": BB_G["cell"],
                                "frames": BB_G["anims"]["fly"]["frames"],
                                "frames_per_row": BB_G["anims"]["fly"]["frames"], "step_time": 0.16,
                                "position": [{"+": [V("entities.boss.x"), 40]}, {"+": [V("entities.boss.y"), 30]}],
                                "size": [30, 40], "auto_update": True,
                                "velocity": [-247, -247],
                                "state": {"ttl": 5, "heavy": IF(V("vars._h2"), 0, 1), "assetLoadingOverlay": False}})]),
            # contact damage
            call("@collide.rect", {"a": "player", "b": "boss"}, assign="vars._h"),
            gif({"and": [{"!!": V("vars._h")}, {"!=": [V("vars.state"), "dead"]}]}, [
                vset("vars.hp", {"-": [V("vars.hp"), {"*": [10, V("event.dt"), 3]}]})]),
            # bridge eating: segment behind boss front
            [gif({"and": [{"<": [V(f"vars.boss_seg"), b["seg"] + 1]},
                          {">": [V("entities.boss.x"), X(b["xu"]) + 30]}]}, [
                vset("vars.boss_seg", b["seg"] + 1),
                call("@tiled.remove_object", {"map": "map", "layer": "collision", "object_id": b["oid"]}),
                call("@despawn", {"id": f"bseg_{b['seg']}"}),
                vset("vars.seq", {"+": [V("vars.seq"), 1]}),
                oneshot("fx_bridge", "boom", [X(b["xu"]) - 40, Y(-0.86) - 80], 62)])
             for b in BRIDGE][0] if False else vset("vars._h", None),
        ]),
    ]),
]
# unrolled bridge eating (kept outside the nested list-comprehension mess)
for b in BRIDGE:
    M += [gif({"and": [V("vars.boss_on"), {"!": V("vars.boss_dead")},
                       {"==": [V("vars.boss_seg"), b["seg"]]},
                       {">": [V("entities.boss.x"), X(b["xu"]) + 34]}]}, [
        vset("vars.boss_seg", b["seg"] + 1),
        call("@tiled.remove_object", {"map": "map", "layer": "collision", "object_id": b["oid"]}),
        call("@despawn", {"id": f"bseg_{b['seg']}"}),
        vset("vars.seq", {"+": [V("vars.seq"), 1]}),
        oneshot("fx_bridge", "boom", [X(b["xu"]) - 40, Y(-0.86) - 80], 62)])]

# boss bombs (25/50 dmg, heavy destroys nothing extra here — bridge handled above)
BBB = G("bossbomb")
M += [call("@for_each_entity", {"where_prefix": "bb_", "do": [
    vset("vars._eid", "{{ loop.id }}"),
    eadd("{{ vars._eid }}", "vy", {"*": [GREN_G, V("event.dt")]}),
    eadd("{{ vars._eid }}", "state.ttl", {"*": [-1, V("event.dt")]}),
    call("@entity.get", {"id": "{{ vars._eid }}", "field": "state.ttl"}, assign="vars._d"),
    call("@collide.rect", {"a": "{{ vars._eid }}", "b": "player"}, assign="vars._h"),
    call("@tiled.has_collision_type", {"map": "map", "entity": "{{ vars._eid }}", "type": "solid"}, assign="vars._h2"),
    gif({"!": V("vars._h2")}, [call("@tiled.has_collision_type", {"map": "map", "entity": "{{ vars._eid }}", "type": "platform"}, assign="vars._h2")]),
    gif({"or": [{"!!": V("vars._h")}, {"!!": V("vars._h2")}, {"<=": [V("vars._d"), 0]}]}, [
        call("@entity.get", {"id": "{{ vars._eid }}", "field": "state.heavy"}, assign="vars._d"),
        gif({"and": [{"!!": V("vars._h")}, {"!=": [V("vars.state"), "dead"]}]},
            [vset("vars.hp", {"-": [V("vars.hp"), IF({"==": [V("vars._d"), 1]}, 50, 25)]}),
             SND("grenade_hit")]),
        call("@entity.get", {"id": "{{ vars._eid }}", "field": "x"}, assign="vars._ex"),
        call("@entity.get", {"id": "{{ vars._eid }}", "field": "y"}, assign="vars._ey"),
        vset("vars.seq", {"+": [V("vars.seq"), 1]}),
        oneshot("bossbomb", "boom", [{"-": [V("vars._ex"), 20]}, {"-": [V("vars._ey"), 40]}], 62),
        call("@despawn", {"id": "{{ vars._eid }}"}), vset("vars._h", None)]),
]})]

# --- collectibles pickup
M += [
    gif({"!": V("vars._h")} if False else {"==": [1, 1]}, []),  # no-op spacer
]
for key, effect in (
    ("hmg", [vset("vars.mg", {"+": [V("vars.mg"), 120]}), SND("v_hmg"), SND("equip")]),
    ("ammo", [vset("vars.bombs", {"+": [V("vars.bombs"), 10]}), SND("grab"), SND("v_okay")]),
    ("medkit", [vset("vars.hp", {"min": [HP0, {"+": [V("vars.hp"), 20]}]}), SND("grab")]),
):
    M += [gif(call("@entity.exists", {"id": f"col_{key}"}), [
        call("@collide.rect", {"a": "player", "b": f"col_{key}"}, assign="vars._h"),
        gif({"!!": V("vars._h")},
            [call("@despawn", {"id": f"col_{key}"}),
             vset("vars.score", {"+": [V("vars.score"), 1000]})] + effect + [vset("vars._h", None)])])]

# --- camera
M += [
    gif(V("vars.autoscroll"),
        [vset("vars.cam_x", {"min": [V("vars.cam_max"), {"+": [V("vars.cam_x"), {"*": [70, V("event.dt")]}]}]})],
        [vset("vars._d", {"min": [V("vars.cam_max"), {"max": [V("vars.cam_min"), {"+": [PCX, 117.6]}]}]}),
         vset("vars.cam_x", {"+": [V("vars.cam_x"),
              {"*": [{"-": [V("vars._d"), V("vars.cam_x")]}, {"min": [1, {"*": [5, V("event.dt")]}]}]}]})]),
    eset("cam", "x", V("vars.cam_x")),
    eset("cam", "y", V("vars.cam_cy")),
    # player edge clamp (3% viewport = 12px)
    gif({"and": [{"<": [PCX, {"-": [V("vars.cam_x"), 184]}]},
                 {">": [PCX, {"-": [V("vars.cam_x"), 284]}]}]},
        [eset("player", "x", {"-": [V("vars.cam_x"), 194.5]})]),
    gif({"and": [{">": [PCX, {"+": [V("vars.cam_x"), 184]}]},
                 {"<": [PCX, {"+": [V("vars.cam_x"), 284]}]}]},
        [eset("player", "x", {"+": [V("vars.cam_x"), 173.5]})]),
    # cloud parallax pin (factor ~0.55 toward camera)
    eset("art_0", "x", {"+": [X(10.302) - ATLAS["slices"]["foreground_cloud_forest"][2] / 2,
                              {"*": [0.55, {"-": [V("vars.cam_x"), X(3.172)]}]}]}),
]

# --- HUD + death/win
M += [
    eset("hud_hp", "w", {"max": [0, {"*": [1.1, V("vars.hp")]}]}),
    eset("hud_score", "render.value", V("vars.score")),
    eset("hud_bombs", "render.value", {"cat": ["x ", V("vars.bombs")]}),
    eset("hud_ammo", "render.value", IF({">": [V("vars.mg"), 0]}, V("vars.mg"), "oo")),
    # hazard water / fall
    gif({"or": [V("entities.player.hazard"), {">": [V("entities.player.y"), 350]}]},
        [vset("vars.hp", 0)]),
    gif({"and": [{"<=": [V("vars.hp"), 0]}, {"!=": [V("vars.state"), "dead"]}, {"!": V("vars.won")}]}, [
        vset("vars.state", "dead"), SND("marco_death"),
        call("@audio.stop", {"id": "bgm"}), call("@audio.stop", {"id": "boss_bgm"}),
        call("@animated_sprite.set_animation", {"id": "player", "animation": "death"})]),
    gif({"==": [V("vars.state"), "dead"]}, [
        vset("vars.dieT", {"+": [V("vars.dieT"), V("event.dt")]}),
        gif({">": [V("vars.dieT"), 2.4]}, [call("@game_over", {})])]),
]

FRAME_LOGIC = [gif(RUN, M),
               gif({"==": [V("vars.state"), "dead"]}, [
                   eset("player", "vx", 0),
                   call("@platformer.step", {"id": "player", "map": "map", "dt": "{{ event.dt }}",
                                             "gravity": GRAV, "max_fall": MAXFALL}),
                   vset("vars.dieT", {"+": [V("vars.dieT"), V("event.dt")]}),
                   gif({">": [V("vars.dieT"), 2.4]}, [call("@game_over", {})])])]

game = {
    "type": "flame_game",
    "world": {"kind": "pixel", "bg": "#3888C8"},
    "viewport": {"width": VW, "height": VH, "fit": "contain"},
    "physics": {"engine": "leap_platformer", "fallback": "aabb_platformer"},
    "camera": {"follow": "cam", "offset_x": 0, "offset_y": 0, "deadzone_y": 0, "smooth_y": 1},
    "overlay": {"score": False, "game_over": True, "asset_loading": True,
                "asset_loading_text": "Loading Metal Slug assets..."},
    "vars": VARS,
    "entities": entities,
    "input": INPUT,
    "frame": {"logic": FRAME_LOGIC},
    "audio": {
        "base_url": AUD,
        "tracks": {"bgm": {"src": "m1_bgm.mp3", "loop": True, "volume": 0.4},
                   "boss_bgm": {"src": "boss_bgm.mp3", "loop": True, "volume": 0.4}},
        "sounds": {"shot": {"src": "shot.mp3", "volume": 0.5},
                   "heavy_shot": {"src": "heavy_shot.mp3", "volume": 0.5},
                   "shot_hit": {"src": "shot_hit.mp3", "volume": 0.45},
                   "melee_hit": {"src": "melee_hit.mp3", "volume": 0.55},
                   "grenade_hit": {"src": "grenade_hit.mp3", "volume": 0.55},
                   "grab": {"src": "grab.mp3", "volume": 0.6},
                   "equip": {"src": "equip.mp3", "volume": 0.6},
                   "destroy1": {"src": "destroy1.mp3", "volume": 0.6},
                   "destroy2": {"src": "destroy2.mp3", "volume": 0.6},
                   "destroy3": {"src": "destroy3.mp3", "volume": 0.6},
                   "marco_death": {"src": "marco_death.mp3", "volume": 0.7},
                   "soldier_death": {"src": "soldier_death.mp3", "volume": 0.5},
                   "v_start": {"src": "mission1_start.wav", "volume": 0.8},
                   "v_complete": {"src": "mission_complete.wav", "volume": 0.8},
                   "v_hmg": {"src": "hmg_voice.wav", "volume": 0.8},
                   "v_okay": {"src": "okay.wav", "volume": 0.8}},
    },
}

entities_m1_player = entities["player"]
entities_m1_torso = entities["torso"]

# ======================= Missions 2 / 3 / 3Boss =======================
# 共享系统工厂：玩家/武器/HUD/相机 复刻 M1 的成熟块；通用敌人 AI 阶梯
# （EnemyControl 语义：melee > ranged > chase，全部 state 驱动）覆盖
# soldier/crab/zombie1-3/maggot/caterpillar。

import math

SGREN = G("sgrenade")
VOM1 = G("zombie1")  # vomit anim rides the zombie group cells


def mk_player(spawn_xu, spawn_yu):
    ents = {}
    ents["player"] = json.loads(json.dumps(entities_m1_player))
    ents["player"]["position"] = [X(spawn_xu) - 10.5, Y(spawn_yu) - 19.5]
    ents["torso"] = json.loads(json.dumps(entities_m1_torso))
    return ents


def mk_hud_title(mission_label, credit=True):
    ents = {}
    for k in ("hud_hpb", "hud_hp", "hud_score", "hud_gicon", "hud_bombs", "hud_ammo"):
        ents[k] = json.loads(json.dumps(entities[k]))
    ents["title_bg"] = json.loads(json.dumps(entities["title_bg"]))
    ents["title_t"] = dict(json.loads(json.dumps(entities["title_t"])),
                           position=[60, 70])
    ents["title_t"]["render"] = dict(ents["title_t"]["render"],
                                     value=f"METAL SLUG — {mission_label}")
    ents["title_s"] = json.loads(json.dumps(entities["title_s"]))
    ents["title_c"] = json.loads(json.dumps(entities["title_c"]))
    return ents


def mk_input(bgm_id, voice_id):
    start = [vset("vars.state", "running"),
             call("@despawn", {"id": "title_bg"}), call("@despawn", {"id": "title_t"}),
             call("@despawn", {"id": "title_s"}), call("@despawn", {"id": "title_c"}),
             call("@audio.play", {"id": bgm_id, "loop": True, "restart": True}),
             SND(voice_id)]
    return {
        "move_axis": [
            gif(TITLE, start),
            vset("vars.move", IF({">": [V("event.x"), 0.5]}, 1,
                                 IF({"<": [V("event.x"), -0.5]}, -1, 0))),
            gif({">": [V("event.x"), 0.5]}, [vset("vars.facing", 1)]),
            gif({"<": [V("event.x"), -0.5]}, [vset("vars.facing", -1)]),
            vset("vars.aimup", {"<": [V("event.y"), -0.5]}),
            vset("vars.duck", {">": [V("event.y"), 0.5]}),
        ],
        "jump": [gif(TITLE, start, [vset("vars.jumpp", True)])],
        "jump_end": [vset("vars._noop", 0)],
        "attack": [gif(TITLE, start, [vset("vars.firep", True)])],
        "attack_end": [vset("vars.firep", False) if False else vset("vars._noop", 0)],
        "grenade": [gif(TITLE, start, [vset("vars.grenp", True)])],
        "tap": [gif(TITLE, start)],
    }


def mk_vars(cam0_x, cam0_min, cam0_max, cam0_cy):
    v = {
        "state": "title", "hp": HP0, "score": 0, "bombs": BOMBS0, "mg": 0,
        "move": 0, "aimup": False, "duck": False, "was_duck": False,
        "jumpp": False, "firep": False, "grenp": False,
        "fire_cd": 0, "burst": 0, "burst_t": 0, "seq": 0,
        "grounded": False, "on_plat": False, "facing": 1,
        "cam_x": cam0_x, "cam_min": cam0_min, "cam_max": cam0_max,
        "cam_cy": cam0_cy, "zone": 0,
        "throwT": 0, "meleeT": 0, "topanim": "p_idle", "bodyanim": "idle",
        "_h": None, "_h2": None, "_eid": "", "_ex": 0, "_ey": 0, "_d": 0,
        "_d2": 0, "won": False, "dieT": 0, "_noop": 0,
    }
    return v


def mk_player_main(y_kill_px):
    """timers + movement + crouch + fire/melee/grenade + torso anim/pin"""
    M = []
    M += [vset("vars.fire_cd", {"max": [0, {"-": [V("vars.fire_cd"), V("event.dt")]}]})]
    M += [
        eset("player", "vx", IF({"==": [V("vars.state"), "dead"]}, 0,
            IF({"and": [V("vars.duck"), {"or": [V("vars.grounded"), V("vars.on_plat")]}]},
               {"*": [V("vars.move"), CSPEED]},
               {"*": [V("vars.move"), PSPEED]}))),
        gif({"and": [V("vars.jumpp"), {"or": [V("vars.grounded"), V("vars.on_plat")]},
                     {"!": V("vars.duck")}, {"!=": [V("vars.state"), "dead"]}]},
            [eset("player", "vy", JUMP_VY), eadd("player", "y", -3),
             vset("vars.on_plat", False)]),
        vset("vars.jumpp", False),
        call("@platformer.step", {"id": "player", "map": "map", "dt": "{{ event.dt }}",
                                  "gravity": GRAV, "max_fall": MAXFALL,
                                  "one_way_types": ["platform"]}),
        vset("vars.grounded", V("entities.player.onGround")),
        gif({"and": [V("vars.grounded"), {"!=": [V("vars.move"), 0]},
                     {"or": [{"!!": V("entities.player.blockedRight")},
                             {"!!": V("entities.player.blockedLeft")}]}]},
            [eadd("player", "y", -5)]),
        vset("vars.on_plat", False),
    ]
    M += [
        gif({"and": [V("vars.duck"), V("vars.grounded"), {"!": V("vars.was_duck")}]},
            [eset("player", "h", 18), eadd("player", "y", 21), vset("vars.was_duck", True)]),
        gif({"and": [{"!": V("vars.duck")}, V("vars.was_duck")]},
            [eset("player", "h", 39), eadd("player", "y", -21), vset("vars.was_duck", False)]),
    ]
    # fire / melee / grenade (same shapes as M1)
    M += [
        gif({"and": [RUN, V("vars.firep"), {"<=": [V("vars.fire_cd"), 0]}]}, [
            call("@collision.first", {"a": "player", "where_prefix": "en_"}, assign="vars._h"),
            gif({"!=": [V("vars._h"), None]},
                [vset("vars.fire_cd", FIRE_CD),
                 eadd("{{ vars._h }}", "state.hp", -MELEE_DMG),
                 vset("vars.score", {"+": [V("vars.score"), MELEE_DMG]}),
                 SND("melee_hit"), vset("vars.meleeT", 0.5), vset("vars._h", None)],
                FIRE_STEPS),
        ]),
        vset("vars.firep", False),
        gif({">": [V("vars.burst"), 0]}, [
            vset("vars.burst_t", {"-": [V("vars.burst_t"), V("event.dt")]}),
            gif({"<=": [V("vars.burst_t"), 0]}, [
                vset("vars.seq", {"+": [V("vars.seq"), 1]}),
                gif(V("vars.aimup"), [spawn_pbullet(1)], [spawn_pbullet(0)]),
                vset("vars.burst", {"-": [V("vars.burst"), 1]}),
                vset("vars.burst_t", 0.05)])]),
        vset("vars.meleeT", {"max": [0, {"-": [V("vars.meleeT"), V("event.dt")]}]}),
        gif({"and": [RUN, V("vars.grenp"), {"<=": [V("vars.fire_cd"), 0]}, {">": [V("vars.bombs"), 0]}]}, [
            vset("vars.bombs", {"-": [V("vars.bombs"), 1]}),
            vset("vars.seq", {"+": [V("vars.seq"), 1]}),
            call("@spawn", {"id": "pg_{{ vars.seq }}", "kind": "animated_sprite", "priority": 45,
                            "asset": SPR + GREN_A["file"], "frame_size": G("grenade")["cell"],
                            "frames": GREN_A["frames"], "frames_per_row": GREN_A["frames"],
                            "step_time": 0.125, "position": [PCX, {"-": [PCY, 10]}],
                            "size": [14, 20], "auto_update": True,
                            "velocity": [{"*": [V("vars.facing"), GREN_V]}, -GREN_V],
                            "state": {"ttl": 4, "assetLoadingOverlay": False}}),
            vset("vars.fire_cd", FIRE_CD), vset("vars.throwT", 0.5)]),
        vset("vars.grenp", False),
        vset("vars.throwT", {"max": [0, {"-": [V("vars.throwT"), V("event.dt")]}]}),
    ]
    # body/torso anims + pin (verbatim M1 shapes)
    M += [
        vset("vars.bodyanim", IF({"==": [V("vars.state"), "dead"]}, "death",
            IF({"and": [V("vars.duck"), GROUNDED]},
               IF({">": [V("vars.meleeT"), 0]}, "c_melee",
                  IF({">": [V("vars.throwT"), 0]}, "c_throw",
                     IF({"!=": [V("entities.player.vx"), 0]}, "c_walk", "c_idle"))),
               IF({"!": GROUNDED},
                  IF({"!=": [V("entities.player.vx"), 0]}, "jump_walk", "jump"),
                  IF({"!=": [V("entities.player.vx"), 0]}, "walk", "idle"))))),
        vset("vars.bodyanim", IF({"==": [V("vars.facing"), 1]}, V("vars.bodyanim"),
                                 {"cat": [V("vars.bodyanim"), "_l"]})),
        call("@animated_sprite.set_animation", {"id": "player", "animation": "{{ vars.bodyanim }}"}),
        eset("player", "state.spriteOffsetX",
             IF({"==": [V("vars.facing"), 1]}, round(10.5 - AXB, 1), round(10.5 - (CWB - AXB), 1))),
        eset("player", "state.spriteOffsetY", round(19.5 - PTYB, 1)),
        gif({"or": [{"and": [V("vars.duck"), GROUNDED]}, {"==": [V("vars.state"), "dead"]}]},
            [eset("torso", "state.opacity", 0)],
            [eset("torso", "state.opacity", 1),
             vset("vars.topanim",
                  IF({">": [V("vars.meleeT"), 0]}, IF({">": [V("vars.mg"), 0]}, "m_melee", "melee"),
                  IF({">": [V("vars.throwT"), 0]}, IF({">": [V("vars.mg"), 0]}, "m_throw", "throw"),
                  IF(V("vars.aimup"),
                     IF({">": [V("vars.fire_cd"), FIRE_CD - 0.15]}, "p_fire_up", "p_up"),
                     IF({"!": GROUNDED},
                        IF({"<": [V("entities.player.vy"), 0]}, "p_jump_up", "p_jump_down"),
                        IF({">": [V("vars.fire_cd"), FIRE_CD - 0.15]},
                           IF({">": [V("vars.mg"), 0]}, "m_fire", "p_fire"),
                           IF({">": [V("vars.mg"), 0]}, "m_idle",
                              IF({"!=": [V("entities.player.vx"), 0]}, "p_walk", "p_idle")))))))),
             vset("vars.topanim", IF({"==": [V("vars.facing"), 1]}, V("vars.topanim"),
                                     {"cat": [V("vars.topanim"), "_l"]})),
             call("@animated_sprite.set_animation", {"id": "torso", "animation": "{{ vars.topanim }}"}),
             eset("torso", "x", IF({"==": [V("vars.facing"), 1]},
                                   {"+": [PCX, round(13.5 - AXT, 1)]},
                                   {"+": [PCX, round(-13.5 - (CWT - AXT), 1)]})),
             eset("torso", "y", {"-": [PCY, round(PTYT, 1) + 6]})]),
    ]
    # hazard / fall death (flag + collision-type fallback)
    M += [
        call("@tiled.has_collision_type", {"map": "map", "entity": "player", "type": "hazard"},
             assign="vars._h2"),
        gif({"or": [V("entities.player.hazard"), {"!!": V("vars._h2")},
                    {">": [V("entities.player.y"), y_kill_px]}]},
            [vset("vars.hp", 0)]),
    ]
    return M


def mk_enemy_loop():
    """通用 EnemyControl 阶梯（state 驱动）：melee > ranged(vomit/grenade) > chase。
    state: kind, hp, spd, act, meleeR, atkR, dmg, canMelee, canThrow, throwKind,
           rangedT, meleeT, dieT, grav, atkAnim"""
    def eget(f):
        return {"call": "@entity.get", "args": {"id": "{{ vars._eid }}", "field": f}}
    throw_vomit = [
        vset("vars.seq", {"+": [V("vars.seq"), 1]}),
        call("@spawn", {"id": "eg_{{ vars.seq }}", "kind": "animated_sprite", "priority": 44,
                        "asset": SPR + VOM1["anims"]["vomit"]["file"], "frame_size": VOM1["cell"],
                        "frames": VOM1["anims"]["vomit"]["frames"],
                        "frames_per_row": VOM1["anims"]["vomit"]["frames"],
                        "step_time": 0.084, "size": [25, 15], "auto_update": True,
                        "position": [{"+": [V("vars._ex"), 20]}, {"+": [V("vars._ey"), 10]}],
                        "velocity": [{"*": [IF({"<": [PCX, V("vars._ex")]}, -1, 1), 176.8]}, -176.8],
                        "state": {"ttl": 3, "dmg": 25, "assetLoadingOverlay": False}}),
        SND("zombie_vomit"),
    ]
    throw_gren = [
        vset("vars.seq", {"+": [V("vars.seq"), 1]}),
        call("@spawn", {"id": "eg_{{ vars.seq }}", "kind": "animated_sprite", "priority": 44,
                        "asset": SPR + SGREN["anims"]["fly"]["file"], "frame_size": SGREN["cell"],
                        "frames": SGREN["anims"]["fly"]["frames"],
                        "frames_per_row": SGREN["anims"]["fly"]["frames"],
                        "step_time": 0.084, "size": [16, 20], "auto_update": True,
                        "position": [{"+": [V("vars._ex"), 14]}, V("vars._ey")],
                        "velocity": [{"*": [IF({"<": [PCX, V("vars._ex")]}, -1, 1), 141]}, -141],
                        "state": {"ttl": 3, "dmg": 10, "assetLoadingOverlay": False}}),
    ]
    return [call("@for_each_entity", {"where_prefix": "en_", "do": [
        vset("vars._eid", "{{ loop.id }}"),
        call("@entity.get", {"id": "{{ vars._eid }}", "field": "state.kind"}, assign="vars._h2"),
        gif({"in": [V("vars._h2"), ["soldier", "crab", "zombie1", "zombie2", "zombie3",
                                    "maggot", "caterpillar"]]}, [
            call("@entity.get", {"id": "{{ vars._eid }}", "field": "x"}, assign="vars._ex"),
            call("@entity.get", {"id": "{{ vars._eid }}", "field": "y"}, assign="vars._ey"),
            call("@entity.get", {"id": "{{ vars._eid }}", "field": "state.hp"}, assign="vars._d"),
            gif({"<=": [V("vars._d"), 0]}, [
                call("@entity.get", {"id": "{{ vars._eid }}", "field": "state.dieT"}, assign="vars._d"),
                gif({"==": [V("vars._d"), 0]}, [
                    call("@animated_sprite.set_animation", {"id": "{{ vars._eid }}",
                        "animation": IF({"<": [PCX, V("vars._ex")]}, "die_l", "die")}),
                    SND("soldier_death")]),
                eadd("{{ vars._eid }}", "state.dieT", V("event.dt")),
                eset("{{ vars._eid }}", "vx", 0),
                call("@entity.get", {"id": "{{ vars._eid }}", "field": "state.dieT"}, assign="vars._d"),
                gif({">": [V("vars._d"), 1.2]}, [call("@despawn", {"id": "{{ vars._eid }}"})]),
            ], [
                call("@platformer.step", {"id": "{{ vars._eid }}", "map": "map",
                                          "dt": "{{ event.dt }}",
                                          "gravity": eget("state.grav"),
                                          "max_fall": MAXFALL,
                                          "one_way_types": ["platform"]}),
                gif({"and": [{"!!": eget("onGround")},
                             {"or": [{"!!": eget("state.blockedRight")},
                                     {"!!": eget("state.blockedLeft")}]}]},
                    [eadd("{{ vars._eid }}", "y", -5)]),
                vset("vars._d", {"-": [V("vars._ex"), PCX]}),
                vset("vars._d2", {"max": [V("vars._d"), {"*": [-1, V("vars._d")]}]}),
                gif({"<": [V("vars._d"), eget("state.act")]}, [
                    gif({"and": [{"!!": eget("state.canMelee")},
                                 {"<": [V("vars._d2"), eget("state.meleeR")]}]}, [
                        eset("{{ vars._eid }}", "vx", 0),
                        call("@animated_sprite.set_animation", {"id": "{{ vars._eid }}",
                            "animation": {"cat": [eget("state.atkAnim"),
                                                  IF({"<": [PCX, {"+": [V("vars._ex"), 20]}]}, "_l", "")]}}),
                        eadd("{{ vars._eid }}", "state.meleeT", V("event.dt")),
                        gif({">": [eget("state.meleeT"), 0.5]}, [
                            eset("{{ vars._eid }}", "state.meleeT", 0),
                            gif({"and": [{"<": [V("vars._d2"), {"+": [eget("state.meleeR"), 10]}]},
                                         {"!=": [V("vars.state"), "dead"]},
                                         {">": [eget("state.dmg"), 0]}]},
                                [vset("vars.hp", {"-": [V("vars.hp"), eget("state.dmg")]}),
                                 SND("melee_hit")])]),
                    ], [
                        gif({"and": [{"!!": eget("state.canThrow")},
                                     {"<": [V("vars._d2"), eget("state.atkR")]}]}, [
                            eset("{{ vars._eid }}", "vx", 0),
                            call("@animated_sprite.set_animation", {"id": "{{ vars._eid }}",
                                "animation": {"cat": [eget("state.atkAnim"),
                                                      IF({"<": [PCX, {"+": [V("vars._ex"), 20]}]}, "_l", "")]}}),
                            eadd("{{ vars._eid }}", "state.rangedT", V("event.dt")),
                            gif({">": [eget("state.rangedT"), eget("state.rangedD")]}, [
                                eset("{{ vars._eid }}", "state.rangedT", 0),
                                gif({"==": [eget("state.throwKind"), "vomit"]},
                                    throw_vomit, throw_gren)]),
                        ], [
                            eset("{{ vars._eid }}", "vx",
                                 IF({"<": [PCX, V("vars._ex")]},
                                    {"*": [-1, eget("state.spd")]}, eget("state.spd"))),
                            call("@animated_sprite.set_animation", {"id": "{{ vars._eid }}",
                                "animation": IF({"<": [PCX, V("vars._ex")]}, "walk_l", "walk")}),
                        ]),
                    ]),
                ], [eset("{{ vars._eid }}", "vx", 0),
                    call("@animated_sprite.set_animation", {"id": "{{ vars._eid }}",
                        "animation": IF({"<": [PCX, V("vars._ex")]}, "idle_l", "idle")})]),
            ]),
        ]),
    ]})]


def mk_pb_loop(extra_prefixes=()):
    """player bullets: ttl/wall/en_ damage (+extra shootable prefixes: 1-hit detonate)"""
    steps = [
        vset("vars._eid", "{{ loop.id }}"),
        eadd("{{ vars._eid }}", "state.ttl", {"*": [-1, V("event.dt")]}),
        call("@entity.get", {"id": "{{ vars._eid }}", "field": "state.ttl"}, assign="vars._d"),
        gif({"<=": [V("vars._d"), 0]}, [call("@despawn", {"id": "{{ vars._eid }}"})], [
            call("@tiled.has_collision_type", {"map": "map", "entity": "{{ vars._eid }}", "type": "solid"}, assign="vars._h"),
            gif(V("vars._h"), [call("@despawn", {"id": "{{ vars._eid }}"})], [
                call("@collision.first", {"a": "{{ vars._eid }}", "where_prefix": "en_"}, assign="vars._h"),
                gif({"!=": [V("vars._h"), None]}, [
                    eadd("{{ vars._h }}", "state.hp", -BULLET_DMG),
                    vset("vars.score", {"+": [V("vars.score"), BULLET_DMG]}),
                    SND("shot_hit"), call("@despawn", {"id": "{{ vars._eid }}"}),
                    vset("vars._h", None)],
                    sum([[call("@collision.first", {"a": "{{ vars._eid }}", "where_prefix": p}, assign="vars._h"),
                          gif({"!=": [V("vars._h"), None]}, [
                              eadd("{{ vars._h }}", "state.hp", -BULLET_DMG),
                              call("@despawn", {"id": "{{ vars._eid }}"}),
                              SND("shot_hit"), vset("vars._h", None)])] for p in extra_prefixes], [])),
            ]),
        ]),
    ]
    return [call("@for_each_entity", {"where_prefix": "pb_", "do": steps})]


def mk_pg_loop(splash=()):
    """player grenades: arc + contact 300 on en_ + optional named-structure splash"""
    steps = [
        vset("vars._eid", "{{ loop.id }}"),
        eadd("{{ vars._eid }}", "vy", {"*": [GREN_G, V("event.dt")]}),
        eadd("{{ vars._eid }}", "state.ttl", {"*": [-1, V("event.dt")]}),
        call("@entity.get", {"id": "{{ vars._eid }}", "field": "x"}, assign="vars._ex"),
        call("@entity.get", {"id": "{{ vars._eid }}", "field": "y"}, assign="vars._ey"),
        call("@collision.first", {"a": "{{ vars._eid }}", "where_prefix": "en_"}, assign="vars._h"),
        call("@tiled.has_collision_type", {"map": "map", "entity": "{{ vars._eid }}", "type": "solid"}, assign="vars._h2"),
        gif({"!": V("vars._h2")}, [call("@tiled.has_collision_type", {"map": "map", "entity": "{{ vars._eid }}", "type": "platform"}, assign="vars._h2")]),
        call("@entity.get", {"id": "{{ vars._eid }}", "field": "state.ttl"}, assign="vars._d"),
        gif({"or": [{"!=": [V("vars._h"), None]}, {"!!": V("vars._h2")}, {"<=": [V("vars._d"), 0]}]}, [
            gif({"!=": [V("vars._h"), None]}, [
                eadd("{{ vars._h }}", "state.hp", -GREN_DMG),
                vset("vars.score", {"+": [V("vars.score"), GREN_DMG]})]),
            vset("vars.seq", {"+": [V("vars.seq"), 1]}),
            oneshot("grenade", "boom", [{"-": [V("vars._ex"), 22]}, {"-": [V("vars._ey"), 100]}], 62),
            SND("grenade_hit"),
            call("@despawn", {"id": "{{ vars._eid }}"}), vset("vars._h", None)]),
    ]
    return [call("@for_each_entity", {"where_prefix": "pg_", "do": steps})]


def mk_eg_loop():
    """enemy throwables (vomit/grenade): arc, damage player by state.dmg"""
    return [call("@for_each_entity", {"where_prefix": "eg_", "do": [
        vset("vars._eid", "{{ loop.id }}"),
        eadd("{{ vars._eid }}", "vy", {"*": [GREN_G, V("event.dt")]}),
        eadd("{{ vars._eid }}", "state.ttl", {"*": [-1, V("event.dt")]}),
        call("@entity.get", {"id": "{{ vars._eid }}", "field": "state.ttl"}, assign="vars._d"),
        call("@collide.rect", {"a": "{{ vars._eid }}", "b": "player"}, assign="vars._h"),
        call("@tiled.has_collision_type", {"map": "map", "entity": "{{ vars._eid }}", "type": "solid"}, assign="vars._h2"),
        gif({"!": V("vars._h2")}, [call("@tiled.has_collision_type", {"map": "map", "entity": "{{ vars._eid }}", "type": "platform"}, assign="vars._h2")]),
        gif({"or": [{"!!": V("vars._h")}, {"!!": V("vars._h2")}, {"<=": [V("vars._d"), 0]}]}, [
            gif({"and": [{"!!": V("vars._h")}, {"!=": [V("vars.state"), "dead"]}]}, [
                call("@entity.get", {"id": "{{ vars._eid }}", "field": "state.dmg"}, assign="vars._d2"),
                vset("vars.hp", {"-": [V("vars.hp"), V("vars._d2")]}), SND("grenade_hit")]),
            call("@despawn", {"id": "{{ vars._eid }}"}), vset("vars._h", None)]),
    ]})]


def mk_hb_loop():
    """straight enemy bullets (heli / boss3): dmg state.dmg"""
    return [call("@for_each_entity", {"where_prefix": "hb_", "do": [
        vset("vars._eid", "{{ loop.id }}"),
        eadd("{{ vars._eid }}", "state.ttl", {"*": [-1, V("event.dt")]}),
        call("@entity.get", {"id": "{{ vars._eid }}", "field": "state.ttl"}, assign="vars._d"),
        call("@collide.rect", {"a": "{{ vars._eid }}", "b": "player"}, assign="vars._h"),
        call("@tiled.has_collision_type", {"map": "map", "entity": "{{ vars._eid }}", "type": "solid"}, assign="vars._h2"),
        gif({"or": [{"!!": V("vars._h")}, {"!!": V("vars._h2")}, {"<=": [V("vars._d"), 0]}]}, [
            gif({"and": [{"!!": V("vars._h")}, {"!=": [V("vars.state"), "dead"]}]}, [
                call("@entity.get", {"id": "{{ vars._eid }}", "field": "state.dmg"}, assign="vars._d2"),
                vset("vars.hp", {"-": [V("vars.hp"), V("vars._d2")]}), SND("shot_hit")]),
            call("@despawn", {"id": "{{ vars._eid }}"}), vset("vars._h", None)]),
    ]})]


def mk_camera(zones, autoscroll_var=None):
    steps = [
        vset("vars._d", {"min": [V("vars.cam_max"), {"max": [V("vars.cam_min"), {"+": [PCX, 117.6]}]}]}),
        vset("vars.cam_x", {"+": [V("vars.cam_x"),
             {"*": [{"-": [V("vars._d"), V("vars.cam_x")]}, {"min": [1, {"*": [5, V("event.dt")]}]}]}]}),
        vset("vars._d2", {"+": [V("vars.cam_cy_t", ) if False else 0, 0]}) if False else vset("vars._noop", 0),
        # smooth vertical toward zone cy
        eset("cam", "x", V("vars.cam_x")),
        eset("cam", "y", {"+": [V("entities.cam.y"),
             {"*": [{"-": [V("vars.cam_cy"), V("entities.cam.y")]}, {"min": [1, {"*": [4, V("event.dt")]}]}]}]}),
        gif({"and": [{"<": [PCX, {"-": [V("vars.cam_x"), 184]}]},
                     {">": [PCX, {"-": [V("vars.cam_x"), 284]}]}]},
            [eset("player", "x", {"-": [V("vars.cam_x"), 194.5]})]),
        gif({"and": [{">": [PCX, {"+": [V("vars.cam_x"), 184]}]},
                     {"<": [PCX, {"+": [V("vars.cam_x"), 284]}]}]},
            [eset("player", "x", {"+": [V("vars.cam_x"), 173.5]})]),
    ]
    return steps


def mk_hud_death(win_var="vars.won"):
    return [
        eset("hud_hp", "w", {"max": [0, {"*": [1.1, V("vars.hp")]}]}),
        eset("hud_score", "render.value", V("vars.score")),
        eset("hud_bombs", "render.value", {"cat": ["x ", V("vars.bombs")]}),
        eset("hud_ammo", "render.value", IF({">": [V("vars.mg"), 0]}, V("vars.mg"), "oo")),
        gif({"and": [{"<=": [V("vars.hp"), 0]}, {"!=": [V("vars.state"), "dead"]}, {"!": V(win_var)}]}, [
            vset("vars.state", "dead"), SND("marco_death"),
            call("@audio.stop", {}),
            call("@animated_sprite.set_animation", {"id": "player", "animation": "death"})]),
    ]


DEAD_TAIL = [gif({"==": [V("vars.state"), "dead"]}, [
    eset("player", "vx", 0),
    call("@platformer.step", {"id": "player", "map": "map", "dt": "{{ event.dt }}",
                              "gravity": GRAV, "max_fall": MAXFALL}),
    vset("vars.dieT", {"+": [V("vars.dieT"), V("event.dt")]}),
    gif({">": [V("vars.dieT"), 2.4]}, [call("@game_over", {})])])]


def mk_zone_events(zones, triggers):
    """triggers: list of (trigger_x_u, target_zone_idx)"""
    steps = []
    for tx, zi in triggers:
        mn, mx, cy = zones[zi]
        lo, hi = X(mn) + VW / 2, X(mx) - VW / 2
        if hi < lo:
            lo = hi = (lo + hi) / 2
        steps.append(gif({"and": [{"==": [V("vars.zone"), zi - 1]}, {">": [PCX, X(tx)]}]},
                         [vset("vars.zone", zi),
                          vset("vars.cam_min", round(lo, 1)), vset("vars.cam_max", round(hi, 1)),
                          vset("vars.cam_cy", Y(cy))]))
    return steps


def zone_bounds(zones, i):
    mn, mx, cy = zones[i]
    lo, hi = X(mn) + VW / 2, X(mx) - VW / 2
    if hi < lo:
        lo = hi = (lo + hi) / 2
    return round(lo, 1), round(hi, 1), Y(cy)


def enemy_ent(group, xu, yu, hitw, hith, spr_off, state):
    g = G(group)
    st = {"hp": 300, "spd": 50, "act": 200, "meleeR": 50, "atkR": 0, "dmg": 10,
          "canMelee": 1, "canThrow": 0, "throwKind": "grenade", "rangedD": 2,
          "rangedT": 0, "meleeT": 0, "dieT": 0, "grav": GRAV, "atkAnim": "attack",
          "spriteW": g["cell"][0], "spriteH": g["cell"][1],
          "spriteOffsetX": spr_off[0], "spriteOffsetY": spr_off[1],
          "assetLoadingOverlay": False}
    st.update(state)
    return {"kind": "animated_sprite", "priority": 30,
            "asset": SPR + g["anims"]["idle"]["file"], "frame_size": g["cell"],
            "frames": g["anims"]["idle"]["frames"],
            "frames_per_row": g["anims"]["idle"]["frames"],
            "step_time": 0.125, "animation": "idle", "animations": anims_of(group),
            "position": [X(xu) - hitw / 2, Y(yu) - hith / 2], "size": [hitw, hith],
            "velocity": [0, 0], "auto_update": False, "state": st}


ZOMBIE_STATES = {
    "zombie1": {"kind": "zombie1", "hp": 500, "spd": 50, "act": 180, "canMelee": 0,
                "canThrow": 1, "throwKind": "vomit", "atkR": 100, "rangedD": 2, "dmg": 10},
    "zombie2": {"kind": "zombie2", "hp": 700, "spd": 50, "act": 180, "canMelee": 0,
                "canThrow": 1, "throwKind": "vomit", "atkR": 80, "rangedD": 2, "dmg": 10},
    "zombie3": {"kind": "zombie3", "hp": 700, "spd": 50, "act": 180, "canMelee": 0,
                "canThrow": 1, "throwKind": "vomit", "atkR": 60, "rangedD": 2, "dmg": 10},
}


def mk_game(vars_, ents, input_, frame_logic, bgm_src, extra_audio=None):
    aud = {"base_url": AUD,
           "tracks": {"bgm": {"src": bgm_src, "loop": True, "volume": 0.4},
                      "boss_bgm": {"src": "boss_bgm.mp3", "loop": True, "volume": 0.4}},
           "sounds": {k: dict(v) for k, v in {
               "shot": {"src": "shot.mp3", "volume": 0.5},
               "heavy_shot": {"src": "heavy_shot.mp3", "volume": 0.5},
               "shot_hit": {"src": "shot_hit.mp3", "volume": 0.45},
               "melee_hit": {"src": "melee_hit.mp3", "volume": 0.55},
               "grenade_hit": {"src": "grenade_hit.mp3", "volume": 0.55},
               "grab": {"src": "grab.mp3", "volume": 0.6},
               "equip": {"src": "equip.mp3", "volume": 0.6},
               "destroy1": {"src": "destroy1.mp3", "volume": 0.6},
               "destroy2": {"src": "destroy2.mp3", "volume": 0.6},
               "destroy3": {"src": "destroy3.mp3", "volume": 0.6},
               "marco_death": {"src": "marco_death.mp3", "volume": 0.7},
               "soldier_death": {"src": "soldier_death.mp3", "volume": 0.5},
               "zombie_vomit": {"src": "zombie_vomit.mp3", "volume": 0.6},
               "zombie_attack": {"src": "zombie_attack.mp3", "volume": 0.6},
               "thunder": {"src": "thunder.mp3", "volume": 0.7},
               "missile_out": {"src": "missile_out.mp3", "volume": 0.6},
               "v_complete": {"src": "mission_complete.wav", "volume": 0.8},
               "v_hmg": {"src": "hmg_voice.wav", "volume": 0.8},
               "v_okay": {"src": "okay.wav", "volume": 0.8},
               "v_m2": {"src": "mission2_start.wav", "volume": 0.8},
               "v_m3": {"src": "mission3_start.wav", "volume": 0.8},
           }.items()}}
    if extra_audio:
        aud["sounds"].update(extra_audio)
    return {
        "type": "flame_game",
        "world": {"kind": "pixel", "bg": "#101018"},
        "viewport": {"width": VW, "height": VH, "fit": "contain"},
        "physics": {"engine": "leap_platformer", "fallback": "aabb_platformer"},
        "camera": {"follow": "cam", "offset_x": 0, "offset_y": 0, "deadzone_y": 0, "smooth_y": 1},
        "overlay": {"score": False, "game_over": True, "asset_loading": True,
                    "asset_loading_text": "Loading Metal Slug assets..."},
        "vars": vars_, "entities": ents, "input": input_,
        "frame": {"logic": frame_logic}, "audio": aud,
    }


def collectible_steps(items):
    steps = []
    for key, cid, effect in items:
        steps.append(gif(call("@entity.exists", {"id": cid}), [
            call("@collide.rect", {"a": "player", "b": cid}, assign="vars._h"),
            gif({"!!": V("vars._h")},
                [call("@despawn", {"id": cid}),
                 vset("vars.score", {"+": [V("vars.score"), 1000]})] + effect + [vset("vars._h", None)])]))
    return steps


def col_ent(key, xu, yu):
    st = MAN["statics"][key]
    return {"kind": "sprite", "priority": 20, "asset": SPR + st["file"],
            "position": [X(xu) - st["size"][0] / 2, Y(yu) - st["size"][1] / 2],
            "size": st["size"], "auto_update": False,
            "state": {"assetLoadingOverlay": False}}


EFFECTS = {
    "hmg": [vset("vars.mg", {"+": [V("vars.mg"), 120]}), SND("v_hmg"), SND("equip")],
    "ammo": [vset("vars.bombs", {"+": [V("vars.bombs"), 10]}), SND("grab"), SND("v_okay")],
    "medkit": [vset("vars.hp", {"min": [HP0, {"+": [V("vars.hp"), 20]}]}), SND("grab")],
}

# ---------------------- MISSION 2 ----------------------
M2A = MAN["m2_atlas"]


def m2_atlas_ent(sl, xu, yu, prio):
    r = M2A["slices"][sl]
    return {"kind": "sprite", "priority": prio, "asset": BASE + "atlas/m2_foreground.png",
            "src": r, "position": [X(xu) - r[2] / 2, Y(yu) - r[3] / 2],
            "size": [r[2], r[3]], "auto_update": False,
            "state": {"assetLoadingOverlay": False}}


def build_m2():
    Z = [  # (vol_min, vol_max, cy) per zone in order
        (-7.481, -3.892, -0.170), (-2.491, 2.797, -0.170), (3.834, 8.266, 0.210),
        (10.528, 14.960, -0.207), (14.623, 16.175, -1.575), (14.623, 16.893, -1.575),
        (20.734, 20.914, -1.805), (24.014, 24.194, -3.225), (23.767, 25.441, -4.535),
        (25.407, 34.920, -4.535), (36.874, 38.718, -4.995), (39.564, 43.420, -5.175),
    ]
    lo, hi, cy = zone_bounds(Z, 0)
    v = mk_vars(lo, lo, hi, cy)
    v.update({"b2_on": False, "b2_dead": False, "b2_t": 3.0, "b2_charge": 0,
              "b2_tx": 0, "h1_on": False, "h1_n": 0, "h1_t": 0, "h1_kills": 0,
              "h2_on": False, "h2_n": 0, "h2_t": 0, "h2_kills": 0, "_found": False})
    ents = {}
    ents["map"] = {"kind": "tiled_map", "priority": -80, "source": "tiles/mission2.tmx",
                   "base_url": BASE, "scale": 1, "solid_layers": ["collision"],
                   "collidable": True}
    # backdrop
    for i, (sl, xu, yu, pr) in enumerate([
            ("background_1", -7.379, 0.215, -70), ("background_1", -3.209, 0.304, -70),
            ("background_1", 0.280, 0.306, -70), ("background _2", 7.960, 0.301, -70),
            ("foreground_0", 1.127, -0.185, -60), ("foreground_3", 0.827, -0.705, 70),
            ("foreground_4", 6.628, -0.287, 70), ("foreground_1", 25.857, -3.525, -60),
            ("foreground_2", 42.697, -5.175, -60)]):
        ents[f"art_{i}"] = m2_atlas_ent(sl, xu, yu, pr)
    ents.update(mk_player(-8.616, 0.13))
    ents.update(mk_hud_title("MISSION 2"))
    ents["cam"] = {"kind": "pixel", "priority": -100, "position": [lo, Y(-0.17)],
                   "size": [1, 1], "auto_update": False,
                   "render": {"shape": "rect", "color": "#000000"}}
    # zombies / soldiers
    zpos = {"zombie1": [(-4.530, -0.630), (31.277, -4.959), (36.508, -5.145)],
            "zombie2": [(-3.340, -0.770), (5.063, 0.105), (9.373, -0.215),
                        (33.050, -4.898), (37.617, -5.210)],
            "zombie3": [(-2.730, -0.760), (3.223, -0.425), (6.753, 0.615),
                        (8.983, -0.355), (34.607, -4.911), (39.025, -5.359)]}
    n = 0
    for grp, lst in zpos.items():
        for xu, yu in lst:
            ents[f"en_z{n}"] = enemy_ent(grp, xu, yu, 30, 39, (-40, -50), ZOMBIE_STATES[grp])
            n += 1
    for i, (xu, yu) in enumerate([(12.810, -0.378), (13.381, -0.503), (14.123, -0.526)]):
        ents[f"en_s{i}"] = enemy_ent("soldier", xu, yu, 28, 39, (-12, -5),
                                     {"kind": "soldier", "hp": 300, "spd": 50, "act": 300,
                                      "canThrow": 1, "atkR": 150, "rangedD": 3,
                                      "atkAnim": "knife", "throwKind": "grenade"})
    # rebel vans (en_ prefixed for damage; AI custom)
    RV = G("rebelvan")
    for i, (xu, yu) in enumerate([(0.390, -0.710), (16.818, -2.319), (20.603, -3.747),
                                  (24.627, -5.205), (26.639, -5.187)]):
        ents[f"en_rv{i}"] = {
            "kind": "animated_sprite", "priority": 25,
            "asset": SPR + RV["anims"]["spawn"]["file"], "frame_size": RV["cell"],
            "frames": RV["anims"]["spawn"]["frames"], "frames_per_row": RV["anims"]["spawn"]["frames"],
            "step_time": 0.125, "animation": "spawn", "animations": anims_of("rebelvan"),
            "position": [X(xu) - 37, Y(yu) - 29], "size": [74, 57],
            "auto_update": False,
            "state": {"kind": "rvan", "hp": 3000, "left": 8, "fireT": 3.5, "dieT": 0,
                      "spriteOffsetX": -5, "spriteOffsetY": -5, "assetLoadingOverlay": False}}
    # boss2
    B2 = G("boss2")
    ents["en_boss2"] = {
        "kind": "animated_sprite", "priority": 35,
        "asset": SPR + B2["anims"]["attack"]["file"], "frame_size": B2["cell"],
        "frames": B2["anims"]["attack"]["frames"], "frames_per_row": B2["anims"]["attack"]["frames"],
        "step_time": 0.084, "animation": "attack", "animations": anims_of("boss2"),
        "position": [X(43.808) - 64, Y(-4.70) - 32], "size": [128, 64],
        "auto_update": False,
        "state": {"kind": "boss2", "hp": 20000, "spriteOffsetX": -30, "spriteOffsetY": -10,
                  "assetLoadingOverlay": False}}
    # collectibles
    cols = []
    for i, (key, xu, yu) in enumerate([
            ("ammo", -2.173, -0.796), ("medkit", 7.392, -0.616), ("ammo", 7.395, 0.597),
            ("hmg", 11.312, -0.599), ("medkit", 15.279, -2.051), ("medkit", 18.986, -3.800),
            ("hmg", 23.763, -5.300), ("medkit", 25.457, -5.327), ("medkit", 30.166, -5.220),
            ("medkit", 42.282, -5.858), ("ammo", 44.929, -5.845), ("hmg", 43.839, -5.897)]):
        cid = f"col_{i}"
        ents[cid] = col_ent(key, xu, yu)
        cols.append((key, cid, EFFECTS[key]))

    HELI = G("heli")
    def heli_system(sid, sx_u, sy_u, trig_x, next_zone):
        lo2, hi2, cy2 = zone_bounds(Z, next_zone)
        spawn_one = call("@spawn", {
            "id": f"en_{sid}h{{{{ vars.{sid}_n }}}}", "kind": "animated_sprite", "priority": 32,
            "asset": SPR + HELI["anims"]["idle"]["file"], "frame_size": HELI["cell"],
            "frames": HELI["anims"]["idle"]["frames"], "frames_per_row": HELI["anims"]["idle"]["frames"],
            "step_time": 0.045, "animation": "idle", "animations": anims_of("heli"),
            "position": [X(sx_u), Y(sy_u)], "size": [77, 60], "velocity": [0, 0],
            "auto_update": False,
            "state": {"kind": "heli", "hp": 600, "dirx": -1, "iy": Y(sy_u), "fireT": 0.5,
                      "shoot": 0, "dieT": 0, "spriteOffsetX": -3, "spriteOffsetY": -7,
                      "assetLoadingOverlay": False}})
        return [
            gif({"and": [{"!": V(f"vars.{sid}_on")}, {">": [PCX, X(trig_x)]}]},
                [vset(f"vars.{sid}_on", True), vset(f"vars.{sid}_t", 0.01)]),
            gif({"and": [V(f"vars.{sid}_on"), {"<": [V(f"vars.{sid}_n"), 5]}]}, [
                vset(f"vars.{sid}_t", {"-": [V(f"vars.{sid}_t"), V("event.dt")]}),
                gif({"<=": [V(f"vars.{sid}_t"), 0]},
                    [spawn_one, vset(f"vars.{sid}_n", {"+": [V(f"vars.{sid}_n"), 1]}),
                     vset(f"vars.{sid}_t", 1.5)])]),
            # shooter designation + per-heli AI
            vset("vars._found", False),
            call("@for_each_entity", {"where_prefix": f"en_{sid}h", "do": [
                vset("vars._eid", "{{ loop.id }}"),
                call("@entity.get", {"id": "{{ vars._eid }}", "field": "state.hp"}, assign="vars._d"),
                gif({"<=": [V("vars._d"), 0]}, [
                    eadd("{{ vars._eid }}", "state.dieT", V("event.dt")),
                    call("@entity.get", {"id": "{{ vars._eid }}", "field": "state.dieT"}, assign="vars._d"),
                    gif({"<": [V("vars._d"), 0.05]}, [SND("destroy2")]),
                    eadd("{{ vars._eid }}", "y", {"*": [120, V("event.dt")]}),
                    gif({">": [V("vars._d"), 1.0]}, [
                        call("@despawn", {"id": "{{ vars._eid }}"}),
                        vset(f"vars.{sid}_kills", {"+": [V(f"vars.{sid}_kills"), 1]})]),
                ], [
                    eset("{{ vars._eid }}", "state.shoot", IF(V("vars._found"), 0, 1)),
                    vset("vars._found", True),
                    call("@entity.get", {"id": "{{ vars._eid }}", "field": "x"}, assign="vars._ex"),
                    call("@entity.get", {"id": "{{ vars._eid }}", "field": "state.dirx"}, assign="vars._d"),
                    gif({"and": [{"<": [V("vars._ex"), {"-": [V("vars.cam_x"), 186]}]}, {"<": [V("vars._d"), 0]}]},
                        [eset("{{ vars._eid }}", "state.dirx", 1)]),
                    gif({"and": [{">": [V("vars._ex"), {"+": [V("vars.cam_x"), 110]}]}, {">": [V("vars._d"), 0]}]},
                        [eset("{{ vars._eid }}", "state.dirx", -1)]),
                    eadd("{{ vars._eid }}", "x", {"*": [{"call": "@entity.get", "args": {"id": "{{ vars._eid }}", "field": "state.dirx"}}, 100, V("event.dt")]}),
                    # gentle altitude wave toward iy +/- 15
                    eadd("{{ vars._eid }}", "state.fireT", {"*": [-1, V("event.dt")]}),
                    gif({"and": [{"!!": {"call": "@entity.get", "args": {"id": "{{ vars._eid }}", "field": "state.shoot"}}},
                                 {"<=": [{"call": "@entity.get", "args": {"id": "{{ vars._eid }}", "field": "state.fireT"}}, 0]}]}, [
                        eset("{{ vars._eid }}", "state.fireT", 0.5),
                        vset("vars.seq", {"+": [V("vars.seq"), 1]}),
                        call("@entity.get", {"id": "{{ vars._eid }}", "field": "y"}, assign="vars._ey"),
                        call("@spawn", {"id": "hb_{{ vars.seq }}", "kind": "sprite", "priority": 44,
                                        "asset": SPR + MAN["statics"]["bullet"]["file"],
                                        "size": [10, 6], "auto_update": True,
                                        "position": [{"+": [V("vars._ex"), 34]}, {"+": [V("vars._ey"), 56]}],
                                        "velocity": [0, 200],
                                        "state": {"ttl": 5, "dmg": 15, "assetLoadingOverlay": False}}),
                        SND("shot")]),
                ]),
            ]}),
            gif({"and": [{"==": [V(f"vars.{sid}_kills"), 5]}, {"==": [V("vars.zone"), next_zone - 1]}]},
                [vset("vars.zone", next_zone),
                 vset("vars.cam_min", lo2), vset("vars.cam_max", hi2), vset("vars.cam_cy", cy2),
                 vset(f"vars.{sid}_kills", 6)]),
        ]

    MAIN = []
    MAIN += mk_player_main(y_kill_px=790)
    # zone triggers (progression: idx per Z list)
    MAIN += mk_zone_events(Z, [(-2.137, 1), (4.023, 2), (10.173, 3), (13.923, 4),
                               (18.363, 6), (21.253, 7), (23.913, 8),
                               (35.743, 10), (40.283, 11)])
    # heli spawners advance zones 5 (1E->2A idx 5) and 9 (2D->2E idx 9)
    MAIN += heli_system("h1", 17.46, -0.95, 17.14, 5)
    MAIN += heli_system("h2", 27.2, -3.95, 26.88, 9)
    MAIN += mk_enemy_loop()
    # rebel van AI
    MAIN += [call("@for_each_entity", {"where_prefix": "en_rv", "do": [
        vset("vars._eid", "{{ loop.id }}"),
        call("@entity.get", {"id": "{{ vars._eid }}", "field": "state.hp"}, assign="vars._d"),
        call("@entity.get", {"id": "{{ vars._eid }}", "field": "x"}, assign="vars._ex"),
        call("@entity.get", {"id": "{{ vars._eid }}", "field": "y"}, assign="vars._ey"),
        gif({"<=": [V("vars._d"), 0]}, [
            eadd("{{ vars._eid }}", "state.dieT", V("event.dt")),
            call("@entity.get", {"id": "{{ vars._eid }}", "field": "state.dieT"}, assign="vars._d"),
            gif({"<": [V("vars._d"), 0.05]}, [
                call("@animated_sprite.set_animation", {"id": "{{ vars._eid }}", "animation": "die"}),
                SND("destroy1")]),
            gif({">": [V("vars._d"), 2.0]}, [call("@despawn", {"id": "{{ vars._eid }}"})]),
        ], [
            gif({"<": [{"-": [V("vars._ex"), PCX]}, 300]}, [
                eadd("{{ vars._eid }}", "state.fireT", {"*": [-1, V("event.dt")]}),
                gif({"and": [{"<=": [{"call": "@entity.get", "args": {"id": "{{ vars._eid }}", "field": "state.fireT"}}, 0]},
                             {">": [{"call": "@entity.get", "args": {"id": "{{ vars._eid }}", "field": "state.left"}}, 0]}]}, [
                    eset("{{ vars._eid }}", "state.fireT", 4.0),
                    eadd("{{ vars._eid }}", "state.left", -1),
                    call("@animated_sprite.set_animation", {"id": "{{ vars._eid }}", "animation": "spawn_soldier"}),
                    vset("vars.seq", {"+": [V("vars.seq"), 1]}),
                    call("@spawn", dict(enemy_ent("soldier", 0, 0, 28, 39, (-12, -5),
                                                  {"kind": "soldier", "hp": 300, "spd": 50, "act": 300,
                                                   "canThrow": 1, "atkR": 150, "rangedD": 3,
                                                   "atkAnim": "knife", "throwKind": "grenade"}),
                                        id="en_sv{{ vars.seq }}",
                                        position=[{"-": [V("vars._ex"), 22]}, V("vars._ey")])),
                ]),
            ]),
        ]),
    ]})]
    # boss2
    b2 = "en_boss2"
    B2R = G("boss2rock")
    MAIN += [
        gif({"and": [{"!": V("vars.b2_on")}, {">": [PCX, X(44.7) - 70]}]}, [
            vset("vars.b2_on", True),
            call("@audio.stop", {"id": "bgm"}),
            call("@audio.play", {"id": "boss_bgm", "loop": True})]),
        gif({"!": V("vars.b2_on")}, [eset(b2, "state.hp", 20000)]),  # immortal until active
        gif({"and": [V("vars.b2_on"), {"!": V("vars.b2_dead")}]}, [
            gif({"<=": [{"call": "@entity.get", "args": {"id": b2, "field": "state.hp"}}, 0]}, [
                vset("vars.b2_dead", True), vset("vars.won", True),
                call("@animated_sprite.set_animation", {"id": b2, "animation": "dead"}),
                call("@audio.stop", {"id": "boss_bgm"}), SND("destroy3"), SND("v_complete"),
                call("@spawn", {"id": "win_t", "kind": "pixel", "priority": 232,
                                "position": [92, 90], "size": [1, 1], "fixed_to_screen": True,
                                "render": {"shape": "text", "value": "MISSION COMPLETE",
                                           "color": "#FFD24A", "fontSize": 22}}),
                call("@game_over", {})], [
                vset("vars.b2_t", {"-": [V("vars.b2_t"), V("event.dt")]}),
                gif({"<=": [V("vars.b2_t"), 0]}, [
                    # telegraph at player x, rock after charge (enrage by hp)
                    vset("vars.b2_tx", PCX),
                    vset("vars.b2_charge",
                         IF({"<=": [{"call": "@entity.get", "args": {"id": b2, "field": "state.hp"}}, 5000]}, 0.5,
                         IF({"<=": [{"call": "@entity.get", "args": {"id": b2, "field": "state.hp"}}, 6666]}, 0.75,
                         IF({"<=": [{"call": "@entity.get", "args": {"id": b2, "field": "state.hp"}}, 10000]}, 1.0, 1.25)))),
                    vset("vars.b2_t", 3.0),
                    call("@animated_sprite.set_animation", {"id": b2, "animation": "attack"}),
                    vset("vars.seq", {"+": [V("vars.seq"), 1]}),
                    call("@spawn", {"id": "tele_{{ vars.seq }}", "kind": "sprite", "priority": 42,
                                    "asset": SPR + MAN["statics"]["b2line"]["file"],
                                    "position": [{"-": [V("vars.b2_tx"), 1]}, Y(-4.5)],
                                    "size": [3, 160], "auto_update": True,
                                    "state": {"ttl": 2, "assetLoadingOverlay": False}}),
                    SND("missile_out")]),
                # telegraph ttl + rock spawn at charge end
                call("@for_each_entity", {"where_prefix": "tele_", "do": [
                    vset("vars._eid", "{{ loop.id }}"),
                    eadd("{{ vars._eid }}", "state.ttl", {"*": [-1, V("event.dt")]}),
                    call("@entity.get", {"id": "{{ vars._eid }}", "field": "state.ttl"}, assign="vars._d"),
                    gif({"and": [{"<": [V("vars._d"), 2 - 0.01]}, {">": [V("vars._d"), 0]},
                                 {"<": [{"-": [2, V("vars._d")]}, {"+": [V("vars.b2_charge"), 0.03]}]},
                                 {">": [{"-": [2, V("vars._d")]}, {"-": [V("vars.b2_charge"), 0.03]}]}]}, [
                        call("@entity.get", {"id": "{{ vars._eid }}", "field": "x"}, assign="vars._ex"),
                        vset("vars.seq", {"+": [V("vars.seq"), 1]}),
                        call("@spawn", {"id": "rk_{{ vars.seq }}", "kind": "animated_sprite",
                                        "priority": 43,
                                        "asset": SPR + B2R["anims"]["fall"]["file"],
                                        "frame_size": B2R["cell"],
                                        "frames": B2R["anims"]["fall"]["frames"],
                                        "frames_per_row": B2R["anims"]["fall"]["frames"],
                                        "step_time": 0.1, "loop": False,
                                        "position": [{"-": [V("vars._ex"), 33]}, Y(-2.2)],
                                        "size": [66, 116], "velocity": [0, 0], "auto_update": True,
                                        "state": {"hp": 500, "grounded": 0, "sitT": 0,
                                                  "assetLoadingOverlay": False}})]),
                    gif({"<=": [V("vars._d"), 0]}, [call("@despawn", {"id": "{{ vars._eid }}"})]),
                ]}),
                # rocks
                call("@for_each_entity", {"where_prefix": "rk_", "do": [
                    vset("vars._eid", "{{ loop.id }}"),
                    call("@entity.get", {"id": "{{ vars._eid }}", "field": "state.grounded"}, assign="vars._d"),
                    call("@entity.get", {"id": "{{ vars._eid }}", "field": "state.hp"}, assign="vars._d2"),
                    gif({"<=": [V("vars._d2"), 0]}, [call("@despawn", {"id": "{{ vars._eid }}"})], [
                        gif({"!!": V("vars._d")}, [
                            eadd("{{ vars._eid }}", "state.sitT", V("event.dt")),
                            gif({">": [{"call": "@entity.get", "args": {"id": "{{ vars._eid }}", "field": "state.sitT"}}, 3.2]},
                                [call("@despawn", {"id": "{{ vars._eid }}"})]),
                        ], [
                            eadd("{{ vars._eid }}", "vy", {"*": [GRAV, V("event.dt")]}),
                            call("@collide.rect", {"a": "{{ vars._eid }}", "b": "player"}, assign="vars._h"),
                            gif({"and": [{"!!": V("vars._h")}, {"!=": [V("vars.state"), "dead"]}]}, [
                                vset("vars.hp", {"-": [V("vars.hp"), 15]}), SND("grenade_hit"),
                                call("@despawn", {"id": "{{ vars._eid }}"}), vset("vars._h", None)]),
                            call("@tiled.has_collision_type", {"map": "map", "entity": "{{ vars._eid }}", "type": "solid"}, assign="vars._h2"),
                            gif({"!!": V("vars._h2")}, [
                                eset("{{ vars._eid }}", "vy", 0),
                                eset("{{ vars._eid }}", "state.grounded", 1)]),
                        ]),
                    ]),
                ]}),
            ]),
        ]),
    ]
    MAIN += mk_pb_loop(extra_prefixes=("rk_",))
    MAIN += mk_pg_loop()
    MAIN += mk_eg_loop()
    MAIN += mk_hb_loop()
    MAIN += collectible_steps(cols)
    MAIN += mk_camera(Z)
    # parallax verticals pin (factor 0.5 relative to initial cam)
    for i, (sl, xu, yu, pr) in enumerate([("background_1", -7.379, 0.215, 0),
                                          ("background_1", -3.209, 0.304, 0),
                                          ("background_1", 0.280, 0.306, 0),
                                          ("background _2", 7.960, 0.301, 0)]):
        r = M2A["slices"][sl]
        MAIN += [eset(f"art_{i}", "x", {"+": [X(xu) - r[2] / 2,
                       {"*": [0.5, {"-": [V("vars.cam_x"), lo]}]}]}),
                 eset(f"art_{i}", "y", {"+": [Y(yu) - r[3] / 2,
                       {"*": [0.5, {"-": [V("entities.cam.y"), Y(-0.17)]}]}]})]
    MAIN += mk_hud_death()
    logic = [gif({"==": [V("vars.state"), "loading"]}, [vset("vars.state", "running")]),
             gif(RUN, MAIN)] + DEAD_TAIL
    return mk_game(v, ents, mk_input("bgm", "v_m2"), logic, "m2_bgm.mp3")


# ---------------------- MISSION 3 ----------------------
def build_m3():
    ZO = [(-7.127, 52.116, -0.199)]
    lo, hi, cy = zone_bounds(ZO, 0)
    v = mk_vars(lo, lo, hi, cy)
    for hn in range(1, 5):
        v[f"hole{hn}_on"] = False
        v[f"hole{hn}_n"] = 0
        v[f"hole{hn}_t"] = 0
    v["exited"] = False
    ents = {}
    ents["map"] = {"kind": "tiled_map", "priority": -80, "source": "tiles/mission3.tmx",
                   "base_url": BASE, "scale": 1, "solid_layers": ["collision"],
                   "collidable": True}
    ms = MAN["m3_strip"]
    ents["art_bg"] = {"kind": "sprite", "priority": -60, "asset": BASE + "atlas/m3_strip.png",
                      "src": [0, 0, ms["w"], ms["h"]],
                      "position": [X(22.62) - ms["w"] / 2, Y(-0.2) - ms["h"] / 2],
                      "size": [ms["w"], ms["h"]], "auto_update": False,
                      "state": {"assetLoadingOverlay": False}}
    ents.update(mk_player(-8.7, 0.325))
    ents.update(mk_hud_title("MISSION 3"))
    ents["cam"] = {"kind": "pixel", "priority": -100, "position": [lo, Y(-0.199)],
                   "size": [1, 1], "auto_update": False,
                   "render": {"shape": "rect", "color": "#000000"}}
    CRABS3 = [(-0.852, -0.681, 5), (0.645, -0.667, 3), (1.371, -0.701, 3), (2.862, -0.727, 3.2),
              (11.916, -0.727, 3), (12.716, -0.727, 3), (13.028, -0.231, 3), (13.891, 0.237, 3),
              (14.699, 0.255, 3), (15.544, 0.283, 3), (17.026, -0.663, 3), (17.958, -0.681, 3),
              (19.116, -0.693, 4), (20.046, -0.713, 4), (20.836, -0.733, 4), (21.82, -0.71, 4),
              (22.636, -0.233, 4), (23.136, 0.277, 4), (24.52, -0.67, 4), (25.472, -0.67, 4),
              (26.306, -0.67, 4), (31.826, -0.67, 1.5), (32.476, -0.613, 1.5), (35.036, -0.633, 1.5),
              (35.666, -0.643, 1.5), (38.086, -0.643, 1.5), (38.736, -0.653, 1.5)]
    for i, (xu, yu, act) in enumerate(CRABS3):
        ents[f"en_c{i}"] = enemy_ent("crab", xu, yu, 40, 34, (-19, -19),
                                     {"kind": "crab", "hp": 300, "spd": 100, "act": act * 100,
                                      "meleeR": 50, "dmg": 10})
    for i, (xu, yu) in enumerate([(-6.947, -0.929), (-6.671, -0.918), (-6.433, -0.935),
                                  (-6.278, -0.802), (-6.167, -0.935), (-5.935, -0.885),
                                  (-4.818, -0.823), (-4.499, -0.823), (-4.096, -0.375),
                                  (-3.676, 0.14), (-2.714, -0.792), (-2.228, -0.832),
                                  (-1.742, -0.832), (-1.276, -0.832), (-6.842, -0.791)]):
        ents[f"en_m{i}"] = enemy_ent("maggot", xu, yu, 22, 11, (-11, -6),
                                     {"kind": "maggot", "hp": 100, "spd": 50, "act": 250,
                                      "meleeR": 50, "dmg": 5, "grav": 196})
    for i, (xu, yu) in enumerate([(27.996, -0.481), (30.206, -0.523), (33.766, -0.443),
                                  (36.996, -0.423), (40.036, -0.403)]):
        ents[f"en_cat{i}"] = enemy_ent("caterpillar", xu, yu, 167, 79, (-12, -2),
                                       {"kind": "caterpillar", "hp": 1000, "spd": 80,
                                        "act": 350, "meleeR": 100, "dmg": 20})
    zp = [("zombie1", 44.065, -0.671), ("zombie1", 46.35, -0.671),
          ("zombie2", 45.496, -0.656), ("zombie2", 47.546, -0.643),
          ("zombie3", 48.944, -0.731)]
    for i, (grp, xu, yu) in enumerate(zp):
        ents[f"en_z{i}"] = enemy_ent(grp, xu, yu, 30, 39, (-40, -50), ZOMBIE_STATES[grp])
    cols = []
    for i, (key, xu, yu) in enumerate([("hmg", 11.342, -0.768), ("medkit", 24.96, -0.78),
                                       ("ammo", 32.177, -0.635)]):
        cid = f"col_{i}"
        ents[cid] = col_ent(key, xu, yu)
        cols.append((key, cid, EFFECTS[key]))

    MAIN = []
    MAIN += mk_player_main(y_kill_px=380)
    # maggot holes
    for hn, (tx, hx, hy) in enumerate([(0.464, 1.316, 0.827), (3.694, 4.696, 0.827),
                                       (6.414, 7.736, 0.827), (8.284, 9.416, 0.827)], start=1):
        spawn = call("@spawn", dict(enemy_ent("maggot", hx, hy, 22, 11, (-11, -6),
                                              {"kind": "maggot", "hp": 100, "spd": 50, "act": 0,
                                               "meleeR": 50, "dmg": 5, "grav": 196}),
                                    id=f"en_hm{hn}_{{{{ vars.hole{hn}_n }}}}"))
        MAIN += [
            gif({"and": [{"!": V(f"vars.hole{hn}_on")}, {">": [PCX, X(tx)]}]},
                [vset(f"vars.hole{hn}_on", True), vset(f"vars.hole{hn}_t", 0.01)]),
            gif({"and": [V(f"vars.hole{hn}_on"), {"<": [V(f"vars.hole{hn}_n"), 6]}]}, [
                vset(f"vars.hole{hn}_t", {"-": [V(f"vars.hole{hn}_t"), V("event.dt")]}),
                gif({"<=": [V(f"vars.hole{hn}_t"), 0]},
                    [spawn, vset(f"vars.hole{hn}_n", {"+": [V(f"vars.hole{hn}_n"), 1]}),
                     vset(f"vars.hole{hn}_t", 0.4)])]),
        ]
    MAIN += mk_enemy_loop()
    MAIN += mk_pb_loop()
    MAIN += mk_pg_loop()
    MAIN += mk_eg_loop()
    MAIN += collectible_steps(cols)
    MAIN += mk_camera(ZO)
    MAIN += mk_hud_death()
    # to boss
    MAIN += [gif({"and": [{"!": V("vars.exited")}, {">": [PCX, X(50.224)]}]}, [
        vset("vars.exited", True),
        call("@audio.stop", {}),
        call("@emit", {"event": "toboss", "data": {"score": "{{ vars.score }}",
                                                   "bombs": "{{ vars.bombs }}",
                                                   "mg": "{{ vars.mg }}", "hp": "{{ vars.hp }}"}})])]
    logic = [gif({"==": [V("vars.state"), "loading"]}, [vset("vars.state", "running")]),
             gif(RUN, MAIN)] + DEAD_TAIL
    g = mk_game(v, ents, mk_input("bgm", "v_m3"), logic, "m3_bgm.mp3")
    g["on_toboss"] = {"type": "call", "call": "@global.gotoM3Boss",
                      "args": {"score": "{{ event.score }}", "bombs": "{{ event.bombs }}",
                               "mg": "{{ event.mg }}", "hp": "{{ event.hp }}"}}
    return g


# ---------------------- MISSION 3 BOSS ----------------------
def build_m3boss():
    v = mk_vars(X(-7.563), X(-7.563), X(-7.563), Y(0.057))
    v.update({"score": "{{ global.ms_score }}", "bombs": "{{ global.ms_bombs }}",
              "mg": "{{ global.ms_mg }}",
              "b3_a1t": 7.0, "b3_a2t": 1.0, "b3_phase": "idle", "b3_pt": 0,
              "b3_shots": 0, "b3_hover": 1, "b3_hit": 0, "b3_dead": False})
    ents = {}
    ents["map"] = {"kind": "tiled_map", "priority": -80, "source": "tiles/mission3boss.tmx",
                   "base_url": BASE, "scale": 1, "solid_layers": ["collision"],
                   "collidable": True}
    # animated lightning background + tower
    LG = G("m3lightning")
    lga = dict({"asset": SPR + LG["anims"]["bolt"]["file"], "frame_size": LG["cell"],
                "frames": LG["anims"]["bolt"]["frames"],
                "frames_per_row": LG["anims"]["bolt"]["frames"],
                "step_time": 0.3, "loop": True})
    ents["art_bg"] = dict({"kind": "animated_sprite", "priority": -70,
                           "position": [X(-7.56) - 190, Y(-0.103) - 132],
                           "size": [380, 264], "auto_update": True,
                           "state": {"assetLoadingOverlay": False}}, **lga)
    for k, key, xu, yu, pr in (("art_tw", "b3tower", -7.558, -0.94, -55),
                               ("art_twn", "b3tower_near", -7.558, -1.15, 70)):
        st = MAN["statics"][key]
        ents[k] = {"kind": "sprite", "priority": pr, "asset": SPR + st["file"],
                   "position": [X(xu) - st["size"][0] / 2, Y(yu) - st["size"][1] / 2],
                   "size": st["size"], "auto_update": False,
                   "state": {"assetLoadingOverlay": False}}
    ents.update(mk_player(-7.48, -0.28))
    ents.update(mk_hud_title("FINAL BOSS"))
    ents["cam"] = {"kind": "pixel", "priority": -100, "position": [X(-7.563), Y(0.057)],
                   "size": [1, 1], "auto_update": False,
                   "render": {"shape": "rect", "color": "#000000"}}
    B3 = G("boss3")
    ents["en_b3"] = {"kind": "animated_sprite", "priority": 35,
                     "asset": SPR + B3["anims"]["attack1"]["file"], "frame_size": B3["cell"],
                     "frames": B3["anims"]["attack1"]["frames"],
                     "frames_per_row": B3["anims"]["attack1"]["frames"],
                     "step_time": 0.05, "animation": "attack1", "animations": anims_of("boss3"),
                     "position": [X(-7.49) - 60, Y(0.54) - 60], "size": [120, 120],
                     "auto_update": False,
                     "state": {"kind": "boss3", "hp": 12000, "iy": Y(0.54) - 60,
                               "spriteOffsetX": -56, "spriteOffsetY": -50,
                               "assetLoadingOverlay": False}}
    b3 = "en_b3"
    # precomputed spread velocities: down ± 50°, 11 buckets, speed 200
    SPREAD = []
    for k in range(11):
        phi = math.radians(-50 + 10 * k)
        SPREAD.append((round(200 * math.sin(phi), 1), round(200 * math.cos(phi), 1)))

    MAIN = []
    MAIN += mk_player_main(y_kill_px=Y(-1.55))
    boss_cx = {"+": [V(f"entities.{b3}.x"), 60]}
    MAIN += [
        gif({"and": [{"!": V("vars.b3_dead")}, {"!=": [V("vars.state"), "dead"]}]}, [
            gif({"<=": [{"call": "@entity.get", "args": {"id": b3, "field": "state.hp"}}, 0]}, [
                vset("vars.b3_dead", True), vset("vars.won", True),
                call("@animated_sprite.set_animation", {"id": b3, "animation": "die"}),
                call("@audio.stop", {}), SND("destroy3"), SND("v_complete"),
                call("@spawn", {"id": "win_t", "kind": "pixel", "priority": 232,
                                "position": [120, 80], "size": [1, 1], "fixed_to_screen": True,
                                "render": {"shape": "text", "value": "GAME CLEAR !",
                                           "color": "#FFD24A", "fontSize": 26}}),
                call("@spawn", {"id": "win_t2", "kind": "pixel", "priority": 232,
                                "position": [104, 120], "size": [1, 1], "fixed_to_screen": True,
                                "render": {"shape": "text",
                                           "value": {"cat": ["FINAL SCORE ", V("vars.score")]},
                                           "fontSize": 14, "color": "#FFFFFF"}}),
                call("@game_over", {})], [
                # hover (triangle wave) while idle
                gif({"==": [V("vars.b3_phase"), "idle"]}, [
                    eadd(b3, "y", {"*": [V("vars.b3_hover"), 10, V("event.dt")]}),
                    gif({">": [V(f"entities.{b3}.y"), {"+": [{"call": "@entity.get", "args": {"id": b3, "field": "state.iy"}}, 10]}]},
                        [vset("vars.b3_hover", -1)]),
                    gif({"<": [V(f"entities.{b3}.y"), {"-": [{"call": "@entity.get", "args": {"id": b3, "field": "state.iy"}}, 10]}]},
                        [vset("vars.b3_hover", 1)]),
                    vset("vars.b3_a1t", {"-": [V("vars.b3_a1t"), V("event.dt")]}),
                    vset("vars.b3_a2t", {"-": [V("vars.b3_a2t"), V("event.dt")]}),
                    gif({"<=": [V("vars.b3_a2t"), 0]},
                        [vset("vars.b3_phase", "a2_drift"), vset("vars.b3_a2t", 11.0),
                         call("@animated_sprite.set_animation", {"id": b3, "animation": "attack2"})],
                        [gif({"<=": [V("vars.b3_a1t"), 0]},
                             [vset("vars.b3_phase", "a1_wind"), vset("vars.b3_pt", 2.0),
                              vset("vars.b3_a1t", 11.0), vset("vars.b3_shots", 10),
                              call("@animated_sprite.set_animation", {"id": b3, "animation": "attack1"}),
                              SND("thunder")])]),
                ]),
                # attack1: windup then 10 spread shots 0.35s apart
                gif({"==": [V("vars.b3_phase"), "a1_wind"]}, [
                    vset("vars.b3_pt", {"-": [V("vars.b3_pt"), V("event.dt")]}),
                    gif({"<=": [V("vars.b3_pt"), 0]},
                        [vset("vars.b3_phase", "a1_fire"), vset("vars.b3_pt", 0.01),
                         call("@animated_sprite.set_animation", {"id": b3, "animation": "firing1"})])]),
                gif({"==": [V("vars.b3_phase"), "a1_fire"]}, [
                    vset("vars.b3_pt", {"-": [V("vars.b3_pt"), V("event.dt")]}),
                    gif({"<=": [V("vars.b3_pt"), 0]}, [
                        vset("vars.b3_pt", 0.35),
                        vset("vars.b3_shots", {"-": [V("vars.b3_shots"), 1]}),
                        vset("vars.seq", {"+": [V("vars.seq"), 1]}),
                        call("@random_int", {"min": 0, "max": 11}, assign="vars._d"),
                    ] + [gif({"==": [V("vars._d"), k]}, [
                            call("@spawn", {"id": "hb_{{ vars.seq }}", "kind": "sprite",
                                            "priority": 44,
                                            "asset": SPR + MAN["statics"]["bullet"]["file"],
                                            "size": [14, 8], "auto_update": True,
                                            "position": [boss_cx, {"+": [V(f"entities.{b3}.y"), 30]}],
                                            "velocity": [SPREAD[k][0], SPREAD[k][1]],
                                            "state": {"ttl": 5, "dmg": 15,
                                                      "assetLoadingOverlay": False}})])
                         for k in range(11)] + [
                        SND("shot"),
                        gif({"<=": [V("vars.b3_shots"), 0]},
                            [vset("vars.b3_phase", "idle"),
                             call("@animated_sprite.set_animation", {"id": b3, "animation": "end1"})]),
                    ]),
                ]),
                # attack2: drift right -> windup -> sweep left w/ ray damage -> return
                gif({"==": [V("vars.b3_phase"), "a2_drift"]}, [
                    eadd(b3, "x", {"*": [50, V("event.dt")]}),
                    gif({">": [boss_cx, X(-6.5)]},
                        [vset("vars.b3_phase", "a2_wind"), vset("vars.b3_pt", 0.8),
                         SND("thunder")])]),
                gif({"==": [V("vars.b3_phase"), "a2_wind"]}, [
                    vset("vars.b3_pt", {"-": [V("vars.b3_pt"), V("event.dt")]}),
                    gif({"<=": [V("vars.b3_pt"), 0]},
                        [vset("vars.b3_phase", "a2_sweep"),
                         call("@animated_sprite.set_animation", {"id": b3, "animation": "firing2"})])]),
                gif({"==": [V("vars.b3_phase"), "a2_sweep"]}, [
                    eadd(b3, "x", {"*": [-50, V("event.dt")]}),
                    # mouth ray: player under boss within band -> tick damage
                    gif({"and": [{"<": [{"max": [{"-": [PCX, boss_cx]}, {"-": [boss_cx, PCX]}]}, 20]},
                                 {"!=": [V("vars.state"), "dead"]}]}, [
                        vset("vars.b3_hit", {"+": [V("vars.b3_hit"), V("event.dt")]}),
                        gif({">": [V("vars.b3_hit"), 0.75]},
                            [vset("vars.b3_hit", 0),
                             vset("vars.hp", {"-": [V("vars.hp"), 25]}), SND("shot_hit")])]),
                    gif({"<": [boss_cx, X(-8.28)]},
                        [vset("vars.b3_phase", "a2_back"),
                         call("@animated_sprite.set_animation", {"id": b3, "animation": "end2"})])]),
                gif({"==": [V("vars.b3_phase"), "a2_back"]}, [
                    eadd(b3, "x", {"*": [50, V("event.dt")]}),
                    gif({">": [boss_cx, X(-7.49)]},
                        [vset("vars.b3_phase", "idle"),
                         call("@animated_sprite.set_animation", {"id": b3, "animation": "attack1"})])]),
            ]),
        ]),
    ]
    MAIN += mk_pb_loop()
    MAIN += mk_pg_loop()
    MAIN += mk_hb_loop()
    MAIN += [
        eset("cam", "x", X(-7.563)), eset("cam", "y", Y(0.057)),
        gif({"<": [V("entities.player.x"), X(-8.72)]}, [eset("player", "x", X(-8.72))]),
        gif({">": [V("entities.player.x"), X(-6.55)]}, [eset("player", "x", X(-6.55))]),
    ]
    MAIN += mk_hud_death()
    logic = [gif({"==": [V("vars.state"), "loading"]}, [vset("vars.state", "running")]),
             gif(RUN, MAIN)] + DEAD_TAIL
    return mk_game(v, ents, mk_input("boss_bgm", "v_complete" if False else "v_m3"),
                   logic, "m3_bgm.mp3")


# ---------- gamepad (stick + JUMP + FIRE + GRENADE) ----------
def pad_button(label, color, down_input, up_input, size=76):
    return {"type": "gesture_detector",
            "onTapDown": {"call": "@flame_game_input", "args": {"input": down_input}},
            "onTapUp": {"call": "@flame_game_input", "args": {"input": up_input}},
            "child": {"type": "container", "width": size, "height": size,
                      "borderRadius": size // 2, "color": color, "alignment": "center",
                      "children": [{"type": "text", "value": label,
                                    "style": {"fontSize": 15, "fontWeight": "bold",
                                              "color": "#FFFFFF", "textAlign": "center"}}]}}


gamepad = {
    "type": "container", "height": 185, "color": "#12182B", "layout": "row", "padding": 10,
    "children": [
        {"type": "gesture_detector",
         "onTapDown": {"call": "@navigate", "args": {"screen": "select"}},
         "child": {"type": "container", "width": 34, "height": 185, "color": "#0B1020",
                   "alignment": "center",
                   "children": [{"type": "text", "value": "≡",
                                 "style": {"fontSize": 18, "color": "#8899AA"}}]}},
        {"type": "container", "layout": "row", "alignment": "center",
         "position": {"type": "flex", "flex": 5},
         "children": [{"type": "container", "width": 145, "height": 145,
                       "children": [{"type": "analog_stick", "backgroundColor": "#0B1020",
                                     "knobColor": "#FFB020", "deadZone": 0.08,
                                     "onChange": {"call": "@flame_game_input", "args": {
                                         "input": "move_axis",
                                         "data": {"x": "{{ event.x }}", "y": "{{ event.y }}",
                                                  "strength": "{{ event.strength }}",
                                                  "angle": "{{ event.angle }}",
                                                  "direction": "{{ event.direction }}"}}},
                                     "onEnd": {"call": "@flame_game_input", "args": {
                                         "input": "move_axis",
                                         "data": {"x": 0, "y": 0, "strength": 0, "angle": 0,
                                                  "direction": "center"}}}}]}]},
        {"type": "container", "layout": "row", "alignment": "center",
         "mainAxisAlignment": "spaceBetween", "position": {"type": "flex", "flex": 7},
         "children": [
             {"type": "container", "width": 10},
             pad_button("BOMB", "#7D3C98", "grenade", "jump_end", 64),
             pad_button("FIRE", "#C0392B", "attack", "attack_end"),
             pad_button("JUMP", "#2471A3", "jump", "jump_end"),
             {"type": "container", "width": 6},
         ]},
    ],
}

m2_game = build_m2()
m3_game = build_m3()
m3b_game = build_m3boss()


def mission_screen(sid, g):
    return {"id": sid, "title": "Metal Slug", "backgroundColor": "#000000",
            "appBar": False, "layout": "column", "padding": 0,
            "children": [{"type": "expanded", "child": g}, gamepad]}


def sel_button(label, screen):
    return {"type": "container", "layout": "column", "padding": 6, "children": [
        {"type": "button", "label": label, "variant": "filled",
         "style": {"backgroundColor": "#B03A2E", "textColor": "#FFFFFF",
                   "fontSize": 18, "borderRadius": 10, "paddingV": 14},
         "action": {"type": "navigate", "screen": screen}}]}


select_screen = {
    "id": "select", "title": "Metal Slug", "backgroundColor": "#101018",
    "appBar": False, "layout": "column", "padding": 24,
    "children": [
        {"type": "container", "height": 46},
        {"type": "text", "value": "METAL SLUG",
         "style": {"fontSize": 34, "fontWeight": "bold", "color": "#FFB020",
                   "textAlign": "center"}},
        {"type": "text", "value": "SELECT MISSION",
         "style": {"fontSize": 15, "color": "#FFFFFF", "textAlign": "center"}},
        {"type": "container", "height": 18},
        sel_button("MISSION 1", "m1"),
        sel_button("MISSION 2", "m2"),
        sel_button("MISSION 3", "m3"),
        sel_button("FINAL BOSS", "m3b"),
        {"type": "container", "height": 14},
        {"type": "text",
         "value": "port of github.com/giacoballoccu/MetalSlugClone (fan project, SNK IP — educational demo)",
         "style": {"fontSize": 10, "color": "#8899AA", "textAlign": "center"}},
    ],
}

app = {
    "dsl": "3.3",
    "appid": APPID,
    "meta": {
        "name": "demo-metalslug", "version": "1.1.0", "type": "app",
        "displayName": {"zh": "合金弹头 Mission 1（开源移植）", "en": "Metal Slug M1 (fan port)"},
        "description": "giacoballoccu/MetalSlugClone（Unity 粉丝重制）Mission 1 的 JSON-DSL 移植：跑打跳蹲、手雷、重机枪、蟹群、伞兵、面包车轰炸、Marco 船段与 Boss 追逐战。Fan/educational demo — Metal Slug is SNK IP.",
        "attribution": {
            "source": "https://github.com/giacoballoccu/MetalSlugClone",
            "license": "no license file (fan project); Metal Slug assets © SNK",
            "note": "Educational demo port; not for redistribution."},
    },
    "global": {"variables": {"_pad": 0, "ms_score": 0, "ms_bombs": 10,
                             "ms_mg": 0, "ms_hp": 100},
                "functions": {"gotoM3Boss": {
                    "params": ["score", "bombs", "mg", "hp"],
                    "logic": [
                        {"call": "@set", "args": {"var": "global.ms_score", "value": "{{ params.score }}"}},
                        {"call": "@set", "args": {"var": "global.ms_bombs", "value": "{{ params.bombs }}"}},
                        {"call": "@set", "args": {"var": "global.ms_mg", "value": "{{ params.mg }}"}},
                        {"call": "@set", "args": {"var": "global.ms_hp", "value": "{{ params.hp }}"}},
                        {"call": "@navigate", "args": {"screen": "m3b"}},
                    ]}}},
    "ui": {"screens": [
        select_screen,
        mission_screen("m1", game),
        mission_screen("m2", m2_game),
        mission_screen("m3", m3_game),
        mission_screen("m3b", m3b_game),
    ]},
}

out = os.path.join(HERE, "../templates/demo_metalslug.json")
json.dump(app, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print("wrote", os.path.abspath(out), "appid", APPID, "entities", len(entities),
      "logic-steps", len(M))
