#!/usr/bin/env python3
"""Generate JSON-only ports for the current source-game batch.

The generated apps intentionally keep game rules in JSON. Framework changes
needed by these apps must remain generic atoms, not per-game Dart bridges.
"""

from __future__ import annotations

import json
import uuid
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
TEMPLATES = ROOT / "templates"
ASSET_ROOT = "https://myapp-oss-endpoint.dapangyu.work/json-app-assets/asset-packs"
PACK_VERSION = "1.1"
APP_VERSION = "1.1.0"


def uid(name: str) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"myapp-json-source-port:{name}"))


def asset(pack: str, path: str) -> str:
    return f"{ASSET_ROOT}/{pack}/{PACK_VERSION}/{path}"


def call(name: str, args: dict[str, Any] | None = None, assign: str | None = None) -> dict[str, Any]:
    step: dict[str, Any] = {"call": name, "args": args or {}}
    if assign:
        step["assign"] = assign
    return step


def setv(var: str, value: Any) -> dict[str, Any]:
    return call("@set", {"var": var, "value": value})


def gif(condition: Any, then: list[Any], otherwise: list[Any] | None = None) -> dict[str, Any]:
    args: dict[str, Any] = {"cond": condition, "then": then}
    if otherwise is not None:
        args["else"] = otherwise
    return call("@if", args)


def uif(condition: Any, then: list[Any], otherwise: list[Any] | None = None) -> dict[str, Any]:
    args: dict[str, Any] = {"condition": condition, "then": then}
    if otherwise is not None:
        args["else"] = otherwise
    return call("@if", args)


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


def pixel(
    position: list[Any],
    size: list[Any],
    color: str,
    *,
    velocity: list[Any] | None = None,
    priority: int = 0,
    shape: str = "rect",
    state: dict[str, Any] | None = None,
) -> dict[str, Any]:
    spec: dict[str, Any] = {
        "kind": "pixel",
        "position": position,
        "size": size,
        "velocity": velocity or [0, 0],
        "priority": priority,
        "render": {"shape": shape, "color": color},
    }
    if state:
        spec["state"] = state
    return spec


def sprite(
    pack: str,
    path: str,
    position: list[Any],
    size: list[Any],
    *,
    src: list[Any] | None = None,
    velocity: list[Any] | None = None,
    priority: int = 0,
    state: dict[str, Any] | None = None,
    fixed: bool = False,
) -> dict[str, Any]:
    spec: dict[str, Any] = {
        "kind": "sprite",
        "asset": asset(pack, path),
        "position": position,
        "size": size,
        "velocity": velocity or [0, 0],
        "priority": priority,
    }
    if src:
        spec["src"] = src
    if state:
        spec["state"] = state
    if fixed:
        spec["fixed_to_screen"] = True
    return spec


def anim(
    pack: str,
    path: str,
    position: list[Any],
    size: list[Any],
    frame_size: list[int],
    frames: int,
    *,
    frames_per_row: int | None = None,
    velocity: list[Any] | None = None,
    priority: int = 0,
    state: dict[str, Any] | None = None,
    step_time: float = 0.1,
    animations: dict[str, Any] | None = None,
    animation: str | None = None,
) -> dict[str, Any]:
    spec = sprite(pack, path, position, size, velocity=velocity, priority=priority, state=state)
    spec.update({"kind": "animated_sprite", "frame_size": frame_size, "frames": frames, "step_time": step_time})
    if frames_per_row:
        spec["frames_per_row"] = frames_per_row
    if animations:
        spec["animations"] = animations
    if animation:
        spec["animation"] = animation
    return spec


def bundle(pack: str, license_name: str, description: str) -> dict[str, Any]:
    return {
        "baseUrl": f"{ASSET_ROOT}/{pack}/{PACK_VERSION}/",
        "manifest": "manifest.json",
        "license": license_name,
        "startupDownload": True,
        "description": description,
    }


def app(
    name: str,
    title: str,
    description: str,
    *,
    deps: dict[str, str] | None = None,
    assets: dict[str, Any] | None = None,
    variables: dict[str, Any] | None = None,
    functions: dict[str, Any] | None = None,
    screens: list[dict[str, Any]],
) -> dict[str, Any]:
    out: dict[str, Any] = {
        "dsl": "3.3",
        "appid": uid(name),
        "meta": {
            "name": name,
            "displayName": title,
            "version": APP_VERSION,
            "type": "app",
            "description": description,
            "author": "fish",
        },
        "dependencies": deps or {"common-ui": "^1.3.0"},
        "global": {"variables": variables or {}, "functions": functions or {}},
        "ui": {"screens": screens},
    }
    if assets:
        out["assets"] = assets
    return out


def score_functions(title: str) -> dict[str, Any]:
    return {
        "scoreChanged": {
            "params": ["score", "best"],
            "logic": [
                setv("global.score", "{{ params.score }}"),
                setv("global.bestScore", "{{ params.best }}"),
            ],
        },
        "status": {"params": ["text"], "logic": [setv("global.status", "{{ params.text }}")]},
        "over": {
            "params": ["score", "best"],
            "logic": [
                setv("global.score", "{{ params.score }}"),
                setv("global.bestScore", "{{ params.best }}"),
                setv("global.status", f"{title} finished"),
                call(
                    "@common-ui.choose",
                    {
                        "title": f"{title} finished",
                        "message": "Score: {{ params.score }}\nBest: {{ params.best }}",
                        "buttons": [
                            {"label": "Close", "value": "close", "style": "text"},
                            {"label": "Restart", "value": "restart"},
                        ],
                    },
                    "global._choice",
                ),
                uif({"==": [{"var": "global._choice"}, "restart"]}, [call("@flame_game_reset", {})]),
            ],
        },
        "reset": {
            "logic": [
                setv("global.score", 0),
                setv("global.status", "Ready"),
            ],
        },
    }


def gamepad(move: str, jump: str, attack: str, *, height: int = 160, bg: str = "#111827") -> dict[str, Any]:
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


def indexed_branch(index_var: str, count: int, make_steps) -> list[dict[str, Any]]:
    """Return nested @if steps for index-based choices.

    The JSON runtime intentionally does not support nested template paths such
    as `assets.{{ vars.i }}`. Keeping this as explicit branches makes generated
    templates boring but deterministic.
    """

    if count <= 0:
        return []
    branch = make_steps(count - 1)
    for i in range(count - 2, -1, -1):
        branch = [gif({"==": [{"var": index_var}, i]}, make_steps(i), branch)]
    return branch


def game_screen(
    title: str,
    subtitle: str,
    flame_game: dict[str, Any],
    *,
    controls: dict[str, Any] | None = None,
    bg: str = "#111827",
) -> dict[str, Any]:
    children: list[dict[str, Any]] = [
        {
            "type": "container",
            "padding": 8,
            "color": bg,
            "layout": "row",
            "crossAxisAlignment": "center",
            "children": [
                {"type": "text", "value": subtitle, "style": {"fontSize": 13, "color": "#E5E7EB"}, "position": {"type": "flex", "flex": 1}},
                {"type": "text", "value": "Score {{ global.score }}", "style": {"fontSize": 13, "fontWeight": "bold", "color": "#FFFFFF"}},
            ],
        },
        {"type": "expanded", "child": flame_game},
    ]
    if controls:
        children.append(controls)
    return {
        "id": "home",
        "title": title,
        "appBar": {"title": title, "centerTitle": True, "backgroundColor": bg, "color": "#FFFFFF", "actions": [{"icon": "replay", "action": {"call": "@flame_game_reset", "args": {}}}]},
        "layout": "column",
        "padding": 0,
        "children": children,
    }


def bgug() -> dict[str, Any]:
    pack = "source-bgug"
    sector_logic = [
        setv("vars._sector", {"+": [{"var": "vars._sector"}, 1]}),
        setv("vars._sector_x", {"*": [{"var": "vars._sector"}, 1000]}),
        setv("vars._id", {"call": "@random_int", "args": {"min": 1000, "max": 999999}}),
        gif(
            {"==": [{"var": "vars._sector"}, 0]},
            [
                spawn(
                    "gem_{{ vars._id }}",
                    sprite(pack, "images/gem.png", [{"var": "vars._sector_x"}, {"-": [{"var": "vars.floor_y"}, 86]}], [32, 32], priority=14),
                )
            ],
            [
                setv("vars._count", {"call": "@random_int", "args": {"min": 1, "max": 5}}),
                call(
                    "@loop_by_num",
                    {
                        "count": "{{ vars._count }}",
                        "body": [
                            setv("vars._id", {"call": "@random_int", "args": {"min": 1000, "max": 999999}}),
                            setv("vars._x", {"+": [{"var": "vars._sector_x"}, {"call": "@random_int", "args": {"min": 32, "max": 930}}]}),
                            gif(
                                {"call": "@random_int", "args": {"min": 0, "max": 2}},
                                [
                                    spawn("obstacle_{{ vars._id }}", anim(pack, "images/obstacle.png", ["{{ vars._x }}", {"-": [{"var": "vars.floor_y"}, 48]}], [48, 48], [16, 16], 3, frames_per_row=3, velocity=[0, 0], priority=10))
                                ],
                                [
                                    spawn("obstacle_{{ vars._id }}", anim(pack, "images/up_obstacle.png", ["{{ vars._x }}", {"var": "vars.top_y"}], [48, 48], [16, 16], 3, frames_per_row=3, velocity=[0, 0], priority=10))
                                ],
                            ),
                        ],
                    },
                ),
                setv("vars._count", {"call": "@random_int", "args": {"min": 0, "max": 6}}),
                call(
                    "@loop_by_num",
                    {
                        "count": "{{ vars._count }}",
                        "body": [
                            setv("vars._id", {"call": "@random_int", "args": {"min": 1000, "max": 999999}}),
                            spawn(
                                "gem_{{ vars._id }}",
                                sprite(
                                    pack,
                                    "images/gem.png",
                                    [
                                        {"+": [{"var": "vars._sector_x"}, {"call": "@random_int", "args": {"min": 50, "max": 900}}]},
                                        {"-": [{"var": "vars.floor_y"}, {"*": [{"call": "@random_int", "args": {"min": 1, "max": 9}}, 42]}]},
                                    ],
                                    [32, 32],
                                    priority=14,
                                ),
                            ),
                        ],
                    },
                ),
                gif(
                    {"<": [{"call": "@random_double", "args": {"min": 0, "max": 1}}, 0.42]},
                    [
                        setv("vars._id", {"call": "@random_int", "args": {"min": 1000, "max": 999999}}),
                        spawn(
                            "coin_{{ vars._id }}",
                            anim(
                                pack,
                                "images/coin.png",
                                [
                                    {"+": [{"var": "vars._sector_x"}, {"call": "@random_int", "args": {"min": 80, "max": 850}}]},
                                    {"-": [{"var": "vars.floor_y"}, {"*": [{"call": "@random_int", "args": {"min": 2, "max": 8}}, 42]}]},
                                ],
                                [34, 34],
                                [16, 16],
                                10,
                                frames_per_row=10,
                                priority=14,
                                step_time=0.05,
                            ),
                        ),
                    ],
                ),
            ],
        ),
    ]

    game = {
        "type": "flame_game",
        "viewport": {"width": 900, "height": 540, "fit": "contain"},
        "world": {"kind": "pixel", "bg": "#111827"},
        "overlay": {"score": False, "game_over": False, "asset_loading_text": "Loading BGUG assets..."},
        "camera": {"follow": "player", "offset_x": -250, "offset_y": 0},
        "audio": {"sounds": {"jump": asset(pack, "audio/jump.wav"), "gem": asset(pack, "audio/gem_collect.wav"), "death": asset(pack, "audio/death.wav"), "block": asset(pack, "audio/block.wav"), "laser": asset(pack, "audio/laser_shoot.wav")}},
        "vars": {
            "state": "tutorial",
            "floor_y": 450,
            "top_y": 88,
            "gravity": 1875,
            "jumpImpulse": -7000,
            "jumpMul": 0.0004,
            "diveImpulse": 20000,
            "maxHold": 500,
            "gems": 0,
            "coins": 0,
            "_sector": -1,
            "_sector_x": 0,
            "_id": 0,
            "_count": 0,
            "_hit": None,
            "_x": 0,
            "block_cd": 0,
            "shot_cd": 0,
        },
        "entities": {
            "bg": {"kind": "parallax", "asset": asset(pack, "images/bg.png"), "speed_x": 45, "priority": -20},
            "hud": sprite(pack, "images/hud_bg.png", [230, 6], [440, 64], priority=50, fixed=True),
            "floor": pixel([-1000, 450], [200000, 90], "#374151", priority=-5),
            "top": pixel([-1000, 64], [200000, 30], "#374151", priority=-5),
            "player": anim(pack, "images/skins/wizard.png", [130, 408], [42, 58], [16, 22], 8, frames_per_row=11, priority=20, step_time=0.0375, velocity=[320, 0], state={"assetLoadingOverlay": True, "dead": False}),
            "shooter_up": sprite(pack, "images/shooter.png", [820, 126], [50, 72], src=[0, 0, 32, 46], priority=50, fixed=True),
            "shooter_down": sprite(pack, "images/shooter.png", [820, 350], [50, 72], src=[0, 0, 32, 46], priority=50, fixed=True),
            "button": sprite(pack, "images/button.png", [760, 454], [116, 54], src=[0, 0, 136, 68], priority=52, fixed=True),
        },
        "init": {"logic": sector_logic + [call("@emit", {"event": "status", "data": {"text": "Tutorial: hold left side, release to jump. Tap right side to dive."}})]},
        "input": {
            "tap": [
                gif({"==": [{"var": "vars.state"}, "tutorial"]}, [setv("vars.state", "running"), call("@emit", {"event": "status", "data": {"text": "Running"}})]),
            ],
            "press_end": [
                gif(
                    {"!=": [{"var": "vars.state"}, "running"]},
                    [],
                    [
                        gif(
                            {"<": [{"var": "event.x"}, 450]},
                            [
                                gif(
                                    {"==": [{"var": "entities.player.y"}, {"-": [{"var": "vars.floor_y"}, {"var": "entities.player.h"}]}]},
                                    [
                                        e_set("player", "vy", {"*": [{"var": "vars.jumpImpulse"}, {"*": [{"min": [{"var": "event.held_ms"}, {"var": "vars.maxHold"}]}, {"var": "vars.jumpMul"}]}]}),
                                        call("@audio.play", {"id": "jump", "volume": 0.6}),
                                    ],
                                )
                            ],
                            [gif({"<": [{"var": "entities.player.y"}, {"-": [{"var": "vars.floor_y"}, {"var": "entities.player.h"}]}]}, [e_set("player", "vy", 760)])],
                        )
                    ],
                )
            ],
        },
        "tick": [
            {"interval": 0.18, "logic": [gif({"==": [{"var": "vars.state"}, "running"]}, [call("@score.add", {"n": 1})])]},
            {
                "interval": 1.0,
                "logic": [
                    gif(
                        {"==": [{"var": "vars.state"}, "running"]},
                        [
                            setv("vars.shot_cd", {"-": [{"var": "vars.shot_cd"}, 1]}),
                            gif(
                                {"<=": [{"var": "vars.shot_cd"}, 0]},
                                [
                                    setv("vars.shot_cd", 2),
                                    setv("vars._id", {"call": "@random_int", "args": {"min": 1000, "max": 999999}}),
                                    spawn("bullet_{{ vars._id }}", anim(pack, "images/bullet.png", [{"+": [{"var": "entities.player.x"}, 760]}, 160], [30, 30], [16, 16], 3, frames_per_row=3, velocity=[-500, 0], priority=15)),
                                    setv("vars._id", {"call": "@random_int", "args": {"min": 1000, "max": 999999}}),
                                    spawn("bullet_{{ vars._id }}", anim(pack, "images/bullet.png", [{"+": [{"var": "entities.player.x"}, 760]}, 380], [30, 30], [16, 16], 3, frames_per_row=3, velocity=[-500, 0], priority=15)),
                                    call("@audio.play", {"id": "laser", "volume": 0.5}),
                                ],
                            ),
                        ],
                    )
                ],
            },
        ],
        "frame": {
            "logic": [
                gif({"!=": [{"var": "vars.state"}, "running"]}, [], [
                    call("@pixel.add_velocity", {"id": "player", "dv": [0, {"*": [{"var": "vars.gravity"}, {"var": "event.dt"}]}]}),
                    gif({">": [{"var": "entities.player.y"}, {"-": [{"var": "vars.floor_y"}, {"var": "entities.player.h"}]}]}, [e_set("player", "y", {"-": [{"var": "vars.floor_y"}, {"var": "entities.player.h"}]}), e_set("player", "vy", 0)]),
                    gif({"<": [{"var": "entities.player.y"}, {"var": "vars.top_y"}]}, [e_set("player", "y", {"var": "vars.top_y"}), e_set("player", "vy", 0)]),
                    call("@while", {"cond": {"<": [{"*": [{"+": [{"var": "vars._sector"}, 1]}, 1000]}, {"+": [{"var": "entities.player.x"}, 1000]}]}, "body": sector_logic, "max_iterations": 4}),
                    call("@collision.first", {"a": "player", "where_prefix": "obstacle_"}, "vars._hit"),
                    gif({"!=": [{"var": "vars._hit"}, None]}, [setv("vars.state", "dead"), call("@audio.play", {"id": "death"}), call("@game_over")]),
                    call("@collision.first", {"a": "player", "where_prefix": "bullet_"}, "vars._hit"),
                    gif({"!=": [{"var": "vars._hit"}, None]}, [setv("vars.state", "dead"), call("@audio.play", {"id": "death"}), call("@game_over")]),
                    call("@collision.first", {"a": "player", "where_prefix": "gem_"}, "vars._hit"),
                    gif({"!=": [{"var": "vars._hit"}, None]}, [despawn("{{ vars._hit }}"), setv("vars.gems", {"+": [{"var": "vars.gems"}, 1]}), call("@score.add", {"n": 20}), call("@audio.play", {"id": "gem", "volume": 0.7}), setv("vars._hit", None)]),
                    call("@collision.first", {"a": "player", "where_prefix": "coin_"}, "vars._hit"),
                    gif({"!=": [{"var": "vars._hit"}, None]}, [despawn("{{ vars._hit }}"), setv("vars.coins", {"+": [{"var": "vars.coins"}, 1]}), call("@score.add", {"n": 50}), call("@audio.play", {"id": "gem", "volume": 0.7}), setv("vars._hit", None)]),
                    call("@for_each_entity", {"where_prefix": "obstacle_", "do": [gif({"<": [{"var": "loop.entity.x"}, {"-": [{"var": "entities.player.x"}, 600]}]}, [despawn("{{ loop.id }}")])]}),
                    call("@for_each_entity", {"where_prefix": "gem_", "do": [gif({"<": [{"var": "loop.entity.x"}, {"-": [{"var": "entities.player.x"}, 600]}]}, [despawn("{{ loop.id }}")])]}),
                    call("@for_each_entity", {"where_prefix": "coin_", "do": [gif({"<": [{"var": "loop.entity.x"}, {"-": [{"var": "entities.player.x"}, 600]}]}, [despawn("{{ loop.id }}")])]}),
                    call("@for_each_entity", {"where_prefix": "bullet_", "do": [gif({"<": [{"var": "loop.entity.x"}, {"-": [{"var": "entities.player.x"}, 200]}]}, [despawn("{{ loop.id }}")])]}),
                ]),
            ]
        },
        "on_score_changed": {"type": "call", "call": "@global.scoreChanged", "args": {"score": "{{ event.score }}", "best": "{{ event.best }}"}},
        "on_status": {"type": "call", "call": "@global.status", "args": {"text": "{{ event.text }}"}},
        "on_game_over": {"type": "call", "call": "@global.over", "args": {"score": "{{ event.score }}", "best": "{{ event.best }}"}},
        "on_reset": {"type": "call", "call": "@global.reset", "args": {}},
    }
    return app(
        "demo-bgug-runner",
        "BGUG Runner",
        "JSON-only parity pass for bgug: held jump, dive, sector generation, gems, coins, shooters, bullets, and block-era HUD assets.",
        assets={"bundles": {"source-bgug": bundle(pack, "MIT", "BGUG source assets and audio")}},
        variables={"score": 0, "bestScore": 0, "status": "Ready", "_choice": None},
        functions=score_functions("BGUG Runner"),
        screens=[game_screen("BGUG Runner", "{{ global.status }}", game, bg="#111827")],
    )


def darkness() -> dict[str, Any]:
    pack = "source-darkness-dungeon"
    enemy_in_vision = {
        "and": [
            {">": [{"var": "loop.entity.x"}, {"-": [{"var": "entities.player.x"}, {"var": "loop.entity.state.vision"}]}]},
            {"<": [{"var": "loop.entity.x"}, {"+": [{"var": "entities.player.x"}, {"var": "loop.entity.state.vision"}]}]},
            {">": [{"var": "loop.entity.y"}, {"-": [{"var": "entities.player.y"}, {"var": "loop.entity.state.vision"}]}]},
            {"<": [{"var": "loop.entity.y"}, {"+": [{"var": "entities.player.y"}, {"var": "loop.entity.state.vision"}]}]},
        ]
    }
    enemy_step = [
        gif(enemy_in_vision, [
            gif({"<": [{"var": "loop.entity.x"}, {"-": [{"var": "entities.player.x"}, 8]}]}, [e_set("{{ loop.id }}", "vx", {"var": "loop.entity.state.speed"})], [gif({">": [{"var": "loop.entity.x"}, {"+": [{"var": "entities.player.x"}, 8]}]}, [e_set("{{ loop.id }}", "vx", {"-": [0, {"var": "loop.entity.state.speed"}]})], [e_set("{{ loop.id }}", "vx", 0)])]),
            gif({"<": [{"var": "loop.entity.y"}, {"-": [{"var": "entities.player.y"}, 8]}]}, [e_set("{{ loop.id }}", "vy", {"var": "loop.entity.state.speed"})], [gif({">": [{"var": "loop.entity.y"}, {"+": [{"var": "entities.player.y"}, 8]}]}, [e_set("{{ loop.id }}", "vy", {"-": [0, {"var": "loop.entity.state.speed"}]})], [e_set("{{ loop.id }}", "vy", 0)])]),
        ], [e_set("{{ loop.id }}", "vx", 0), e_set("{{ loop.id }}", "vy", 0)]),
        call("@entity.flip_by_velocity", {"id": "{{ loop.id }}", "invert": True}),
    ]
    templates = {
        "torch": sprite(pack, "images/items/torch_spritesheet.png", ["{{ object.x }}", "{{ object.y }}"], [32, 32], src=[0, 0, 16, 16], priority=8, state={"kind": "torch"}),
        "torch_empty": sprite(pack, "images/items/torch_spritesheet.png", ["{{ object.x }}", "{{ object.y }}"], [32, 32], src=[0, 0, 16, 16], priority=8, state={"kind": "torch_empty"}),
        "door": sprite(pack, "images/items/door_closed.png", ["{{ object.x }}", "{{ object.y }}"], [64, 64], priority=10, state={"kind": "door"}),
        "key": sprite(pack, "images/items/key_silver.png", ["{{ object.x }}", "{{ object.y }}"], [28, 28], priority=14, state={"kind": "key"}),
        "potion": sprite(pack, "images/items/potion_red.png", ["{{ object.x }}", "{{ object.y }}"], [28, 28], priority=14, state={"kind": "potion"}),
        "spikes": sprite(pack, "images/items/spikes.png", ["{{ object.x }}", "{{ object.y }}"], [32, 32], src=[0, 0, 16, 16], priority=9, state={"kind": "spikes"}),
        "wizard": sprite(pack, "images/npc/wizard.png", ["{{ object.x }}", {"-": ["{{ object.y }}", 20]}], [32, 56], priority=14, state={"kind": "wizard"}),
        "kid": sprite(pack, "images/npc/kid_idle_left.png", ["{{ object.x }}", {"-": ["{{ object.y }}", 12]}], [44, 44], src=[0, 0, 16, 22], priority=14, state={"kind": "kid"}),
        "goblin": anim(pack, "images/enemy/goblin/goblin_idle.png", ["{{ object.x }}", "{{ object.y }}"], [36, 36], [16, 16], 6, frames_per_row=6, priority=18, state={"kind": "enemy", "hp": 120, "speed": 48, "vision": 128}),
        "imp": anim(pack, "images/enemy/imp/imp_idle.png", ["{{ object.x }}", "{{ object.y }}"], [36, 36], [16, 16], 4, frames_per_row=4, priority=18, state={"kind": "enemy", "hp": 80, "speed": 64, "vision": 160}),
        "mini_boss": sprite(pack, "images/enemy/mini_boss/mini_boss_idle.png", ["{{ object.x }}", "{{ object.y }}"], [44, 56], src=[0, 0, 16, 24], priority=18, state={"kind": "enemy", "hp": 150, "speed": 48, "vision": 160}),
        "boss": anim(pack, "images/enemy/boss/boss_idle.png", ["{{ object.x }}", {"-": ["{{ object.y }}", 24]}], [72, 82], [32, 36], 4, frames_per_row=4, priority=18, state={"kind": "enemy", "hp": 200, "speed": 42, "vision": 192, "boss": True}),
    }
    for key, value in templates.items():
        value["id_prefix"] = f"{key}_"

    game = {
        "type": "flame_game",
        "viewport": {"width": 640, "height": 420, "fit": "cover"},
        "world": {"kind": "pixel", "bg": "#111827"},
        "overlay": {"score": False, "game_over": False, "asset_loading_text": "Loading dungeon map..."},
        "camera": {"follow": "player", "map": "map", "offset_x": 0, "offset_y": 0, "smooth_y": 0.3},
        "vars": {"move_x": 0, "move_y": 0, "speed": 80, "hp": 200, "stamina": 100, "hasKey": False, "objects_spawned": False, "attack_cd": 0, "hurt_cd": 0, "_hit": None, "_id": 0, "_dist": 9999},
        "entities": {
            "map": {"kind": "tiled_map", "source": "images/tiled/map.json", "base_url": f"{ASSET_ROOT}/{pack}/{PACK_VERSION}/", "scale": 2, "solid_layers": ["mapa"], "priority": -10},
            "player": anim(pack, "images/player/knight_idle.png", [64, 96], [40, 40], [16, 16], 6, frames_per_row=6, priority=30, animation="idle", animations={
                "idle": {"asset": asset(pack, "images/player/knight_idle.png"), "frame_size": [16, 16], "frames": 6, "frames_per_row": 6, "step_time": 0.12},
                "run": {"asset": asset(pack, "images/player/knight_run.png"), "frame_size": [16, 16], "frames": 6, "frames_per_row": 6, "step_time": 0.08},
            }, state={"assetLoadingOverlay": True}),
        },
        "input": {
            "move_axis": [setv("vars.move_x", {"var": "event.x"}), setv("vars.move_y", {"var": "event.y"})],
            "jump": [gif({"and": [{">=": [{"var": "vars.stamina"}, 10]}, {"<=": [{"var": "vars.attack_cd"}, 0]}]}, [setv("vars.attack_cd", 0.28), setv("vars.stamina", {"-": [{"var": "vars.stamina"}, 10]}), setv("vars._id", {"call": "@random_int", "args": {"min": 1000, "max": 999999}}), spawn("bolt_{{ vars._id }}", anim(pack, "images/player/fireball_right.png", [{"var": "entities.player.x"}, {"var": "entities.player.y"}], [30, 30], [23, 23], 3, frames_per_row=3, velocity=[260, 0], priority=40))])],
            "attack": [gif({"and": [{">=": [{"var": "vars.stamina"}, 15]}, {"<=": [{"var": "vars.attack_cd"}, 0]}]}, [setv("vars.attack_cd", 0.22), setv("vars.stamina", {"-": [{"var": "vars.stamina"}, 15]}), spawn("slash", pixel([{"-": [{"var": "entities.player.x"}, 20]}, {"-": [{"var": "entities.player.y"}, 20]}], [82, 82], "#FBBF2444", shape="circle", priority=50, state={"ttl": 0.14}))])],
        },
        "frame": {"logic": [
            gif({"and": [{"call": "@tiled.loaded", "args": {"map": "map"}}, {"!": {"var": "vars.objects_spawned"}}]}, [
                setv("vars.objects_spawned", True),
                call("@tiled.spawn_objects", {"map": "map", "layer": "objects", "templates": templates, "debug": False}),
                call("@emit", {"event": "status", "data": {"text": "Explore the dungeon. Circle melee, triangle fireball."}}),
            ]),
            setv("vars.attack_cd", {"max": [0, {"-": [{"var": "vars.attack_cd"}, {"var": "event.dt"}]}]}),
            setv("vars.hurt_cd", {"max": [0, {"-": [{"var": "vars.hurt_cd"}, {"var": "event.dt"}]}]}),
            setv("vars.stamina", {"min": [100, {"+": [{"var": "vars.stamina"}, {"*": [13.3, {"var": "event.dt"}]}]}]}),
            e_set("player", "vx", {"*": [{"var": "vars.move_x"}, {"var": "vars.speed"}]}),
            e_set("player", "vy", {"*": [{"var": "vars.move_y"}, {"var": "vars.speed"}]}),
            gif({"or": [{"!=": [{"var": "vars.move_x"}, 0]}, {"!=": [{"var": "vars.move_y"}, 0]}]}, [call("@animated_sprite.set_animation", {"id": "player", "animation": "run"})], [call("@animated_sprite.set_animation", {"id": "player", "animation": "idle"})]),
            e_add("player", "x", 0, min=16, max=1540),
            e_add("player", "y", 0, min=16, max=1540),
            call("@for_each_entity", {"where_prefix": "goblin_", "do": enemy_step}),
            call("@for_each_entity", {"where_prefix": "imp_", "do": enemy_step}),
            call("@for_each_entity", {"where_prefix": "mini_boss_", "do": enemy_step}),
            call("@for_each_entity", {"where_prefix": "boss_", "do": enemy_step}),
            call("@collision.first", {"a": "player", "where_prefix": "key_"}, "vars._hit"),
            gif({"!=": [{"var": "vars._hit"}, None]}, [despawn("{{ vars._hit }}"), setv("vars.hasKey", True), call("@score.add", {"n": 100}), call("@emit", {"event": "status", "data": {"text": "Silver key found"}}), setv("vars._hit", None)]),
            call("@collision.first", {"a": "player", "where_prefix": "potion_"}, "vars._hit"),
            gif({"!=": [{"var": "vars._hit"}, None]}, [despawn("{{ vars._hit }}"), setv("vars.hp", {"min": [200, {"+": [{"var": "vars.hp"}, 30]}]}), call("@emit", {"event": "status", "data": {"text": "Life restored"}}), setv("vars._hit", None)]),
            call("@collision.first", {"a": "player", "where_prefix": "spikes_"}, "vars._hit"),
            gif({"and": [{"!=": [{"var": "vars._hit"}, None]}, {"<=": [{"var": "vars.hurt_cd"}, 0]}]}, [setv("vars.hurt_cd", 1.0), setv("vars.hp", {"-": [{"var": "vars.hp"}, 30]}), call("@emit", {"event": "status", "data": {"text": "HP {{ vars.hp }} / Stamina {{ vars.stamina }}"}}), setv("vars._hit", None)]),
            gif({"call": "@entity.exists", "args": {"id": "slash"}}, [e_set("slash", "x", {"-": [{"var": "entities.player.x"}, 20]}), e_set("slash", "y", {"-": [{"var": "entities.player.y"}, 20]}), e_add("slash", "state.ttl", {"-": [0, {"var": "event.dt"}]}), call("@collision.first", {"a": "slash", "where_prefix": "goblin_"}, "vars._hit"), gif({"==": [{"var": "vars._hit"}, None]}, [call("@collision.first", {"a": "slash", "where_prefix": "imp_"}, "vars._hit")]), gif({"==": [{"var": "vars._hit"}, None]}, [call("@collision.first", {"a": "slash", "where_prefix": "mini_boss_"}, "vars._hit")]), gif({"==": [{"var": "vars._hit"}, None]}, [call("@collision.first", {"a": "slash", "where_prefix": "boss_"}, "vars._hit")]), gif({"!=": [{"var": "vars._hit"}, None]}, [despawn("{{ vars._hit }}"), call("@score.add", {"n": 120}), setv("vars._hit", None)]), gif({"<=": [{"var": "entities.slash.state.ttl"}, 0]}, [despawn("slash")])]),
            call("@for_each_entity", {"where_prefix": "bolt_", "do": [call("@collision.first", {"a": "{{ loop.id }}", "where_prefix": "goblin_"}, "vars._hit"), gif({"==": [{"var": "vars._hit"}, None]}, [call("@collision.first", {"a": "{{ loop.id }}", "where_prefix": "imp_"}, "vars._hit")]), gif({"==": [{"var": "vars._hit"}, None]}, [call("@collision.first", {"a": "{{ loop.id }}", "where_prefix": "mini_boss_"}, "vars._hit")]), gif({"==": [{"var": "vars._hit"}, None]}, [call("@collision.first", {"a": "{{ loop.id }}", "where_prefix": "boss_"}, "vars._hit")]), gif({"!=": [{"var": "vars._hit"}, None]}, [despawn("{{ loop.id }}"), despawn("{{ vars._hit }}"), call("@score.add", {"n": 150}), setv("vars._hit", None)]), gif({">": [{"var": "loop.entity.x"}, {"+": [{"var": "entities.player.x"}, 500]}]}, [despawn("{{ loop.id }}")])]}),
            call("@collision.first", {"a": "player", "where_prefix": "goblin_"}, "vars._hit"),
            gif({"==": [{"var": "vars._hit"}, None]}, [call("@collision.first", {"a": "player", "where_prefix": "imp_"}, "vars._hit")]),
            gif({"==": [{"var": "vars._hit"}, None]}, [call("@collision.first", {"a": "player", "where_prefix": "mini_boss_"}, "vars._hit")]),
            gif({"==": [{"var": "vars._hit"}, None]}, [call("@collision.first", {"a": "player", "where_prefix": "boss_"}, "vars._hit")]),
            gif({"and": [{"!=": [{"var": "vars._hit"}, None]}, {"<=": [{"var": "vars.hurt_cd"}, 0]}]}, [setv("vars.hurt_cd", 0.8), setv("vars.hp", {"-": [{"var": "vars.hp"}, 20]}), call("@emit", {"event": "status", "data": {"text": "HP {{ vars.hp }} / Stamina {{ vars.stamina }}"}}), setv("vars._hit", None)]),
            gif({"<=": [{"var": "vars.hp"}, 0]}, [call("@game_over")]),
        ]},
        "on_score_changed": {"type": "call", "call": "@global.scoreChanged", "args": {"score": "{{ event.score }}", "best": "{{ event.best }}"}},
        "on_status": {"type": "call", "call": "@global.status", "args": {"text": "{{ event.text }}"}},
        "on_game_over": {"type": "call", "call": "@global.over", "args": {"score": "{{ event.score }}", "best": "{{ event.best }}"}},
        "on_reset": {"type": "call", "call": "@global.reset", "args": {}},
    }
    return app(
        "demo-darkness-dungeon",
        "Darkness Dungeon",
        "JSON-only port using the original Tiled map object layer and source sprites.",
        deps={"common-ui": "^1.3.0", "game-controls": "^1.0.8"},
        assets={"bundles": {"source-darkness-dungeon": bundle(pack, "MIT", "Darkness Dungeon source map and sprites")}},
        variables={"score": 0, "bestScore": 0, "status": "Loading dungeon...", "_choice": None, "_gamepadStyle": "default", "_gamepadEditing": False, "_gamepadReset": 0},
        functions=score_functions("Darkness Dungeon"),
        screens=[game_screen("Darkness Dungeon", "{{ global.status }}", game, controls=gamepad("move_axis", "jump", "attack", bg="#111827"), bg="#111827")],
    )


def new_super_jumper() -> dict[str, Any]:
    pack = "source-new-super-jumper"
    platform_paths = [
        "LandPiece_DarkBlue.png", "LandPiece_LightBlue.png", "LandPiece_DarkBeige.png", "LandPiece_LightBeige.png",
        "LandPiece_DarkGray.png", "LandPiece_LightGray.png", "LandPiece_DarkGreen.png", "LandPiece_LightGreen.png",
        "LandPiece_DarkMulticolored.png", "LandPiece_LightMulticolored.png", "LandPiece_DarkPink.png", "LandPiece_LightPink.png",
        "BrokenLandPiece_Blue.png", "BrokenLandPiece_Beige.png", "BrokenLandPiece_Gray.png", "BrokenLandPiece_Green.png",
        "BrokenLandPiece_Multicolored.png", "BrokenLandPiece_Pink.png",
    ]
    spawn_platform = [
        setv("vars._id", {"call": "@random_int", "args": {"min": 1000, "max": 999999}}),
        setv("vars._ptype", {"call": "@random_int", "args": {"min": 0, "max": len(platform_paths)}}),
        *indexed_branch(
            "vars._ptype",
            len(platform_paths),
            lambda i: [
                spawn(
                    "platform_{{ vars._id }}",
                    sprite(
                        pack,
                        f"sprites/{platform_paths[i]}",
                        [{"call": "@random_int", "args": {"min": 8, "max": 316}}, {"var": "vars.gen_y"}],
                        [112, 52],
                        priority=5,
                        state={"broken": i >= 12},
                    ),
                )
            ],
        ),
        gif({"<": [{"call": "@random_double", "args": {"min": 0, "max": 1}}, 0.3]}, [
            setv("vars._id", {"call": "@random_int", "args": {"min": 1000, "max": 999999}}),
            spawn("coin_{{ vars._id }}", sprite(pack, "sprites/Coin.png", [{"call": "@random_int", "args": {"min": 12, "max": 390}}, {"-": [{"var": "vars.gen_y"}, 46]}], [26, 33], priority=12)),
        ]),
        gif({"<": [{"call": "@random_double", "args": {"min": 0, "max": 1}}, 0.22]}, [
            setv("vars._id", {"call": "@random_int", "args": {"min": 1000, "max": 999999}}),
            setv("vars._power", {"call": "@random_int", "args": {"min": 0, "max": 3}}),
            *indexed_branch(
                "vars._power",
                3,
                lambda i: [
                    spawn(
                        "power_{{ vars._id }}",
                        sprite(
                            pack,
                            f"sprites/{['Jetpack_Small.png', 'Bubble_Small.png', 'Pistol.png'][i]}",
                            [{"call": "@random_int", "args": {"min": 14, "max": 380}}, {"-": [{"var": "vars.gen_y"}, 38]}],
                            [30, 38],
                            priority=13,
                            state={"type": i},
                        ),
                    )
                ],
            ),
        ]),
        gif({"<": [{"call": "@random_double", "args": {"min": 0, "max": 1}}, 0.42]}, [
            setv("vars._id", {"call": "@random_int", "args": {"min": 1000, "max": 999999}}),
            gif({"<": [{"call": "@random_double", "args": {"min": 0, "max": 1}}, 0.72]}, [
                spawn("enemy_{{ vars._id }}", sprite(pack, "sprites/HearthEnemy1.png", [{"call": "@random_int", "args": {"min": 20, "max": 360}}, {"-": [{"var": "vars.gen_y"}, 88]}], [70, 42], priority=14, velocity=[80, 0], state={"minX": 0, "maxX": 390}))
            ], [
                spawn("cloud_{{ vars._id }}", sprite(pack, "sprites/HappyCloud.png", [{"call": "@random_int", "args": {"min": 20, "max": 330}}, {"-": [{"var": "vars.gen_y"}, 110]}], [92, 50], priority=14, velocity=[70, 0], state={"minX": 0, "maxX": 360, "timer": 0}))
            ]),
        ]),
        setv("vars.gen_y", {"-": [{"var": "vars.gen_y"}, 84]}),
    ]
    game = {
        "type": "flame_game",
        "viewport": {"width": 428, "height": 926, "fit": "contain"},
        "world": {"kind": "pixel", "bg": "#9DD7F3"},
        "overlay": {"score": False, "game_over": False, "asset_loading_text": "Loading New Super Jumper atlas assets..."},
        "vars": {"move_x": 0, "gravity": 980, "jump_v": -750, "speed": 260, "prev_bottom": 0, "gen_y": 620, "scroll": 0, "coins": 0, "bullets": 0, "jetpack": 0, "bubble": False, "_hit": None, "_hit_y": 0, "_hit_broken": False, "_power_type": 0, "_id": 0, "_ptype": 0, "_power": 0, "shoot_cd": 0},
        "entities": {
            "bg": sprite(pack, "sprites/background.png", [0, 0], [428, 926], priority=-20, fixed=True),
            "hero": anim(pack, "sprites/heroFall.png", [176, 706], [74, 79], [74, 79], 1, priority=30, state={"assetLoadingOverlay": True, "state": "fall"}, animation="fall", animations={
                "fall": {"asset": asset(pack, "sprites/heroFall.png"), "frame_size": [74, 79], "frames": 1, "frames_per_row": 1, "step_time": 0.1},
                "jump": {"asset": asset(pack, "sprites/heroJump.png"), "frame_size": [74, 79], "frames": 1, "frames_per_row": 1, "step_time": 0.1},
            }),
            "floor": pixel([0, 840], [428, 18], "#FFFFFF00", priority=0),
        },
        "init": {"logic": [spawn("platform_start", sprite(pack, "sprites/LandPiece_DarkBlue.png", [154, 790], [120, 54], priority=5))] + [step for _ in range(13) for step in spawn_platform] + [call("@emit", {"event": "status", "data": {"text": "Tilt or joystick to move. Tap attack to fire."}})]},
        "input": {
            "move_axis": [setv("vars.move_x", {"var": "event.x"})],
            "jump": [e_set("hero", "vy", {"var": "vars.jump_v"})],
            "attack": [gif({"and": [{">": [{"var": "vars.bullets"}, 0]}, {"<=": [{"var": "vars.shoot_cd"}, 0]}]}, [setv("vars.shoot_cd", 0.18), setv("vars.bullets", {"max": [0, {"-": [{"var": "vars.bullets"}, 3]}]}), setv("vars._id", {"call": "@random_int", "args": {"min": 1000, "max": 999999}}), spawn("bullet_{{ vars._id }}", sprite(pack, "sprites/Bullet.png", [{"var": "entities.hero.x"}, {"var": "entities.hero.y"}], [12, 12], velocity=[0, -640], priority=40))])],
        },
        "frame": {"logic": [
            setv("vars.prev_bottom", {"+": [{"var": "entities.hero.y"}, {"var": "entities.hero.h"}]}),
            e_set("hero", "vx", {"*": [{"var": "vars.move_x"}, {"var": "vars.speed"}]}),
            call("@pixel.add_velocity", {"id": "hero", "dv": [0, {"*": [{"var": "vars.gravity"}, {"var": "event.dt"}]}]}),
            setv("vars.shoot_cd", {"max": [0, {"-": [{"var": "vars.shoot_cd"}, {"var": "event.dt"}]}]}),
            gif({">": [{"var": "vars.jetpack"}, 0]}, [setv("vars.jetpack", {"-": [{"var": "vars.jetpack"}, {"var": "event.dt"}]}), e_set("hero", "vy", {"var": "vars.jump_v"})]),
            gif({">": [{"var": "entities.hero.x"}, 428]}, [e_set("hero", "x", -70)]),
            gif({"<": [{"var": "entities.hero.x"}, -76]}, [e_set("hero", "x", 428)]),
            gif({">": [{"var": "entities.hero.vy"}, 0]}, [call("@animated_sprite.set_animation", {"id": "hero", "animation": "fall"})], [call("@animated_sprite.set_animation", {"id": "hero", "animation": "jump"})]),
            call("@collision.first", {"a": "hero", "where_prefix": "platform_"}, "vars._hit"),
            gif({"and": [{"!=": [{"var": "vars._hit"}, None]}, {">": [{"var": "entities.hero.vy"}, 0]}]}, [
                call("@entity.get", {"id": "{{ vars._hit }}", "field": "y"}, "vars._hit_y"),
                call("@entity.get", {"id": "{{ vars._hit }}", "field": "state.broken"}, "vars._hit_broken"),
                gif({"<=": [{"var": "vars.prev_bottom"}, {"+": [{"var": "vars._hit_y"}, 24]}]}, [
                    gif({"var": "vars._hit_broken"}, [despawn("{{ vars._hit }}"), setv("vars._id", {"call": "@random_int", "args": {"min": 1000, "max": 999999}}), spawn("piece_l_{{ vars._id }}", sprite(pack, "sprites/HalfLandPiece_Left_Blue.png", [{"var": "entities.hero.x"}, {"var": "entities.hero.y"}], [64, 46], velocity=[-90, -90], priority=6)), spawn("piece_r_{{ vars._id }}", sprite(pack, "sprites/HalfLandPiece_Right_Blue.png", [{"var": "entities.hero.x"}, {"var": "entities.hero.y"}], [64, 46], velocity=[90, -90], priority=6))]),
                    e_set("hero", "vy", {"var": "vars.jump_v"}),
                    call("@score.add", {"n": 10}),
                ]),
                setv("vars._hit", None),
            ]),
            gif({"and": [{"call": "@collide.rect", "args": {"a": "hero", "b": "floor"}}, {">": [{"var": "entities.hero.vy"}, 0]}]}, [e_set("hero", "vy", {"var": "vars.jump_v"})]),
            gif({"<": [{"var": "entities.hero.y"}, 330]}, [setv("vars.scroll", {"-": [330, {"var": "entities.hero.y"}]}), e_set("hero", "y", 330), call("@for_each_entity", {"where_prefix": "platform_", "do": [e_add("{{ loop.id }}", "y", {"var": "vars.scroll"})]}), call("@for_each_entity", {"where_prefix": "coin_", "do": [e_add("{{ loop.id }}", "y", {"var": "vars.scroll"})]}), call("@for_each_entity", {"where_prefix": "power_", "do": [e_add("{{ loop.id }}", "y", {"var": "vars.scroll"})]}), call("@for_each_entity", {"where_prefix": "enemy_", "do": [e_add("{{ loop.id }}", "y", {"var": "vars.scroll"})]}), call("@for_each_entity", {"where_prefix": "cloud_", "do": [e_add("{{ loop.id }}", "y", {"var": "vars.scroll"})]}), call("@score.add", {"n": "{{ vars.scroll }}"})]),
            call("@for_each_entity", {"where_prefix": "platform_", "do": [gif({">": [{"var": "loop.entity.y"}, 980]}, [despawn("{{ loop.id }}")])]}),
            call("@for_each_entity", {"where_prefix": "enemy_", "do": [gif({"<": [{"var": "loop.entity.x"}, 0]}, [e_set("{{ loop.id }}", "vx", 90)]), gif({">": [{"var": "loop.entity.x"}, 360]}, [e_set("{{ loop.id }}", "vx", -90)])]}),
            call("@for_each_entity", {"where_prefix": "cloud_", "do": [gif({"<": [{"var": "loop.entity.x"}, 0]}, [e_set("{{ loop.id }}", "vx", 70)]), gif({">": [{"var": "loop.entity.x"}, 350]}, [e_set("{{ loop.id }}", "vx", -70)]), e_add("{{ loop.id }}", "state.timer", {"var": "event.dt"}), gif({">": [{"var": "loop.entity.state.timer"}, 4.6]}, [e_set("{{ loop.id }}", "state.timer", 0), setv("vars._id", {"call": "@random_int", "args": {"min": 1000, "max": 999999}}), spawn("lightning_{{ vars._id }}", sprite(pack, "sprites/Lightning1.png", [{"var": "loop.entity.x"}, {"+": [{"var": "loop.entity.y"}, 45]}], [28, 102], velocity=[0, 180], priority=13))])]}),
            call("@collision.first", {"a": "hero", "where_prefix": "coin_"}, "vars._hit"),
            gif({"!=": [{"var": "vars._hit"}, None]}, [despawn("{{ vars._hit }}"), setv("vars.coins", {"+": [{"var": "vars.coins"}, 1]}), e_set("hero", "vy", -850), call("@score.add", {"n": 25}), setv("vars._hit", None)]),
            call("@collision.first", {"a": "hero", "where_prefix": "power_"}, "vars._hit"),
            gif({"!=": [{"var": "vars._hit"}, None]}, [call("@entity.get", {"id": "{{ vars._hit }}", "field": "state.type"}, "vars._power_type"), gif({"==": [{"var": "vars._power_type"}, 0]}, [setv("vars.jetpack", 3.0)]), gif({"==": [{"var": "vars._power_type"}, 1]}, [setv("vars.bubble", True)]), gif({"==": [{"var": "vars._power_type"}, 2]}, [setv("vars.bullets", {"+": [{"var": "vars.bullets"}, 25]})]), despawn("{{ vars._hit }}"), setv("vars._hit", None)]),
            call("@collision.first", {"a": "hero", "where_prefix": "enemy_"}, "vars._hit"),
            gif({"!=": [{"var": "vars._hit"}, None]}, [gif({"var": "vars.bubble"}, [setv("vars.bubble", False), despawn("{{ vars._hit }}"), setv("vars._hit", None)], [call("@game_over")])]),
            call("@collision.first", {"a": "hero", "where_prefix": "lightning_"}, "vars._hit"),
            gif({"!=": [{"var": "vars._hit"}, None]}, [call("@game_over")]),
            call("@for_each_entity", {"where_prefix": "bullet_", "do": [call("@collision.first", {"a": "{{ loop.id }}", "where_prefix": "enemy_"}, "vars._hit"), gif({"!=": [{"var": "vars._hit"}, None]}, [despawn("{{ loop.id }}"), despawn("{{ vars._hit }}"), call("@score.add", {"n": 100}), setv("vars._hit", None)]), gif({"<": [{"var": "loop.entity.y"}, -80]}, [despawn("{{ loop.id }}")])]}),
            gif({">": [{"var": "entities.hero.y"}, 1020]}, [call("@game_over")]),
            gif({"<": [{"var": "vars.gen_y"}, -260]}, [setv("vars.gen_y", 0), call("@loop_by_num", {"count": 6, "body": spawn_platform})]),
        ]},
        "on_score_changed": {"type": "call", "call": "@global.scoreChanged", "args": {"score": "{{ event.score }}", "best": "{{ event.best }}"}},
        "on_status": {"type": "call", "call": "@global.status", "args": {"text": "{{ event.text }}"}},
        "on_game_over": {"type": "call", "call": "@global.over", "args": {"score": "{{ event.score }}", "best": "{{ event.best }}"}},
        "on_reset": {"type": "call", "call": "@global.reset", "args": {}},
    }
    return app(
        "demo-new-super-jumper",
        "New Super Jumper",
        "JSON-only port using the extracted TexturePacker atlas sprites, vertical world loop, one-way platforms, enemies, powerups, coins, bullets, and wrap movement.",
        deps={"common-ui": "^1.3.0", "game-controls": "^1.0.8"},
        assets={"bundles": {"source-new-super-jumper": bundle(pack, "Repository license not specified", "Extracted New Super Jumper atlas assets")}},
        variables={"score": 0, "bestScore": 0, "status": "Ready", "_choice": None, "_gamepadStyle": "default", "_gamepadEditing": False, "_gamepadReset": 0},
        functions=score_functions("New Super Jumper"),
        screens=[game_screen("New Super Jumper", "{{ global.status }}", game, controls=gamepad("move_axis", "jump", "attack", bg="#0EA5E9"), bg="#0EA5E9")],
    )


def rps() -> dict[str, Any]:
    pack = "source-guidi-tu"
    rock = asset(pack, "images/rps/hands/rock.png")
    paper = asset(pack, "images/rps/hands/paper.png")
    scissors = asset(pack, "images/rps/hands/scissors.png")
    empty = asset(pack, "images/rps/hands/rock_grey.png")

    def pick_button(label: str, img: str, value: str) -> dict[str, Any]:
        return {"type": "button", "label": label, "style": {"type": "filled", "backgroundColor": "#FACC15", "textColor": "#111827"}, "action": {"call": "@global.pick", "args": {"gesture": value, "url": img}}}

    def slot(prefix: str, i: int) -> dict[str, Any]:
        return {"type": "image", "src": "{{ global." + prefix + f"{i} }}", "width": 70, "height": 56, "fit": "contain"}

    def score_pair(i: int) -> list[dict[str, Any]]:
        return [
            setv("global._a", f"{{{{ global.p1.{i} }}}}"),
            setv("global._b", f"{{{{ global.p2.{i} }}}}"),
            uif({"or": [{"and": [{"==": [{"var": "global._a"}, "rock"]}, {"==": [{"var": "global._b"}, "scissors"]}]}, {"and": [{"==": [{"var": "global._a"}, "paper"]}, {"==": [{"var": "global._b"}, "rock"]}]}, {"and": [{"==": [{"var": "global._a"}, "scissors"]}, {"==": [{"var": "global._b"}, "paper"]}]}]}, [setv("global.p1Score", {"+": [{"var": "global.p1Score"}, 1]})]),
            uif({"or": [{"and": [{"==": [{"var": "global._b"}, "rock"]}, {"==": [{"var": "global._a"}, "scissors"]}]}, {"and": [{"==": [{"var": "global._b"}, "paper"]}, {"==": [{"var": "global._a"}, "rock"]}]}, {"and": [{"==": [{"var": "global._b"}, "scissors"]}, {"==": [{"var": "global._a"}, "paper"]}]}]}, [setv("global.p2Score", {"+": [{"var": "global.p2Score"}, 1]})]),
        ]

    funcs = {
        "pick": {
            "params": ["gesture", "url"],
            "logic": [
                uif({"==": [{"var": "global.phase"}, "p1"]}, [
                    uif({"<": [{"var": "global.p1Count"}, 4]}, [
                        setv("global.p1.{{ global.p1Count }}", "{{ params.gesture }}"),
                        setv("global.p1Url{{ global.p1Count }}", "{{ params.url }}"),
                        setv("global.p1Count", {"+": [{"var": "global.p1Count"}, 1]}),
                    ]),
                    uif({"==": [{"var": "global.p1Count"}, 4]}, [setv("global.phase", "p2"), setv("global.status", "Player 2 sequence")]),
                ], [
                    uif({"and": [{"==": [{"var": "global.phase"}, "p2"]}, {"<": [{"var": "global.p2Count"}, 4]}]}, [
                        setv("global.p2.{{ global.p2Count }}", "{{ params.gesture }}"),
                        setv("global.p2Url{{ global.p2Count }}", "{{ params.url }}"),
                        setv("global.p2Count", {"+": [{"var": "global.p2Count"}, 1]}),
                    ]),
                    uif({"==": [{"var": "global.p2Count"}, 4]}, [{"call": "@global.score", "args": {}}]),
                ]),
            ],
        },
        "back": {
            "logic": [
                uif({"and": [{"==": [{"var": "global.phase"}, "p1"]}, {">": [{"var": "global.p1Count"}, 0]}]}, [
                    setv("global.p1Count", {"-": [{"var": "global.p1Count"}, 1]}),
                    setv("global.p1.{{ global.p1Count }}", ""),
                    setv("global.p1Url{{ global.p1Count }}", "{{ global.empty }}"),
                ]),
                uif({"and": [{"==": [{"var": "global.phase"}, "p2"]}, {">": [{"var": "global.p2Count"}, 0]}]}, [
                    setv("global.p2Count", {"-": [{"var": "global.p2Count"}, 1]}),
                    setv("global.p2.{{ global.p2Count }}", ""),
                    setv("global.p2Url{{ global.p2Count }}", "{{ global.empty }}"),
                ]),
            ],
        },
        "score": {
            "logic": [
                setv("global.p1Score", 0),
                setv("global.p2Score", 0),
                *[step for i in range(4) for step in score_pair(i)],
                setv("global.phase", "result"),
                setv("global.status", "P1 {{ global.p1Score }} : {{ global.p2Score }} P2"),
            ],
        },
        "reset": {"logic": [
            setv("global.phase", "p1"), setv("global.status", "Player 1 sequence"), setv("global.p1Count", 0), setv("global.p2Count", 0), setv("global.p1Score", 0), setv("global.p2Score", 0),
            *[setv(f"global.p1.{i}", "") for i in range(4)], *[setv(f"global.p2.{i}", "") for i in range(4)],
            *[setv(f"global.p1Url{i}", "{{ global.empty }}") for i in range(4)], *[setv(f"global.p2Url{i}", "{{ global.empty }}") for i in range(4)],
        ]},
    }
    screen = {
        "id": "home",
        "title": "Guidi Tu RPS",
        "appBar": {"title": "Guidi Tu RPS", "centerTitle": True, "backgroundColor": "#111827", "color": "#FFFFFF", "actions": [{"icon": "replay", "action": {"call": "@global.reset", "args": {}}}]},
        "layout": "column",
        "padding": 14,
        "children": [
            {"type": "image", "src": asset(pack, "images/title/logo_en.png"), "height": 92, "fit": "contain"},
            {"type": "text", "value": "{{ global.status }}", "style": {"fontSize": 18, "fontWeight": "bold", "color": "#111827", "align": "center"}},
            {"type": "container", "padding": 10, "layout": "row", "mainAxisAlignment": "spaceEvenly", "children": [slot("p1Url", i) for i in range(4)]},
            {"type": "container", "padding": 10, "layout": "row", "mainAxisAlignment": "spaceEvenly", "children": [slot("p2Url", i) for i in range(4)]},
            {"type": "container", "padding": 10, "layout": "row", "mainAxisAlignment": "spaceEvenly", "children": [pick_button("Rock", rock, "rock"), pick_button("Paper", paper, "paper"), pick_button("Scissors", scissors, "scissors"), {"type": "button", "label": "Back", "style": {"type": "outlined"}, "action": {"call": "@global.back", "args": {}}}]},
            {"type": "text", "visible": {"==": [{"var": "global.phase"}, "result"]}, "value": "Result: Player 1 {{ global.p1Score }} - {{ global.p2Score }} Player 2", "style": {"fontSize": 18, "fontWeight": "bold", "color": "#7C2D12", "align": "center"}},
        ],
    }
    return app(
        "demo-guidi-tu-rps",
        "Guidi Tu RPS",
        "Pass-and-play JSON port of Guidi Tu Rock Paper Scissors with source hand assets and per-slot sequence scoring.",
        assets={"bundles": {"source-guidi-tu": bundle(pack, "CC BY-NC-SA 4.0", "Guidi Tu LFS hand/interstitial assets")}},
        variables={"phase": "p1", "status": "Player 1 sequence", "empty": empty, "p1": ["", "", "", ""], "p2": ["", "", "", ""], "p1Count": 0, "p2Count": 0, "p1Score": 0, "p2Score": 0, "_a": "", "_b": "", **{f"p1Url{i}": empty for i in range(4)}, **{f"p2Url{i}": empty for i in range(4)}},
        functions=funcs,
        screens=[screen],
    )


def boules() -> dict[str, Any]:
    pack = "source-guidi-tu"
    game = {
        "type": "flame_game",
        "viewport": {"width": 428, "height": 760, "fit": "contain"},
        "world": {"kind": "pixel", "bg": "#14532D"},
        "overlay": {"score": False, "game_over": False, "asset_loading_text": "Loading Boules assets..."},
        "vars": {"state": "aim", "friction": 0.986, "dx": 0, "dy": 0, "dist2": 0, "speed2": 0},
        "entities": {
            "jack": sprite(pack, "images/boules/target.png", [190, 118], [36, 36], priority=8, state={"assetLoadingOverlay": True}),
            "bowl": sprite(pack, "images/boules/bowl.png", [190, 628], [42, 42], priority=12),
            "aim": pixel([185, 460], [52, 52], "#FFFFFF33", shape="circle", priority=4),
            "arrow": pixel([205, 480], [8, 150], "#E0F2FE88", priority=3),
        },
        "input": {
            "pan": [gif({"==": [{"var": "vars.state"}, "aim"]}, [e_add("aim", "x", {"var": "event.dx"}, min=20, max=356), e_add("aim", "y", {"var": "event.dy"}, min=60, max=650), e_set("arrow", "x", {"var": "entities.aim.x"}), e_set("arrow", "y", {"var": "entities.aim.y"})])],
            "swipe": [gif({"==": [{"var": "vars.state"}, "aim"]}, [e_set("bowl", "vx", {"*": [{"var": "event.dx"}, 1.65]}), e_set("bowl", "vy", {"*": [{"var": "event.dy"}, 1.65]}), e_set("arrow", "render.color", "#FFFFFF00"), setv("vars.state", "rolling"), call("@emit", {"event": "status", "data": {"text": "Rolling"}})])],
            "tap": [gif({"==": [{"var": "vars.state"}, "done"]}, [call("@game_reset")])],
        },
        "frame": {"logic": [
            gif({"==": [{"var": "vars.state"}, "rolling"]}, [
                e_set("bowl", "vx", {"*": [{"var": "entities.bowl.vx"}, {"var": "vars.friction"}]}),
                e_set("bowl", "vy", {"*": [{"var": "entities.bowl.vy"}, {"var": "vars.friction"}]}),
                gif({"<": [{"var": "entities.bowl.x"}, 0]}, [e_set("bowl", "x", 0), e_set("bowl", "vx", {"*": [{"var": "entities.bowl.vx"}, -0.72]})]),
                gif({">": [{"var": "entities.bowl.x"}, 386]}, [e_set("bowl", "x", 386), e_set("bowl", "vx", {"*": [{"var": "entities.bowl.vx"}, -0.72]})]),
                gif({"<": [{"var": "entities.bowl.y"}, 0]}, [e_set("bowl", "y", 0), e_set("bowl", "vy", {"*": [{"var": "entities.bowl.vy"}, -0.72]})]),
                gif({">": [{"var": "entities.bowl.y"}, 718]}, [e_set("bowl", "y", 718), e_set("bowl", "vy", {"*": [{"var": "entities.bowl.vy"}, -0.72]})]),
                gif({"call": "@collide.rect", "args": {"a": "bowl", "b": "jack"}}, [e_set("jack", "vx", {"*": [{"var": "entities.bowl.vx"}, 0.45]}), e_set("jack", "vy", {"*": [{"var": "entities.bowl.vy"}, 0.45]})]),
                e_set("jack", "vx", {"*": [{"var": "entities.jack.vx"}, 0.965]}),
                e_set("jack", "vy", {"*": [{"var": "entities.jack.vy"}, 0.965]}),
                setv("vars.speed2", {"+": [{"*": [{"var": "entities.bowl.vx"}, {"var": "entities.bowl.vx"}]}, {"*": [{"var": "entities.bowl.vy"}, {"var": "entities.bowl.vy"}]}]}),
                gif({"<": [{"var": "vars.speed2"}, 20]}, [
                    e_set("bowl", "vx", 0),
                    e_set("bowl", "vy", 0),
                    setv("vars.dx", {"-": [{"+": [{"var": "entities.bowl.x"}, 21]}, {"+": [{"var": "entities.jack.x"}, 18]}]}),
                    setv("vars.dy", {"-": [{"+": [{"var": "entities.bowl.y"}, 21]}, {"+": [{"var": "entities.jack.y"}, 18]}]}),
                    setv("vars.dist2", {"+": [{"*": [{"var": "vars.dx"}, {"var": "vars.dx"}]}, {"*": [{"var": "vars.dy"}, {"var": "vars.dy"}]}]}),
                    call("@score.set", {"value": {"max": [0, {"-": [1000, {"*": [{"var": "vars.dist2"}, 0.08]}]}]}}),
                    setv("vars.state", "done"),
                    call("@emit", {"event": "status", "data": {"text": "Stopped. Tap field or restart."}}),
                    call("@game_over"),
                ]),
            ]),
        ]},
        "on_score_changed": {"type": "call", "call": "@global.scoreChanged", "args": {"score": "{{ event.score }}", "best": "{{ event.best }}"}},
        "on_status": {"type": "call", "call": "@global.status", "args": {"text": "{{ event.text }}"}},
        "on_game_over": {"type": "call", "call": "@global.over", "args": {"score": "{{ event.score }}", "best": "{{ event.best }}"}},
        "on_reset": {"type": "call", "call": "@global.reset", "args": {}},
    }
    return app(
        "demo-guidi-tu-boules",
        "Guidi Tu Boules",
        "JSON-only Boules port with drag projection, wall bounce, damping, jack collision, and distance scoring.",
        assets={"bundles": {"source-guidi-tu": bundle(pack, "CC BY-NC-SA 4.0", "Guidi Tu Boules LFS assets")}},
        variables={"score": 0, "bestScore": 0, "status": "Drag above the bowl and release.", "_choice": None},
        functions=score_functions("Guidi Tu Boules"),
        screens=[game_screen("Guidi Tu Boules", "{{ global.status }}", game, bg="#14532D")],
    )


def save(filename: str, content: dict[str, Any]) -> None:
    (TEMPLATES / filename).write_text(json.dumps(content, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(filename)


def main() -> None:
    save("demo_bgug_runner.json", bgug())
    save("demo_darkness_dungeon.json", darkness())
    save("demo_new_super_jumper.json", new_super_jumper())
    save("demo_guidi_tu_rps.json", rps())
    save("demo_guidi_tu_boules.json", boules())


if __name__ == "__main__":
    main()
