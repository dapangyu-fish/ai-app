#!/usr/bin/env python3
"""Build templates/demo_contra.json — Contra port on the flame_game DSL.
All mechanics constants transcribed from /home/fish/Contra (MIT) source."""
import json
import uuid

BASE = "https://myapp-demo-de-oss-endpoint.dapangyu.work/json-app-assets/demo-contra/1.0.0/"
SPR = BASE + "sprites/"
APPID = str(uuid.uuid5(uuid.NAMESPACE_DNS, "myapp-template:demo-contra"))

# ---- original constants (pygame source) ----
SPEED = 500          # player.py Entity.speed
GRAVITY = 2400       # player.py gravity 40/frame @60fps
JUMP_VY = -1100      # player.py jump_speed
MAX_FALL = 1500
BULLET_V = 2000      # bullet.py speed
BULLET_TTL = 1.0     # bullet.py 1000ms
FIRE_CD = 0.2        # entity.py cooldown 200ms
ENEMY_CD = 0.8       # enemy.py cooldown 800ms
ENEMY_RANGE = 600    # enemy.py distance<600
HP = 20              # entity.py health
ENEMY_HP = 3
PLAT_SPEED = 200     # tile.py MovingPlatform
INVUL = 0.2          # entity.py invul_duration 200ms
ANIM_FPS = 7         # entity.py animate 7*dt
STEP = round(1 / ANIM_FPS, 3)

V = lambda p: {"var": p}          # noqa: E731
def IF(c, t, e): return {"if": [c, t, e]}


def anim(asset, frames, w, h, step=STEP, loop=True):
    a = {"asset": SPR + asset, "frame_size": [w, h], "frames": frames,
         "frames_per_row": frames, "step_time": step}
    if not loop:
        a["loop"] = False
    return a


PLAYER_ANIMS = {
    "right_run":  anim("player_right.png", 8, 92, 124),
    "left_run":   anim("player_left.png", 8, 92, 124),
    "right_idle": anim("player_right_idle.png", 6, 92, 124),
    "left_idle":  anim("player_left_idle.png", 6, 92, 124),
    "right_jump": anim("player_right_jump.png", 1, 92, 124),
    "left_jump":  anim("player_left_jump.png", 1, 92, 124),
    "right_duck": anim("player_right_duck.png", 1, 92, 124),
    "left_duck":  anim("player_left_duck.png", 1, 92, 124),
}

def call(name, args=None, assign=None):
    c = {"call": name}
    if args is not None:
        c["args"] = args
    if assign:
        c["assign"] = assign
    return c


def gif(cond, then, els=None):
    args = {"cond": cond, "then": then}
    if els:
        args["else"] = els
    return call("@if", args)


def eset(id_, field, value):
    return call("@entity.set", {"id": id_, "field": field, "value": value})


def eadd(id_, field, by, mn=None, mx=None):
    a = {"id": id_, "field": field, "by": by}
    if mn is not None:
        a["min"] = mn
    if mx is not None:
        a["max"] = mx
    return call("@entity.add", a)


def vset(var, value):
    return call("@set", {"var": var, "value": value})


# ---------- entities ----------
def sky(i, layer):
    return {
        "kind": "sprite", "priority": -60 if layer == "bg" else -55,
        "asset": BASE + f"sky/{layer}_sky.png",
        "position": [-4000, 800], "size": [1984, 1088],
        "auto_update": False,
        "state": {"assetLoadingOverlay": False},
    }


entities = {}
for i in range(3):
    entities[f"sky_bg_{i}"] = sky(i, "bg")
for i in range(3):
    entities[f"sky_fg_{i}"] = sky(i, "fg")

entities["map"] = {
    "kind": "tiled_map", "priority": -40,
    "source": "tiles/contra.tmx", "base_url": BASE, "scale": 1,
    "include_layers": ["BG", "BG Detail", "Level"],
    "solid_layers": ["Level"], "collidable": True,
    "render": {"shape": "text", "value": "Loading map", "color": "#FFFFFF"},
}
entities["map_fg"] = {
    "kind": "tiled_map", "priority": 80,
    "source": "tiles/contra.tmx", "base_url": BASE, "scale": 1,
    "include_layers": ["FG Detail Bottom", "FG Detail Top"],
    "solid_layers": [], "collidable": False,
}

# platforms: corridors from map.tmx Border rects (platform.top ranges)
entities["plat_w"] = {
    "kind": "sprite", "priority": -10, "asset": SPR + "p2.png",
    "position": [1517, 2060], "size": [94, 56], "auto_update": False,
    "state": {"dir": -1, "top_min": 1408.7, "top_max": 2060.3,
              "assetLoadingOverlay": False},
}
entities["plat_e"] = {
    "kind": "sprite", "priority": -10, "asset": SPR + "p1.png",
    "position": [4067, 2312], "size": [192, 56], "auto_update": False,
    "state": {"dir": -1, "top_min": 1003.3, "top_max": 2312.7,
              "assetLoadingOverlay": False},
}

entities["player"] = {
    "kind": "animated_sprite", "priority": 40,
    "position": [687, 2255], "size": [64, 120], "velocity": [0, 0],
    "auto_update": False, "animation": "right_idle",
    "asset": SPR + "player_right_idle.png", "frame_size": [92, 124],
    "frames": 6, "frames_per_row": 6, "step_time": STEP,
    "animations": PLAYER_ANIMS,
    "state": {"spriteW": 92, "spriteH": 124, "spriteOffsetX": -14,
              "spriteOffsetY": -4, "assetLoadingOverlay": False},
}

entities["hud_hp_icon"] = {
    "kind": "sprite", "priority": 220, "asset": SPR + "health.png",
    "position": [16, 12], "size": [16, 32], "fixed_to_screen": True,
    "auto_update": False, "state": {"assetLoadingOverlay": False},
}
entities["hud_hp_text"] = {
    "kind": "pixel", "priority": 220, "position": [42, 18], "size": [1, 1],
    "fixed_to_screen": True, "auto_update": False,
    "render": {"shape": "text", "value": "x 20", "color": "#FFFFFF",
               "fontSize": 22},
}

entities["title_bg"] = {
    "kind": "pixel", "priority": 200, "position": [0, 0], "size": [1280, 720],
    "fixed_to_screen": True, "auto_update": False,
    "render": {"shape": "rect", "color": "#101018"},
}
entities["title_text"] = {
    "kind": "pixel", "priority": 201, "position": [420, 240], "size": [1, 1],
    "fixed_to_screen": True, "auto_update": False,
    "render": {"shape": "text", "value": "C O N T R A", "color": "#FF4040",
               "fontSize": 72},
}
entities["title_sub"] = {
    "kind": "pixel", "priority": 201, "position": [455, 400], "size": [1, 1],
    "fixed_to_screen": True, "auto_update": False,
    "render": {"shape": "text", "value": "TAP OR PRESS TO START",
               "color": "#FFFFFF", "fontSize": 26},
}
entities["title_credit"] = {
    "kind": "pixel", "priority": 201, "position": [340, 640], "size": [1, 1],
    "fixed_to_screen": True, "auto_update": False,
    "render": {"shape": "text",
               "value": "port of github.com/hanessn1/Contra (MIT)",
               "color": "#8899AA", "fontSize": 18},
}

# ---------- enemy spawn template ----------
ENEMY_TEMPLATE = {
    "id_prefix": "enemy_", "kind": "animated_sprite", "priority": 30,
    "asset": SPR + "enemy_left.png", "frame_size": [96, 112],
    "frames": 3, "frames_per_row": 3, "step_time": STEP,
    "position": ["{{ object.x }}", "{{ object.y }}"],
    "size": [96, 112], "velocity": [0, 0], "auto_update": False,
    "animation": "left",
    "animations": {
        "right": anim("enemy_right.png", 3, 96, 112),
        "left": anim("enemy_left.png", 3, 96, 112),
    },
    "state": {"hp": ENEMY_HP, "cd": ENEMY_CD, "assetLoadingOverlay": False},
}

# ---------- input ----------
START = [
    vset("vars.state", "loading"),
    call("@despawn", {"id": "title_bg"}),
    call("@despawn", {"id": "title_text"}),
    call("@despawn", {"id": "title_sub"}),
    call("@despawn", {"id": "title_credit"}),
    call("@audio.play", {"id": "music", "loop": True, "restart": True}),
]
TITLE = {"==": [V("vars.state"), "title"]}
RUNNING = {"==": [V("vars.state"), "running"]}

INPUT = {
    "move_axis": [
        gif(TITLE, START),
        vset("vars.move_axis", V("event.x")),
        gif({">": [V("event.x"), 0.08]}, [vset("vars.facing", 1)]),
        gif({"<": [V("event.x"), -0.08]}, [vset("vars.facing", -1)]),
        vset("vars.duck", {">": [V("event.y"), 0.5]}),
        gif({"<": [V("event.y"), -0.6]}, [vset("vars.jump_pressed", True)]),
    ],
    "jump": [gif(TITLE, START, [vset("vars.jump_pressed", True)])],
    "jump_end": [vset("vars._noop", 0)],
    "attack": [gif(TITLE, START, [vset("vars.fire_held", True)])],
    "attack_end": [vset("vars.fire_held", False)],
    "tap": [gif(TITLE, START)],
}

# ---------- frame.logic ----------
GROUNDED_ALL = {"or": [V("vars.grounded"), V("vars.on_platform")]}

def platform_step(pid):
    top_min = entities[pid]["state"]["top_min"]
    top_max = entities[pid]["state"]["top_max"]
    return [
        eadd(pid, "y", {"*": [V(f"entities.{pid}.dir"),
                              {"*": [PLAT_SPEED, V("event.dt")]}]}),
        gif({"<=": [V(f"entities.{pid}.y"), top_min]},
            [eset(pid, "y", top_min), eset(pid, "state.dir", 1)]),
        gif({">=": [V(f"entities.{pid}.y"), top_max]},
            [eset(pid, "y", top_max), eset(pid, "state.dir", -1)]),
    ]


def platform_carry(pid):
    px, pw = f"entities.{pid}.x", entities[pid]["size"][0]
    py = f"entities.{pid}.y"
    return [
        gif({"and": [
            {">": [{"+": [V("entities.player.x"), 64]}, V(px)]},
            {"<": [V("entities.player.x"), {"+": [V(px), pw]}]},
            {">=": [{"+": [V("entities.player.y"), 120]}, {"-": [V(py), 12]}]},
            {"<=": [{"+": [V("entities.player.y"), 120]}, {"+": [V(py), 26]}]},
            {">=": [V("entities.player.vy"), 0]},
        ]}, [
            eset("player", "y", {"-": [V(py), 120]}),
            eset("player", "vy", 0),
            vset("vars.on_platform", True),
        ]),
    ]


def fire_bullet(shooter_cx, shooter_cy, facing_expr, duck_expr, prefix):
    """Spawn bullet + muzzle flash from an expression-position. Returns steps."""
    yoff = IF(duck_expr, 10, -16) if duck_expr is not None else -16
    return [
        vset("vars.bseq", {"+": [V("vars.bseq"), 1]}),
        call("@spawn", {
            "id": prefix + "{{ vars.bseq }}", "kind": "sprite", "priority": 45,
            "asset": SPR + "bullet.png", "size": [20, 12],
            "flip_x": {"<": [facing_expr, 0]},
            "position": [
                {"+": [shooter_cx, {"-": [{"*": [facing_expr, 80]}, 10]}]},
                {"+": [shooter_cy, {"-": [yoff, 6]}]}],
            "velocity": [{"*": [facing_expr, BULLET_V]}, 0],
            "auto_update": True,
            "state": {"ttl": BULLET_TTL, "assetLoadingOverlay": False},
        }),
        call("@spawn", {
            "id": "fx_{{ vars.bseq }}", "kind": "animated_sprite",
            "priority": 46,
            "asset": SPR + "fire_right.png", "frame_size": [31, 20],
            "frames": 2, "frames_per_row": 2, "step_time": 0.066,
            "loop": False,
            "animations": {
                "flash_r": dict(anim("fire_right.png", 2, 31, 20, 0.066),
                                loop=False),
                "flash_l": dict(anim("fire_left.png", 2, 31, 20, 0.066),
                                loop=False)},
            "animation": IF({"<": [facing_expr, 0]}, "flash_l", "flash_r"),
            "position": [
                {"+": [shooter_cx, {"-": [{"*": [facing_expr, 60]}, 15]}]},
                {"+": [shooter_cy, {"-": [yoff, 10]}]}],
            "size": [31, 20], "auto_update": True,
            "state": {"removeOnFinish": True, "assetLoadingOverlay": False},
        }),
        call("@audio.play", {"id": "bullet"}),
    ]


P_CX = {"+": [V("entities.player.x"), 32]}
P_CY = {"+": [V("entities.player.y"), 60]}

MAIN = []
# timers
MAIN += [
    vset("vars.fire_cd", {"max": [0, {"-": [V("vars.fire_cd"), V("event.dt")]}]}),
    vset("vars.invul", {"max": [0, {"-": [V("vars.invul"), V("event.dt")]}]}),
    vset("vars.on_platform", False),
]
# horizontal velocity (instant, like the original)
MAIN += [
    eset("player", "vx", IF(
        {"and": [V("vars.duck"), GROUNDED_ALL]}, 0,
        IF({">": [V("vars.move_axis"), 0.08]}, SPEED,
           IF({"<": [V("vars.move_axis"), -0.08]}, -SPEED, 0)))),
]
# jump (manual: covers ground + moving platforms)
MAIN += [
    gif({"and": [V("vars.jump_pressed"),
                 {"or": [V("vars.grounded"), V("vars.on_platform")]}]},
        [eset("player", "vy", JUMP_VY), eadd("player", "y", -4),
         vset("vars.on_platform", False)]),
    vset("vars.jump_pressed", False),
]
# physics step (all Level tiles solid — walls block)
MAIN += [
    call("@platformer.step", {
        "id": "player", "map": "map", "dt": "{{ event.dt }}",
        "gravity": GRAVITY, "max_fall": MAX_FALL, "one_way_types": []}),
]
# platforms move + carry
MAIN += platform_step("plat_w") + platform_step("plat_e")
MAIN += platform_carry("plat_w") + platform_carry("plat_e")
MAIN += [vset("vars.grounded", V("entities.player.onGround"))]
# duck hitbox toggle (feet stay planted)
MAIN += [
    gif({"and": [V("vars.duck"), GROUNDED_ALL, {"!": V("vars.was_duck")}]}, [
        eset("player", "h", 70), eadd("player", "y", 50),
        eset("player", "state.spriteOffsetY", -54), vset("vars.was_duck", True)]),
    gif({"and": [{"!": V("vars.duck")}, V("vars.was_duck")]}, [
        eset("player", "h", 120), eadd("player", "y", -50),
        eset("player", "state.spriteOffsetY", -4), vset("vars.was_duck", False)]),
]
# player fire (hold-to-fire, 200ms cadence)
MAIN += [
    gif({"and": [V("vars.fire_held"), {"<=": [V("vars.fire_cd"), 0]}]},
        fire_bullet(P_CX, P_CY, V("vars.facing"), V("vars.duck"), "pb_")
        + [vset("vars.fire_cd", FIRE_CD)]),
]
# enemies: face player, cooldown, fire when in range & same height band
MAIN += [
    call("@for_each_entity", {"where_prefix": "enemy_", "do": [
        vset("vars._eid", "{{ loop.id }}"),
        eadd("{{ vars._eid }}", "state.cd", {"*": [-1, V("event.dt")]}, mn=0),
        vset("vars._ex", call("@entity.get", {"id": "{{ vars._eid }}", "field": "x"})),
        vset("vars._ey", call("@entity.get", {"id": "{{ vars._eid }}", "field": "y"})),
        vset("vars._efacing", IF({"<": [P_CX, {"+": [V("vars._ex"), 48]}]}, -1, 1)),
        call("@animated_sprite.set_animation", {
            "id": "{{ vars._eid }}",
            "animation": IF({"==": [V("vars._efacing"), 1]}, "right", "left")}),
        gif({"and": [
            {"<": [{"max": [{"-": [P_CX, {"+": [V("vars._ex"), 48]}]}, {"-": [{"+": [V("vars._ex"), 48]}, P_CX]}]}, ENEMY_RANGE]},
            {">": [P_CY, {"-": [V("vars._ey"), 20]}]},
            {"<": [P_CY, {"+": [V("vars._ey"), 132]}]},
            {"<=": [call("@entity.get", {"id": "{{ vars._eid }}", "field": "state.cd"}), 0]},
        ]},
            fire_bullet({"+": [V("vars._ex"), 48]}, {"+": [V("vars._ey"), 56]},
                        V("vars._efacing"), None, "eb_")
            + [eset("{{ vars._eid }}", "state.cd", ENEMY_CD)]),
    ]}),
]
# player bullets: ttl, walls, enemies
MAIN += [
    call("@for_each_entity", {"where_prefix": "pb_", "do": [
        vset("vars._bid", "{{ loop.id }}"),
        eadd("{{ vars._bid }}", "state.ttl", {"*": [-1, V("event.dt")]}),
        gif({"<=": [call("@entity.get", {"id": "{{ vars._bid }}", "field": "state.ttl"}), 0]},
            [call("@despawn", {"id": "{{ vars._bid }}"})],
            [
                call("@tiled.has_collision_type",
                     {"map": "map", "entity": "{{ vars._bid }}", "type": "platform"},
                     assign="vars._bwall"),
                gif(V("vars._bwall"), [call("@despawn", {"id": "{{ vars._bid }}"})], [
                    call("@collision.first",
                         {"a": "{{ vars._bid }}", "where_prefix": "enemy_"},
                         assign="vars._bhit"),
                    gif({"!=": [V("vars._bhit"), None]}, [
                        call("@despawn", {"id": "{{ vars._bid }}"}),
                        eadd("{{ vars._bhit }}", "state.hp", -1),
                        call("@audio.play", {"id": "hit"}),
                        gif({"<=": [call("@entity.get", {"id": "{{ vars._bhit }}", "field": "state.hp"}), 0]},
                            [call("@despawn", {"id": "{{ vars._bhit }}"})]),
                        vset("vars._bhit", None),
                    ]),
                ]),
            ]),
    ]}),
]
# enemy bullets: ttl + walls; then one hit-test vs player
MAIN += [
    call("@for_each_entity", {"where_prefix": "eb_", "do": [
        vset("vars._bid", "{{ loop.id }}"),
        eadd("{{ vars._bid }}", "state.ttl", {"*": [-1, V("event.dt")]}),
        gif({"<=": [call("@entity.get", {"id": "{{ vars._bid }}", "field": "state.ttl"}), 0]},
            [call("@despawn", {"id": "{{ vars._bid }}"})],
            [
                call("@tiled.has_collision_type",
                     {"map": "map", "entity": "{{ vars._bid }}", "type": "platform"},
                     assign="vars._bwall"),
                gif(V("vars._bwall"), [call("@despawn", {"id": "{{ vars._bid }}"})]),
            ]),
    ]}),
    call("@collision.first", {"a": "player", "where_prefix": "eb_"},
         assign="vars.hit_eb"),
    gif({"!=": [V("vars.hit_eb"), None]}, [
        call("@despawn", {"id": "{{ vars.hit_eb }}"}),
        gif({"<=": [V("vars.invul"), 0]}, [
            vset("vars.hp", {"-": [V("vars.hp"), 1]}),
            vset("vars.invul", INVUL),
            call("@audio.play", {"id": "hit"}),
            eset("hud_hp_text", "render.value", {"cat": ["x ", V("vars.hp")]}),
        ]),
        vset("vars.hit_eb", None),
    ]),
]
# death / fall-off / win
MAIN += [
    gif({"or": [{"<=": [V("vars.hp"), 0]},
                {">": [V("entities.player.y"), 3300]}]}, [
        vset("vars.state", "over"),
        call("@audio.stop", {"id": "music"}),
        call("@game_over", {}),
    ]),
    gif({">": [V("entities.player.x"), 5000]}, [
        vset("vars.state", "over"),
        call("@audio.stop", {"id": "music"}),
        call("@spawn", {
            "id": "win_text", "kind": "pixel", "priority": 230,
            "position": [340, 300], "size": [1, 1], "fixed_to_screen": True,
            "render": {"shape": "text", "value": "MISSION COMPLETE",
                       "color": "#FFD24A", "fontSize": 52}}),
        call("@game_over", {}),
    ]),
]
# animation select
MAIN += [
    vset("vars._anim", {"cat": [
        IF({"==": [V("vars.facing"), 1]}, "right", "left"),
        IF({"!": GROUNDED_ALL}, "_jump",
           IF({"and": [V("vars.duck"), GROUNDED_ALL]}, "_duck",
              IF({"!=": [V("entities.player.vx"), 0]}, "_run", "_idle")))]}),
    call("@animated_sprite.set_animation",
         {"id": "player", "animation": "{{ vars._anim }}"}),
]
# parallax sky (original: base y 800, bg factor 2.5, fg factor 2)
CAM_X = {"min": [{"max": [{"-": [P_CX, 640]}, 0]}, 3840]}
CAM_Y = {"min": [{"max": [{"-": [P_CY, 360]}, 0]}, 2480]}
MAIN += [
    vset("vars._cam_x", CAM_X),
    vset("vars._cam_y", CAM_Y),
    vset("vars._sky_mx", {"+": [V("vars._cam_x"),
        {"%": [{"-": [-640, {"/": [V("vars._cam_x"), 2.5]}]}, 1984]}]}),
    vset("vars._sky_my", {"+": [V("vars._cam_y"),
        {"-": [800, {"/": [V("vars._cam_y"), 2.5]}]}]}),
    vset("vars._skyf_mx", {"+": [V("vars._cam_x"),
        {"%": [{"-": [-640, {"/": [V("vars._cam_x"), 2]}]}, 1984]}]}),
    vset("vars._skyf_my", {"+": [V("vars._cam_y"),
        {"-": [800, {"/": [V("vars._cam_y"), 2]}]}]}),
]
for i in range(3):
    off = (i - 1) * 1984
    MAIN += [
        eset(f"sky_bg_{i}", "x", {"+": [V("vars._sky_mx"), off]}),
        eset(f"sky_bg_{i}", "y", V("vars._sky_my")),
        eset(f"sky_fg_{i}", "x", {"+": [V("vars._skyf_mx"), off]}),
        eset(f"sky_fg_{i}", "y", V("vars._skyf_my")),
    ]

FRAME_LOGIC = [
    gif({"==": [V("vars.state"), "loading"]}, [
        gif(call("@tiled.loaded", {"map": "map"}), [
            call("@tiled.spawn_objects", {
                "map": "map", "layer": "Entities", "debug": True,
                "templates": {"Enemy": ENEMY_TEMPLATE}}),
            vset("vars.state", "running"),
        ]),
    ]),
    gif(RUNNING, MAIN),
]

game = {
    "type": "flame_game",
    "world": {"kind": "pixel", "bg": "#F98367"},
    "viewport": {"width": 1280, "height": 720, "fit": "contain"},
    "physics": {"engine": "leap_platformer", "fallback": "aabb_platformer"},
    "camera": {"follow": "player", "map": "map", "offset_x": 0, "offset_y": 0,
               "deadzone_y": 0, "smooth_y": 1},
    "overlay": {"score": False, "game_over": True, "asset_loading": True,
                "asset_loading_text": "Loading Contra assets..."},
    "vars": {
        "state": "title", "hp": HP, "move_axis": 0, "facing": 1,
        "duck": False, "was_duck": False, "jump_pressed": False,
        "fire_held": False, "fire_cd": 0, "bseq": 0,
        "grounded": False, "on_platform": False, "invul": 0,
        "hit_eb": None, "_noop": 0, "_anim": "right_idle",
        "_eid": "", "_ex": 0, "_ey": 0, "_efacing": 1,
        "_bid": "", "_bwall": False, "_bhit": None,
        "_cam_x": 0, "_cam_y": 0,
        "_sky_mx": 0, "_sky_my": 0, "_skyf_mx": 0, "_skyf_my": 0,
    },
    "entities": entities,
    "input": INPUT,
    "frame": {"logic": FRAME_LOGIC},
    "audio": {
        "base_url": BASE + "audio/",
        "tracks": {"music": {"src": "music.wav", "loop": True, "volume": 0.45}},
        "sounds": {"bullet": {"src": "bullet.wav", "volume": 0.5},
                   "hit": {"src": "hit.wav", "volume": 0.5}},
    },
}

# ---------- gamepad (custom: hold-to-fire needs press/release) ----------
def pad_button(label, color, down_input, up_input):
    return {
        "type": "gesture_detector",
        "onTapDown": {"call": "@flame_game_input", "args": {"input": down_input}},
        "onTapUp": {"call": "@flame_game_input", "args": {"input": up_input}},
        "child": {
            "type": "container", "width": 92, "height": 92,
            "borderRadius": 46, "color": color, "alignment": "center",
            "children": [{"type": "text", "value": label,
                          "style": {"fontSize": 20, "fontWeight": "bold",
                                    "color": "#FFFFFF", "textAlign": "center"}}],
        },
    }


gamepad = {
    "type": "container", "height": 190, "color": "#141C2E", "layout": "row",
    "padding": 12,
    "children": [
        {"type": "container", "layout": "row", "alignment": "center",
         "position": {"type": "flex", "flex": 5},
         "children": [{
             "type": "container", "width": 150, "height": 150,
             "children": [{
                 "type": "analog_stick",
                 "backgroundColor": "#0B1020", "knobColor": "#4A6CFF",
                 "deadZone": 0.08,
                 "onChange": {"call": "@flame_game_input", "args": {
                     "input": "move_axis",
                     "data": {"x": "{{ event.x }}", "y": "{{ event.y }}",
                              "strength": "{{ event.strength }}",
                              "angle": "{{ event.angle }}",
                              "direction": "{{ event.direction }}"}}},
                 "onEnd": {"call": "@flame_game_input", "args": {
                     "input": "move_axis",
                     "data": {"x": 0, "y": 0, "strength": 0, "angle": 0,
                              "direction": "center"}}},
             }]}]},
        {"type": "container", "layout": "row", "alignment": "center",
         "mainAxisAlignment": "spaceBetween",
         "position": {"type": "flex", "flex": 6},
         "children": [
             {"type": "container", "width": 24},
             pad_button("FIRE", "#C0392B", "attack", "attack_end"),
             pad_button("JUMP", "#2471A3", "jump", "jump_end"),
             {"type": "container", "width": 8},
         ]},
    ],
}

app = {
    "dsl": "3.3",
    "appid": APPID,
    "meta": {
        "name": "demo-contra", "version": "1.0.1", "type": "app",
        "displayName": {"zh": "魂斗罗（开源移植）", "en": "Contra (open-source port)"},
        "description": "hanessn1/Contra（MIT 开源 pygame 游戏）的完整 JSON-DSL 移植：跑打跳蹲、持枪扫射、移动平台、视差卷轴。Complete JSON-DSL port of the MIT-licensed pygame Contra.",
        "attribution": {
            "source": "https://github.com/hanessn1/Contra",
            "license": "MIT (c) 2023 Sagnik Barman",
            "note": "Game code & assets from the MIT-licensed repo; 'Contra' is a Konami trademark — this is a fan/educational demo."},
    },
    "global": {"variables": {"_pad": 0}, "functions": {}},
    "ui": {"screens": [{
        "id": "game", "title": "Contra", "backgroundColor": "#000000",
        "appBar": False, "layout": "column", "padding": 0,
        "children": [
            {"type": "expanded", "child": game},
            gamepad,
        ],
    }]},
}

out = "/home/fish/ai-app/templates/demo_contra.json"
json.dump(app, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print("wrote", out, "appid", APPID)
