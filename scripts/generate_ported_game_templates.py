#!/usr/bin/env python3
"""Generate JSON-DSL ports for the current game migration batch.

The output is intentionally JSON-only. Each game is built from generic
`flame_game`, `game-controls`, and normal JSON UI atoms; there are no
game-specific Dart bridges.
"""

from __future__ import annotations

import json
import uuid
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
TEMPLATES = ROOT / "templates"
ASSET = "https://myapp-oss-endpoint.dapangyu.work/json-app-assets/asset-packs"


def u(name: str) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"myapp-json-port:{name}"))


def asset(pack: str, path: str) -> str:
    return f"{ASSET}/{pack}/1.0/{path}"


def save(app: dict[str, Any], filename: str) -> None:
    (TEMPLATES / filename).write_text(
        json.dumps(app, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def call(name: str, args: dict[str, Any] | None = None, assign: str | None = None) -> dict[str, Any]:
    out: dict[str, Any] = {"call": name, "args": args or {}}
    if assign:
        out["assign"] = assign
    return out


def setv(var: str, value: Any) -> dict[str, Any]:
    return call("@set", {"var": var, "value": value})


def iff(cond: Any, then: list[Any], otherwise: list[Any] | None = None) -> dict[str, Any]:
    out = {"cond": cond, "then": then}
    if otherwise is not None:
        out["else"] = otherwise
    return call("@if", out)


def e_set(entity: str, field: str, value: Any) -> dict[str, Any]:
    return call("@entity.set", {"id": entity, "field": field, "value": value})


def e_add(entity: str, field: str, by: Any, **extra: Any) -> dict[str, Any]:
    args = {"id": entity, "field": field, "by": by}
    args.update(extra)
    return call("@entity.add", args)


def spawn(entity_id: str, spec: dict[str, Any]) -> dict[str, Any]:
    args = {"id": entity_id}
    args.update(spec)
    return call("@spawn", args)


def despawn(entity_id: str) -> dict[str, Any]:
    return call("@despawn", {"id": entity_id})


def pixel(position: list[Any], size: list[Any], color: str, *, velocity: list[Any] | None = None, priority: int = 0, shape: str = "rect", state: dict[str, Any] | None = None) -> dict[str, Any]:
    out: dict[str, Any] = {
        "kind": "pixel",
        "position": position,
        "size": size,
        "velocity": velocity or [0, 0],
        "priority": priority,
        "render": {"shape": shape, "color": color},
    }
    if state:
        out["state"] = state
    return out


def sprite(pack: str, path: str, position: list[Any], size: list[Any], *, src: list[Any] | None = None, velocity: list[Any] | None = None, priority: int = 0, state: dict[str, Any] | None = None) -> dict[str, Any]:
    out: dict[str, Any] = {
        "kind": "sprite",
        "asset": asset(pack, path),
        "position": position,
        "size": size,
        "velocity": velocity or [0, 0],
        "priority": priority,
    }
    if src:
        out["src"] = src
    if state:
        out["state"] = state
    return out


def anim(pack: str, path: str, position: list[Any], size: list[Any], frame: list[int], frames: int, *, frames_per_row: int | None = None, velocity: list[Any] | None = None, priority: int = 0, state: dict[str, Any] | None = None, step_time: float = 0.09, animations: dict[str, Any] | None = None, animation: str | None = None) -> dict[str, Any]:
    out = sprite(pack, path, position, size, velocity=velocity, priority=priority, state=state)
    out.update({"kind": "animated_sprite", "frame_size": frame, "frames": frames, "step_time": step_time})
    if frames_per_row:
        out["frames_per_row"] = frames_per_row
    if animations:
        out["animations"] = animations
    if animation:
        out["animation"] = animation
    return out


def base_app(name: str, display_name: str, version: str, description: str, *, appid_name: str | None = None, deps: dict[str, str] | None = None, assets: dict[str, Any] | None = None, variables: dict[str, Any] | None = None, functions: dict[str, Any] | None = None, screens: list[dict[str, Any]] | None = None, steps: list[Any] | None = None) -> dict[str, Any]:
    return {
        "dsl": "3.3",
        "appid": u(appid_name or name),
        "meta": {
            "name": name,
            "displayName": display_name,
            "version": version,
            "type": "app",
            "description": description,
            "author": "fish",
        },
        "dependencies": deps or {"common-ui": "^1.3.0"},
        **({"assets": assets} if assets else {}),
        "global": {"variables": variables or {}, "functions": functions or {}},
        "steps": steps or [],
        "ui": {"screens": screens or []},
    }


def bundle(pack: str, license_name: str, description: str) -> dict[str, Any]:
    return {
        "baseUrl": f"{ASSET}/{pack}/1.0/",
        "manifest": "manifest.json",
        "license": license_name,
        "startupDownload": True,
        "description": description,
    }


def score_functions(game_title: str) -> dict[str, Any]:
    return {
        "scoreChanged": {
            "params": ["score"],
            "logic": [
                {"call": "@set", "args": {"var": "global.score", "value": "{{ params.score }}"}},
                {"call": "@if", "args": {"condition": {">": [{"var": "params.score"}, {"var": "global.bestScore"}]}, "then": [
                    {"call": "@set", "args": {"var": "global.bestScore", "value": "{{ params.score }}"}}
                ]}},
            ],
        },
        "status": {
            "params": ["text"],
            "logic": [{"call": "@set", "args": {"var": "global.status", "value": "{{ params.text }}"}}],
        },
        "over": {
            "params": ["score"],
            "logic": [
                {"call": "@set", "args": {"var": "global.score", "value": "{{ params.score }}"}},
                {"call": "@common-ui.choose", "args": {
                    "title": f"{game_title} finished",
                    "message": "Score: {{ params.score }}\nBest: {{ global.bestScore }}",
                    "buttons": [
                        {"label": "Close", "value": None, "style": "text"},
                        {"label": "Restart", "value": "restart"},
                    ],
                }, "assign": "global._choice"},
                {"call": "@if", "args": {"condition": {"==": [{"var": "global._choice"}, "restart"]}, "then": [
                    {"call": "@flame_game_reset", "args": {}}
                ]}},
            ],
        },
        "reset": {
            "logic": [
                {"call": "@set", "args": {"var": "global.score", "value": 0}},
                {"call": "@set", "args": {"var": "global.status", "value": "Ready"}},
            ],
        },
    }


def game_screen(title: str, subtitle: str, game: dict[str, Any], *, controls: dict[str, Any] | None = None, bg: str = "#111827") -> dict[str, Any]:
    children = [
        {
            "type": "container",
            "padding": 10,
            "color": bg,
            "layout": "row",
            "crossAxisAlignment": "center",
            "children": [
                {"type": "text", "value": subtitle, "style": {"fontSize": 13, "color": "#D1D5DB"}, "position": {"type": "flex", "flex": 1}},
                {"type": "text", "value": "Score {{ global.score }}", "style": {"fontSize": 13, "fontWeight": "bold", "color": "#FFFFFF"}},
            ],
        },
        {"type": "expanded", "child": game},
    ]
    if controls:
        children.append(controls)
    return {
        "id": "home",
        "title": title,
        "appBar": {
            "title": title,
            "centerTitle": True,
            "backgroundColor": bg,
            "color": "#FFFFFF",
            "actions": [
                {"icon": "replay", "action": {"call": "@flame_game_reset", "args": {}}},
            ],
        },
        "layout": "column",
        "padding": 0,
        "children": children,
    }


def gamepad(move: str, jump: str, attack: str, *, height: int = 176, bg: str = "#111827") -> dict[str, Any]:
    return {
        "type": "ref",
        "from": "game-controls",
        "widget": "psJoystickGamepad",
        "props": {
            "moveInput": move,
            "moveEndInput": move,
            "jumpInput": jump,
            "attackInput": attack,
            "height": height,
            "backgroundColor": bg,
        },
    }


def bgug() -> dict[str, Any]:
    pack = "source-bgug"
    game = {
        "type": "flame_game",
        "world": {"kind": "pixel", "bg": "#111827"},
        "overlay": {"game_over": False, "asset_loading_text": "Loading BGUG assets..."},
        "vars": {
            "state": "ready",
            "ground_y": 420,
            "top_y": 84,
            "speed": -248,
            "gravity": 1750,
            "jump_v": -620,
            "dive_v": 740,
            "spawn_timer": 0.2,
            "gem_timer": 0.6,
            "coin_timer": 2.2,
            "on_ground": True,
            "_id": 0,
            "_lane": 0,
            "_hit": None,
        },
        "entities": {
            "bg": {"kind": "parallax", "asset": asset(pack, "images/bg.png"), "speed_x": -90, "priority": -20},
            "top": pixel([0, 50], [{"var": "world.width"}, 28], "#0F172A", priority=-5),
            "floor": pixel([0, {"-": [{"var": "world.height"}, 52]}], [{"var": "world.width"}, 52], "#1F2937", priority=-5),
            "player": anim(pack, "images/skins/wizard.png", [88, 360], [44, 58], [16, 22], 8, frames_per_row=11, priority=20, state={"assetLoadingOverlay": True}),
        },
        "init": {"logic": [
            setv("vars.ground_y", {"-": [{"var": "world.height"}, 110]}),
            e_set("player", "y", {"var": "vars.ground_y"}),
            call("@emit", {"event": "status", "data": {"text": "Tap left to jump, right to dive"}}),
        ]},
        "input": {
            "tap": [
                iff({"==": [{"var": "vars.state"}, "ready"]}, [
                    setv("vars.state", "running"),
                    call("@emit", {"event": "status", "data": {"text": "Run"}}),
                ], [
                    iff({"<": [{"var": "event.x"}, {"/": [{"var": "world.width"}, 2]}]}, [
                        iff({"var": "vars.on_ground"}, [
                            e_set("player", "vy", {"var": "vars.jump_v"}),
                            setv("vars.on_ground", False),
                        ])
                    ], [
                        e_set("player", "vy", {"var": "vars.dive_v"})
                    ])
                ])
            ]
        },
        "tick": {"interval": 0.2, "logic": [
            iff({"==": [{"var": "vars.state"}, "running"]}, [call("@score.add", {"n": 1})])
        ]},
        "frame": {"logic": [
            iff({"!=": [{"var": "vars.state"}, "running"]}, [], [
                call("@pixel.add_velocity", {"id": "player", "dv": [0, {"*": [{"var": "vars.gravity"}, {"var": "event.dt"}]}]}),
                iff({">": [{"var": "entities.player.y"}, {"var": "vars.ground_y"}]}, [
                    e_set("player", "y", {"var": "vars.ground_y"}),
                    e_set("player", "vy", 0),
                    setv("vars.on_ground", True),
                ]),
                iff({"<": [{"var": "entities.player.y"}, {"var": "vars.top_y"}]}, [
                    e_set("player", "y", {"var": "vars.top_y"}),
                    e_set("player", "vy", 0),
                ]),
                e_add("player", "x", 0, min=88, max=88),
                setv("vars.spawn_timer", {"+": [{"var": "vars.spawn_timer"}, {"var": "event.dt"}]}),
                iff({">=": [{"var": "vars.spawn_timer"}, 1.05]}, [
                    setv("vars.spawn_timer", 0),
                    setv("vars._id", {"call": "@random_int", "args": {"min": 1000, "max": 999999}}),
                    setv("vars._lane", {"call": "@random_int", "args": {"min": 0, "max": 2}}),
                    iff({"==": [{"var": "vars._lane"}, 0]}, [
                        spawn("obstacle_{{ vars._id }}", sprite(pack, "images/obstacle.png", [{"var": "world.width"}, {"+": [{"var": "vars.ground_y"}, 18]}], [52, 52], src=[0, 0, 16, 16], velocity=[{"var": "vars.speed"}, 0], priority=10))
                    ], [
                        spawn("obstacle_{{ vars._id }}", sprite(pack, "images/up_obstacle.png", [{"var": "world.width"}, 92], [52, 52], src=[0, 0, 16, 16], velocity=[{"var": "vars.speed"}, 0], priority=10))
                    ])
                ]),
                setv("vars.gem_timer", {"+": [{"var": "vars.gem_timer"}, {"var": "event.dt"}]}),
                iff({">=": [{"var": "vars.gem_timer"}, 1.4]}, [
                    setv("vars.gem_timer", 0),
                    setv("vars._id", {"call": "@random_int", "args": {"min": 1000, "max": 999999}}),
                    spawn("gem_{{ vars._id }}", sprite(pack, "images/gem.png", [{"var": "world.width"}, {"call": "@random_int", "args": {"min": 120, "max": 410}}], [28, 28], velocity=[{"var": "vars.speed"}, 0], priority=12)),
                ]),
                setv("vars.coin_timer", {"+": [{"var": "vars.coin_timer"}, {"var": "event.dt"}]}),
                iff({">=": [{"var": "vars.coin_timer"}, 5.5]}, [
                    setv("vars.coin_timer", 0),
                    setv("vars._id", {"call": "@random_int", "args": {"min": 1000, "max": 999999}}),
                    spawn("coin_{{ vars._id }}", anim(pack, "images/coin.png", [{"var": "world.width"}, {"call": "@random_int", "args": {"min": 150, "max": 390}}], [36, 36], [16, 16], 10, frames_per_row=10, velocity=[{"var": "vars.speed"}, 0], priority=12)),
                ]),
                call("@collision.first", {"a": "player", "where_prefix": "obstacle_"}, "vars._hit"),
                iff({"!=": [{"var": "vars._hit"}, None]}, [call("@game_over")]),
                call("@collision.first", {"a": "player", "where_prefix": "gem_"}, "vars._hit"),
                iff({"!=": [{"var": "vars._hit"}, None]}, [despawn("{{ vars._hit }}"), call("@score.add", {"n": 10}), setv("vars._hit", None)]),
                call("@collision.first", {"a": "player", "where_prefix": "coin_"}, "vars._hit"),
                iff({"!=": [{"var": "vars._hit"}, None]}, [despawn("{{ vars._hit }}"), call("@score.add", {"n": 50}), setv("vars._hit", None)]),
                call("@for_each_entity", {"where_prefix": "obstacle_", "do": [iff({"<": [{"var": "loop.entity.x"}, -80]}, [despawn("{{ loop.id }}")])]}),
                call("@for_each_entity", {"where_prefix": "gem_", "do": [iff({"<": [{"var": "loop.entity.x"}, -80]}, [despawn("{{ loop.id }}")])]}),
                call("@for_each_entity", {"where_prefix": "coin_", "do": [iff({"<": [{"var": "loop.entity.x"}, -80]}, [despawn("{{ loop.id }}")])]}),
            ])
        ]},
        "on_score_changed": {"type": "call", "call": "@global.scoreChanged", "args": {"score": "{{ event.score }}"}},
        "on_status": {"type": "call", "call": "@global.status", "args": {"text": "{{ event.text }}"}},
        "on_game_over": {"type": "call", "call": "@global.over", "args": {"score": "{{ event.score }}"}},
        "on_reset": {"type": "call", "call": "@global.reset", "args": {}},
    }
    return base_app(
        "demo-bgug-runner",
        "BGUG Runner",
        "1.0.0",
        "JSON-DSL port inspired by bgug (MIT). Tap left to jump and right to dive.",
        deps={"common-ui": "^1.3.0"},
        assets={"bundles": {"bgug": bundle(pack, "MIT", "bgug source assets")}},
        variables={"score": 0, "bestScore": 0, "status": "Ready", "_choice": None},
        functions=score_functions("BGUG Runner"),
        screens=[game_screen("BGUG Runner", "{{ global.status }}", game, bg="#111827")],
    )


def darkness() -> dict[str, Any]:
    pack = "source-darkness-dungeon"
    game = {
        "type": "flame_game",
        "world": {"kind": "pixel", "bg": "#111827"},
        "overlay": {"game_over": False, "asset_loading_text": "Loading dungeon assets..."},
        "camera": {"follow": "player", "offset_x": -210, "offset_y": -320, "deadzone_y": 90, "smooth_y": 0.22},
        "vars": {"move_x": 0, "move_y": 0, "speed": 132, "hp": 200, "stamina": 100, "facing_x": 1, "facing_y": 0, "attack_cd": 0, "hurt_cd": 0, "_hit": None, "_id": 0},
        "entities": {
            "map": {
                "kind": "tiled_map",
                "source": "images/tiled/map.json",
                "base_url": f"{ASSET}/{pack}/1.0/",
                "scale": 2,
                "priority": -10,
                "render": {"shape": "text", "value": "Loading map...", "color": "#FFFFFF"},
            },
            "player": anim(pack, "images/player/knight_idle.png", [64, 96], [42, 42], [16, 16], 6, frames_per_row=6, priority=20, animations={
                "idle": {"asset": asset(pack, "images/player/knight_idle.png"), "frame_size": [16, 16], "frames": 6, "frames_per_row": 6, "step_time": 0.12},
                "run": {"asset": asset(pack, "images/player/knight_run.png"), "frame_size": [16, 16], "frames": 6, "frames_per_row": 6, "step_time": 0.08},
            }, animation="idle"),
            "door": sprite(pack, "images/items/door_closed.png", [128, 438], [54, 54], priority=5),
            "key": sprite(pack, "images/items/key_silver.png", [548, 148], [30, 30], priority=12),
            "potion": sprite(pack, "images/items/potion_red.png", [310, 602], [30, 30], priority=12),
            "torch_1": sprite(pack, "images/items/torch_spritesheet.png", [104, 72], [34, 34], src=[0, 0, 16, 16], priority=8),
            "torch_2": sprite(pack, "images/items/torch_spritesheet.png", [510, 326], [34, 34], src=[0, 0, 16, 16], priority=8),
            "enemy_goblin": anim(pack, "images/enemy/goblin/goblin_idle.png", [430, 164], [38, 38], [16, 16], 6, frames_per_row=6, priority=18, state={"hp": 2}),
            "enemy_imp": anim(pack, "images/enemy/imp/imp_idle.png", [240, 506], [38, 38], [16, 16], 4, frames_per_row=4, priority=18, state={"hp": 2}),
            "enemy_boss": anim(pack, "images/enemy/boss/boss_idle.png", [620, 560], [80, 80], [32, 36], 4, frames_per_row=4, priority=18, state={"hp": 5}),
        },
        "input": {
            "move_axis": [setv("vars.move_x", {"var": "event.x"}), setv("vars.move_y", {"var": "event.y"}), iff({"!=": [{"var": "event.x"}, 0]}, [setv("vars.facing_x", {"var": "event.x"}), setv("vars.facing_y", 0)]), iff({"and": [{"==": [{"var": "event.x"}, 0]}, {"!=": [{"var": "event.y"}, 0]}]}, [setv("vars.facing_y", {"var": "event.y"}), setv("vars.facing_x", 0)])],
            "jump": [iff({"<=": [{"var": "vars.attack_cd"}, 0]}, [setv("vars.attack_cd", 0.28), setv("vars._id", {"call": "@random_int", "args": {"min": 1000, "max": 999999}}), spawn("bolt_{{ vars._id }}", sprite(pack, "images/player/fireball_right.png", [{"var": "entities.player.x"}, {"var": "entities.player.y"}], [28, 18], src=[0, 0, 23, 23], velocity=[{"*": [{"var": "vars.facing_x"}, 300]}, {"*": [{"var": "vars.facing_y"}, 300]}], priority=30))])],
            "attack": [iff({"<=": [{"var": "vars.attack_cd"}, 0]}, [setv("vars.attack_cd", 0.25), spawn("slash", pixel([{"+": [{"var": "entities.player.x"}, {"*": [{"var": "vars.facing_x"}, 30]}]}, {"+": [{"var": "entities.player.y"}, {"*": [{"var": "vars.facing_y"}, 30]}]}], [52, 52], "#FBBF2444", priority=40, shape="circle", state={"ttl": 0.16}))])],
        },
        "frame": {"logic": [
            setv("vars.attack_cd", {"-": [{"var": "vars.attack_cd"}, {"var": "event.dt"}]}),
            setv("vars.hurt_cd", {"-": [{"var": "vars.hurt_cd"}, {"var": "event.dt"}]}),
            e_set("player", "vx", {"*": [{"var": "vars.move_x"}, {"var": "vars.speed"}]}),
            e_set("player", "vy", {"*": [{"var": "vars.move_y"}, {"var": "vars.speed"}]}),
            iff({"or": [{"!=": [{"var": "vars.move_x"}, 0]}, {"!=": [{"var": "vars.move_y"}, 0]}]}, [call("@animated_sprite.set_animation", {"id": "player", "animation": "run"})], [call("@animated_sprite.set_animation", {"id": "player", "animation": "idle"})]),
            e_add("player", "x", 0, min=24, max=740),
            e_add("player", "y", 0, min=24, max=740),
            call("@for_each_entity", {"where_prefix": "enemy_", "do": [
                iff({"<": [{"var": "loop.entity.x"}, {"-": [{"var": "entities.player.x"}, 12]}]}, [e_set("{{ loop.id }}", "vx", 54)], [iff({">": [{"var": "loop.entity.x"}, {"+": [{"var": "entities.player.x"}, 12]}]}, [e_set("{{ loop.id }}", "vx", -54)], [e_set("{{ loop.id }}", "vx", 0)])]),
                iff({"<": [{"var": "loop.entity.y"}, {"-": [{"var": "entities.player.y"}, 12]}]}, [e_set("{{ loop.id }}", "vy", 54)], [iff({">": [{"var": "loop.entity.y"}, {"+": [{"var": "entities.player.y"}, 12]}]}, [e_set("{{ loop.id }}", "vy", -54)], [e_set("{{ loop.id }}", "vy", 0)])]),
                call("@entity.flip_by_velocity", {"id": "{{ loop.id }}", "invert": True}),
            ]}),
            call("@collision.first", {"a": "player", "where_prefix": "key"}, "vars._hit"),
            iff({"!=": [{"var": "vars._hit"}, None]}, [despawn("key"), call("@emit", {"event": "status", "data": {"text": "Silver key found"}}), call("@score.add", {"n": 100})]),
            call("@collision.first", {"a": "player", "where_prefix": "potion"}, "vars._hit"),
            iff({"!=": [{"var": "vars._hit"}, None]}, [despawn("potion"), setv("vars.hp", 200), call("@emit", {"event": "status", "data": {"text": "Life restored"}})]),
            call("@for_each_entity", {"where_prefix": "bolt_", "do": [call("@collision.first", {"a": "{{ loop.id }}", "where_prefix": "enemy_"}, "vars._hit"), iff({"!=": [{"var": "vars._hit"}, None]}, [despawn("{{ loop.id }}"), despawn("{{ vars._hit }}"), call("@score.add", {"n": 150})]), iff({"or": [{"<": [{"var": "loop.entity.x"}, -100]}, {">": [{"var": "loop.entity.x"}, 900]}, {"<": [{"var": "loop.entity.y"}, -100]}, {">": [{"var": "loop.entity.y"}, 900]}]}, [despawn("{{ loop.id }}")])]}),
            iff({"call": "@entity.exists", "args": {"id": "slash"}}, [
                call("@collision.first", {"a": "slash", "where_prefix": "enemy_"}, "vars._hit"),
                iff({"!=": [{"var": "vars._hit"}, None]}, [despawn("{{ vars._hit }}"), call("@score.add", {"n": 120})]),
                e_add("slash", "state.ttl", {"-": [0, {"var": "event.dt"}]}),
                iff({"<=": [{"var": "entities.slash.state.ttl"}, 0]}, [despawn("slash")]),
            ]),
            call("@collision.first", {"a": "player", "where_prefix": "enemy_"}, "vars._hit"),
            iff({"and": [{"!=": [{"var": "vars._hit"}, None]}, {"<=": [{"var": "vars.hurt_cd"}, 0]}]}, [setv("vars.hurt_cd", 0.8), setv("vars.hp", {"-": [{"var": "vars.hp"}, 20]}), call("@emit", {"event": "status", "data": {"text": "HP {{ vars.hp }}"}})]),
            iff({"<=": [{"var": "vars.hp"}, 0]}, [call("@game_over")]),
            iff({"and": [{"!": {"call": "@entity.exists", "args": {"id": "enemy_goblin"}}}, {"!": {"call": "@entity.exists", "args": {"id": "enemy_imp"}}}, {"!": {"call": "@entity.exists", "args": {"id": "enemy_boss"}}}]}, [call("@score.add", {"n": 500}), call("@game_over")]),
        ]},
        "on_score_changed": {"type": "call", "call": "@global.scoreChanged", "args": {"score": "{{ event.score }}"}},
        "on_status": {"type": "call", "call": "@global.status", "args": {"text": "{{ event.text }}"}},
        "on_game_over": {"type": "call", "call": "@global.over", "args": {"score": "{{ event.score }}"}},
        "on_reset": {"type": "call", "call": "@global.reset", "args": {}},
    }
    return base_app(
        "demo-darkness-dungeon",
        "Darkness Dungeon",
        "1.0.0",
        "JSON-DSL dungeon action port inspired by Darkness Dungeon (MIT).",
        deps={"common-ui": "^1.3.0", "game-controls": "^1.0.8"},
        assets={"bundles": {"darkness": bundle(pack, "MIT", "Darkness Dungeon source assets")}},
        variables={"score": 0, "bestScore": 0, "status": "Joystick to move. Triangle shoots, circle slashes.", "_choice": None, "_gamepadStyle": "default", "_gamepadEditing": False, "_gamepadReset": 0},
        functions=score_functions("Darkness Dungeon"),
        screens=[game_screen("Darkness Dungeon", "{{ global.status }}", game, controls=gamepad("move_axis", "jump", "attack", bg="#111827"), bg="#111827")],
    )


def new_super_jumper() -> dict[str, Any]:
    pack = "source-new-super-jumper"
    game = {
        "type": "flame_game",
        "world": {"kind": "pixel", "bg": "#9DD7F3"},
        "overlay": {"game_over": False, "asset_loading_text": "Loading jumper assets..."},
        "vars": {"move_x": 0, "gravity": 980, "jump_v": -650, "speed": 220, "shoot_cd": 0, "scroll": 0, "_hit": None, "_id": 0},
        "entities": {
            "bg": sprite(pack, "ui/background.png", [0, 0], [{"var": "world.width"}, {"var": "world.height"}], priority=-20),
            "hero": sprite(pack, "ui/heroJump.png", [190, 460], [56, 62], priority=20),
            "floor": sprite(pack, "ui/LandPiece_DarkBlue.png", [130, 650], [180, 78], priority=5),
        },
        "init": {"logic": [
            *[
                spawn(f"platform_{i}", sprite(pack, "ui/LandPiece_DarkMulticolored.png", [x, y], [126, 58], priority=4))
                for i, (x, y) in enumerate([(18, 560), (210, 485), (92, 400), (252, 330), (34, 250), (198, 176), (80, 90), (260, 12)])
            ],
            spawn("coin_1", pixel([300, 250], [26, 26], "#FACC15", priority=12, shape="circle")),
            spawn("enemy_1", sprite(pack, "ui/HappyCloud.png", [45, 145], [74, 40], velocity=[60, 0], priority=14, state={"minX": 20, "maxX": 330})),
            call("@emit", {"event": "status", "data": {"text": "Climb, wrap around, tap attack to shoot"}}),
        ]},
        "input": {
            "move_axis": [setv("vars.move_x", {"var": "event.x"})],
            "jump": [e_set("hero", "vy", {"var": "vars.jump_v"})],
            "attack": [iff({"<=": [{"var": "vars.shoot_cd"}, 0]}, [setv("vars.shoot_cd", 0.22), setv("vars._id", {"call": "@random_int", "args": {"min": 1000, "max": 999999}}), spawn("bullet_{{ vars._id }}", pixel([{"+": [{"var": "entities.hero.x"}, 24]}, {"var": "entities.hero.y"}], [8, 18], "#111827", velocity=[0, -520], priority=30, shape="circle"))])],
        },
        "frame": {"logic": [
            e_set("hero", "vx", {"*": [{"var": "vars.move_x"}, {"var": "vars.speed"}]}),
            call("@pixel.add_velocity", {"id": "hero", "dv": [0, {"*": [{"var": "vars.gravity"}, {"var": "event.dt"}]}]}),
            setv("vars.shoot_cd", {"-": [{"var": "vars.shoot_cd"}, {"var": "event.dt"}]}),
            iff({">": [{"var": "entities.hero.x"}, {"var": "world.width"}]}, [e_set("hero", "x", -56)]),
            iff({"<": [{"var": "entities.hero.x"}, -60]}, [e_set("hero", "x", {"var": "world.width"})]),
            call("@collision.first", {"a": "hero", "where_prefix": "platform_"}, "vars._hit"),
            iff({"and": [{"!=": [{"var": "vars._hit"}, None]}, {">": [{"var": "entities.hero.vy"}, 0]}]}, [e_set("hero", "vy", {"var": "vars.jump_v"}), call("@score.add", {"n": 10}), setv("vars._hit", None)]),
            iff({"and": [{"call": "@collide.rect", "args": {"a": "hero", "b": "floor"}}, {">": [{"var": "entities.hero.vy"}, 0]}]}, [e_set("hero", "vy", {"var": "vars.jump_v"})]),
            iff({"<": [{"var": "entities.hero.y"}, 220]}, [
                setv("vars.scroll", {"-": [220, {"var": "entities.hero.y"}]}),
                e_set("hero", "y", 220),
                call("@for_each_entity", {"where_prefix": "platform_", "do": [e_add("{{ loop.id }}", "y", {"var": "vars.scroll"})]}),
                call("@for_each_entity", {"where_prefix": "coin_", "do": [e_add("{{ loop.id }}", "y", {"var": "vars.scroll"})]}),
                call("@for_each_entity", {"where_prefix": "enemy_", "do": [e_add("{{ loop.id }}", "y", {"var": "vars.scroll"})]}),
            ]),
            call("@for_each_entity", {"where_prefix": "platform_", "do": [iff({">": [{"var": "loop.entity.y"}, {"+": [{"var": "world.height"}, 80]}]}, [e_set("{{ loop.id }}", "y", {"call": "@random_int", "args": {"min": -160, "max": -40}}), e_set("{{ loop.id }}", "x", {"call": "@random_int", "args": {"min": 18, "max": 300}})])]}),
            call("@for_each_entity", {"where_prefix": "enemy_", "do": [iff({"<": [{"var": "loop.entity.x"}, {"var": "loop.entity.state.minX"}]}, [e_set("{{ loop.id }}", "vx", 70)]), iff({">": [{"var": "loop.entity.x"}, {"var": "loop.entity.state.maxX"}]}, [e_set("{{ loop.id }}", "vx", -70)])]}),
            call("@collision.first", {"a": "hero", "where_prefix": "coin_"}, "vars._hit"),
            iff({"!=": [{"var": "vars._hit"}, None]}, [despawn("{{ vars._hit }}"), call("@score.add", {"n": 25}), setv("vars._hit", None)]),
            call("@collision.first", {"a": "hero", "where_prefix": "enemy_"}, "vars._hit"),
            iff({"!=": [{"var": "vars._hit"}, None]}, [call("@game_over")]),
            call("@for_each_entity", {"where_prefix": "bullet_", "do": [call("@collision.first", {"a": "{{ loop.id }}", "where_prefix": "enemy_"}, "vars._hit"), iff({"!=": [{"var": "vars._hit"}, None]}, [despawn("{{ loop.id }}"), despawn("{{ vars._hit }}"), call("@score.add", {"n": 100})]), iff({"<": [{"var": "loop.entity.y"}, -50]}, [despawn("{{ loop.id }}")])]}),
            iff({">": [{"var": "entities.hero.y"}, {"+": [{"var": "world.height"}, 80]}]}, [call("@game_over")]),
        ]},
        "on_score_changed": {"type": "call", "call": "@global.scoreChanged", "args": {"score": "{{ event.score }}"}},
        "on_status": {"type": "call", "call": "@global.status", "args": {"text": "{{ event.text }}"}},
        "on_game_over": {"type": "call", "call": "@global.over", "args": {"score": "{{ event.score }}"}},
        "on_reset": {"type": "call", "call": "@global.reset", "args": {}},
    }
    return base_app(
        "demo-new-super-jumper",
        "New Super Jumper",
        "1.0.0",
        "JSON-DSL vertical jumper inspired by new_super_jumper from flutter_games_compilation.",
        deps={"common-ui": "^1.3.0", "game-controls": "^1.0.8"},
        assets={"bundles": {"new_super_jumper": bundle(pack, "Repository license not specified", "new_super_jumper source assets")}},
        variables={"score": 0, "bestScore": 0, "status": "Ready", "_choice": None, "_gamepadStyle": "default", "_gamepadEditing": False, "_gamepadReset": 0},
        functions=score_functions("New Super Jumper"),
        screens=[game_screen("New Super Jumper", "{{ global.status }}", game, controls=gamepad("move_axis", "jump", "attack", bg="#0EA5E9"), bg="#0EA5E9")],
    )


def rps() -> dict[str, Any]:
    funcs = {
        "pick": {
            "params": ["choice"],
            "logic": [
                {"call": "@set", "args": {"var": "global.player", "value": "{{ params.choice }}"}},
                {"call": "@random_pick", "args": {"list": ["rock", "paper", "scissors"]}, "assign": "global.bot"},
                {"call": "@set", "args": {"var": "global.round", "value": {"+": [{"var": "global.round"}, 1]}}},
                {"call": "@if", "args": {"condition": {"==": [{"var": "global.player"}, {"var": "global.bot"}]}, "then": [
                    {"call": "@set", "args": {"var": "global.result", "value": "Draw"}},
                ], "else": [
                    {"call": "@if", "args": {"condition": {"or": [
                        {"and": [{"==": [{"var": "global.player"}, "rock"]}, {"==": [{"var": "global.bot"}, "scissors"]}]},
                        {"and": [{"==": [{"var": "global.player"}, "paper"]}, {"==": [{"var": "global.bot"}, "rock"]}]},
                        {"and": [{"==": [{"var": "global.player"}, "scissors"]}, {"==": [{"var": "global.bot"}, "paper"]}]},
                    ]}, "then": [
                        {"call": "@set", "args": {"var": "global.result", "value": "Win"}},
                        {"call": "@set", "args": {"var": "global.score", "value": {"+": [{"var": "global.score"}, 1]}}},
                    ], "else": [
                        {"call": "@set", "args": {"var": "global.result", "value": "Lose"}},
                        {"call": "@set", "args": {"var": "global.botScore", "value": {"+": [{"var": "global.botScore"}, 1]}}},
                    ]}},
                ]}},
                {"call": "@list_add", "args": {"var": "global.history", "item": "{{ global.round }}. {{ global.player }} vs {{ global.bot }} - {{ global.result }}"}},
            ],
        },
        "reset": {"logic": [
            {"call": "@set", "args": {"var": "global.round", "value": 0}},
            {"call": "@set", "args": {"var": "global.score", "value": 0}},
            {"call": "@set", "args": {"var": "global.botScore", "value": 0}},
            {"call": "@set", "args": {"var": "global.player", "value": "-"}},
            {"call": "@set", "args": {"var": "global.bot", "value": "-"}},
            {"call": "@set", "args": {"var": "global.result", "value": "Choose"}},
            {"call": "@list_clear", "args": {"var": "global.history"}},
        ]},
    }
    button_style = {"fontSize": 15, "paddingH": 14, "paddingV": 12, "borderRadius": 18, "backgroundColor": "#312E81", "textColor": "#FFFFFF"}
    screen = {
        "id": "home",
        "title": "Guidi Tu RPS",
        "appBar": {"title": "Guidi Tu RPS", "centerTitle": True, "backgroundColor": "#111827", "color": "#FFFFFF", "actions": [{"icon": "replay", "action": {"call": "@global.reset", "args": {}}}]},
        "layout": "column",
        "padding": 16,
        "children": [
            {"type": "container", "padding": 18, "borderRadius": 18, "color": "#EEF2FF", "layout": "column", "children": [
                {"type": "text", "value": "Round {{ global.round }}", "style": {"fontSize": 18, "fontWeight": "bold", "color": "#111827"}},
                {"type": "text", "value": "You {{ global.score }} : {{ global.botScore }} Bot", "style": {"fontSize": 16, "color": "#374151"}},
                {"type": "text", "value": "{{ global.player }} vs {{ global.bot }} -> {{ global.result }}", "style": {"fontSize": 16, "fontWeight": "bold", "color": "#4F46E5"}},
            ]},
            {"type": "container", "padding": 12, "layout": "row", "mainAxisAlignment": "spaceEvenly", "children": [
                {"type": "button", "label": "Rock", "style": button_style, "action": {"call": "@global.pick", "args": {"choice": "rock"}}},
                {"type": "button", "label": "Paper", "style": button_style, "action": {"call": "@global.pick", "args": {"choice": "paper"}}},
                {"type": "button", "label": "Scissors", "style": button_style, "action": {"call": "@global.pick", "args": {"choice": "scissors"}}},
            ]},
            {"type": "expanded", "child": {"type": "list", "source": "{{ global.history }}", "emptyText": "Pick a gesture to start.", "item_template": {"type": "container", "padding": 10, "borderRadius": 10, "color": "#F9FAFB", "child": {"type": "text", "value": "{{ loop.item }}", "style": {"fontSize": 13, "color": "#111827"}}}}},
        ],
    }
    return base_app(
        "demo-guidi-tu-rps",
        "Guidi Tu RPS",
        "1.0.0",
        "JSON-DSL party mini-game inspired by Guidi Tu Rock Paper Scissors. Source license: CC BY-NC-SA 4.0.",
        variables={"round": 0, "score": 0, "botScore": 0, "player": "-", "bot": "-", "result": "Choose", "history": []},
        functions=funcs,
        screens=[screen],
    )


def boules() -> dict[str, Any]:
    game = {
        "type": "flame_game",
        "world": {"kind": "pixel", "bg": "#14532D"},
        "overlay": {"score": False, "game_over": False},
        "vars": {"state": "aim", "friction": 0.986, "best": 9999, "stopped": False},
        "entities": {
            "target": pixel([210, 118], [20, 20], "#FDE68A", priority=5, shape="circle"),
            "bowl": pixel([202, 610], [34, 34], "#60A5FA", priority=10, shape="circle"),
            "aim": pixel([196, 350], [46, 46], "#FFFFFF33", priority=3, shape="circle"),
        },
        "input": {
            "tap": [
                iff({"==": [{"var": "vars.state"}, "aim"]}, [
                    e_set("aim", "x", {"-": [{"var": "event.x"}, 23]}),
                    e_set("aim", "y", {"-": [{"var": "event.y"}, 23]}),
                    e_set("bowl", "vx", {"*": [{"-": [{"var": "event.x"}, {"var": "entities.bowl.x"}]}, 1.7]}),
                    e_set("bowl", "vy", {"*": [{"-": [{"var": "event.y"}, {"var": "entities.bowl.y"}]}, 1.7]}),
                    setv("vars.state", "rolling"),
                    call("@emit", {"event": "status", "data": {"text": "Rolling"}}),
                ])
            ]
        },
        "frame": {"logic": [
            iff({"==": [{"var": "vars.state"}, "rolling"]}, [
                e_set("bowl", "vx", {"*": [{"var": "entities.bowl.vx"}, {"var": "vars.friction"}]}),
                e_set("bowl", "vy", {"*": [{"var": "entities.bowl.vy"}, {"var": "vars.friction"}]}),
                iff({"<": [{"var": "entities.bowl.x"}, 6]}, [e_set("bowl", "x", 6), e_set("bowl", "vx", {"*": [{"var": "entities.bowl.vx"}, -0.72]})]),
                iff({">": [{"+": [{"var": "entities.bowl.x"}, {"var": "entities.bowl.w"}]}, {"var": "world.width"}]}, [e_set("bowl", "x", {"-": [{"var": "world.width"}, {"var": "entities.bowl.w"}]}), e_set("bowl", "vx", {"*": [{"var": "entities.bowl.vx"}, -0.72]})]),
                iff({"<": [{"var": "entities.bowl.y"}, 6]}, [e_set("bowl", "y", 6), e_set("bowl", "vy", {"*": [{"var": "entities.bowl.vy"}, -0.72]})]),
                iff({">": [{"+": [{"var": "entities.bowl.y"}, {"var": "entities.bowl.h"}]}, {"var": "world.height"}]}, [e_set("bowl", "y", {"-": [{"var": "world.height"}, {"var": "entities.bowl.h"}]}), e_set("bowl", "vy", {"*": [{"var": "entities.bowl.vy"}, -0.72]})]),
                iff({"and": [
                    {">": [{"var": "entities.bowl.vx"}, -5]},
                    {"<": [{"var": "entities.bowl.vx"}, 5]},
                    {">": [{"var": "entities.bowl.vy"}, -5]},
                    {"<": [{"var": "entities.bowl.vy"}, 5]},
                ]}, [
                    e_set("bowl", "vx", 0),
                    e_set("bowl", "vy", 0),
                    setv("vars.state", "done"),
                    call("@emit", {"event": "status", "data": {"text": "Stopped. Tap restart for another throw."}}),
                    call("@game_over"),
                ]),
            ])
        ]},
        "on_status": {"type": "call", "call": "@global.status", "args": {"text": "{{ event.text }}"}},
        "on_game_over": {"type": "call", "call": "@global.over", "args": {"score": "{{ event.score }}"}},
        "on_reset": {"type": "call", "call": "@global.reset", "args": {}},
    }
    return base_app(
        "demo-guidi-tu-boules",
        "Guidi Tu Boules",
        "1.0.0",
        "JSON-DSL boules mini-game inspired by Guidi Tu. Source license: CC BY-NC-SA 4.0.",
        variables={"score": 0, "bestScore": 0, "status": "Tap the field to throw toward the jack.", "_choice": None},
        functions=score_functions("Guidi Tu Boules"),
        screens=[game_screen("Guidi Tu Boules", "{{ global.status }}", game, bg="#14532D")],
    )


def main() -> None:
    apps = {
        "demo_bgug_runner.json": bgug(),
        "demo_darkness_dungeon.json": darkness(),
        "demo_new_super_jumper.json": new_super_jumper(),
        "demo_guidi_tu_rps.json": rps(),
        "demo_guidi_tu_boules.json": boules(),
    }
    for filename, app in apps.items():
        save(app, filename)
        print(filename)


if __name__ == "__main__":
    main()
