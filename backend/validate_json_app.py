#!/usr/bin/env python3
"""Static checks for generated JSON-APP files.

This is intentionally conservative: it catches patterns that often produce
runtime crashes or inert apps before the generated JSON is uploaded.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


FORBIDDEN_UI_KEYS = {
    "marginBottom",
    "shadow",
    "transform",
    "transition",
}

JSONLOGIC_SINGLE_KEYS = {
    "!",
    "!!",
    "!=",
    "!==",
    "%",
    "*",
    "+",
    "-",
    "/",
    "<",
    "<=",
    "==",
    "===",
    ">",
    ">=",
    "abs",
    "all",
    "and",
    "at",
    "cat",
    "filter",
    "if",
    "in",
    "length",
    "log",
    "map",
    "max",
    "merge",
    "method",
    "min",
    "missing",
    "missing_some",
    "none",
    "or",
    "reduce",
    "reverse",
    "slice",
    "some",
    "sort",
    "str_contains",
    "str_ends_with",
    "str_index_of",
    "str_lower",
    "str_replace",
    "str_starts_with",
    "str_trim",
    "str_upper",
    "substr",
    "to_double",
    "to_int",
    "to_string",
    "var",
}

ENTITY_SET_FIELDS = {
    "auto_update",
    "autoMove",
    "h",
    "height",
    "state.",
    "vx",
    "vy",
    "w",
    "width",
    "x",
    "y",
}

ENTITY_ADD_FIELDS = {
    "h",
    "height",
    "state.",
    "vx",
    "vy",
    "w",
    "width",
    "x",
    "y",
}

COMPOUND_ENTITY_FIELDS = {"position", "size", "velocity"}

KNOWN_SPRITE_SHEETS = {
    # asset-url suffix -> expected single frame size.
    # These are generic metadata for hosted asset packs, not app-specific rules.
    "asset-packs/vaca-roxa-generic-run-n-gun/1.0/Player/SpriteSheet_player_sliced.png": (45, 45),
    "asset-packs/vaca-roxa-generic-run-n-gun/1.0/Enemies/ARMob.png": (48, 38),
    "asset-packs/vaca-roxa-generic-run-n-gun/1.0/Enemies/RPGmob.png": (48, 38),
    "asset-packs/vaca-roxa-generic-run-n-gun/1.0/Enemies/SniperMob.png": (48, 38),
    "asset-packs/vaca-roxa-generic-run-n-gun/1.0/Enemies/Explosion_Particle.png": (32, 32),
}

DEFAULT_BUILTIN_CALLS = {
    # Dotted built-ins are needed by backend-only registry validation. In the
    # Docker image the Dart sources may not be present, so load_builtin_calls()
    # cannot always discover them dynamically.
    "@animated_sprite.effect",
    "@animated_sprite.set_animation",
    "@cell.set",
    "@cell_path.advance",
    "@cell_path.contains",
    "@cell_path.grow",
    "@cell_path.head",
    "@cell_path.head_collides_self",
    "@collide.rect",
    "@collision.first",
    "@entity.add",
    "@entity.exists",
    "@entity.flip_by_velocity",
    "@entity.get",
    "@entity.set",
    "@grid.random_empty",
    "@pixel.add_velocity",
    "@pixel.set_position",
    "@pixel.set_velocity",
    "@platformer.backend",
    "@platformer.respawn",
    "@platformer.section_exit",
    "@platformer.step",
    "@platformer.stuck_check",
    "@score.add",
    "@score.set",
    "@scroll_list.add_speed",
    "@scroll_list.first_unhit_below",
    "@scroll_list.set_speed",
    "@scroll_list.tap",
    "@tiled.clear_spawned",
    "@tiled.collisions",
    "@tiled.first_object",
    "@tiled.has_collision_type",
    "@tiled.load",
    "@tiled.loaded",
    "@tiled.nearest_object",
    "@tiled.spawn_objects",
    "@tiled.spawn_objects_near",
    "@value_grid.can_move",
    "@value_grid.slide_merge",
    "@value_grid.spawn",
}


@dataclass
class Finding:
    level: str
    path: str
    message: str


class Validator:
    def __init__(self, root: Any, builtin_calls: set[str]) -> None:
        self.root = root
        self.builtin_calls = builtin_calls
        self.findings: list[Finding] = []
        self.dependencies: set[str] = set()
        self.self_package_names: set[str] = set()
        self.flame_games: list[tuple[str, dict[str, Any]]] = []

    def error(self, path: str, message: str) -> None:
        self.findings.append(Finding("ERROR", path, message))

    def warn(self, path: str, message: str) -> None:
        self.findings.append(Finding("WARN", path, message))

    def validate(self) -> int:
        self._validate_root()
        self._walk(self.root, "$", in_game_logic=False)
        self._validate_sprite_sheet_usage()
        self._validate_game_profiles()
        for finding in self.findings:
            print(f"{finding.level} {finding.path}: {finding.message}")
        return 1 if any(f.level == "ERROR" for f in self.findings) else 0

    def _validate_root(self) -> None:
        if not isinstance(self.root, dict):
            self.error("$", "root must be a JSON object")
            return

        for key in ("dsl", "meta"):
            if not self.root.get(key):
                self.error(f"$.{key}", "required field is missing or empty")

        meta = self.root.get("meta")
        app_type = None
        if isinstance(meta, dict):
            app_type = meta.get("type")
            name = str(meta.get("name") or "").strip()
            if name:
                self.self_package_names.add(name)
                self.self_package_names.add(name.rsplit("/", 1)[-1])
            for key in ("name", "version", "type"):
                if not meta.get(key):
                    self.error(f"$.meta.{key}", "required meta field is missing")
        else:
            self.error("$.meta", "meta must be an object")

        dependencies = self.root.get("dependencies", {})
        if dependencies is None:
            dependencies = {}
        if not isinstance(dependencies, dict):
            self.error("$.dependencies", "dependencies must be a map/object")
        else:
            self.dependencies = {str(k) for k in dependencies.keys()}

        if app_type != "library":
            ui = self.root.get("ui")
            screens = ui.get("screens") if isinstance(ui, dict) else None
            if not screens:
                self.error("$.ui.screens", "app JSON must define ui.screens")

    def _walk(self, node: Any, path: str, *, in_game_logic: bool) -> None:
        if isinstance(node, dict):
            self._validate_dict(node, path, in_game_logic=in_game_logic)

            node_type = node.get("type")
            if node_type == "flame_game":
                self.flame_games.append((path, node))
                for key, value in node.items():
                    child_path = self._path(path, key)
                    self._walk(value, child_path, in_game_logic=key in {"frame", "init", "input", "tick"})
                return

            for key, value in node.items():
                self._walk(value, self._path(path, key), in_game_logic=in_game_logic)
            return

        if isinstance(node, list):
            for index, value in enumerate(node):
                self._walk(value, f"{path}[{index}]", in_game_logic=in_game_logic)

    def _validate_dict(self, node: dict[str, Any], path: str, *, in_game_logic: bool) -> None:
        node_type = node.get("type")

        if node_type == "container" and "style" in node:
            self.error(self._path(path, "style"), "container has no style field; flatten style properties")

        for key in node.keys():
            if key in FORBIDDEN_UI_KEYS and not self._is_allowed_non_ui_key(node, key):
                self.error(self._path(path, key), f"unsupported web/CSS-like field: {key}")

        if node_type == "list" and isinstance(node.get("source"), dict):
            self.error(self._path(path, "source"), "list.source must be a string interpolation, not jsonlogic")

        action = node.get("action")
        if isinstance(action, dict) and action.get("type") == "call":
            self.warn(self._path(path, "action"), "type:'call' is accepted but redundant; prefer {call,args}")

        if len(node) == 1:
            only_key = next(iter(node))
            if only_key in JSONLOGIC_SINGLE_KEYS:
                # Single-key jsonlogic is valid; this note is useful only when it
                # appears under args as intended data, which static analysis cannot
                # prove. Keep it a warning to avoid blocking correct expressions.
                pass

        call = node.get("call")
        if isinstance(call, str) and call.startswith("@"):
            args = node.get("args", {})
            if args is None:
                args = {}
            if not isinstance(args, dict):
                self.error(self._path(path, "args"), f"{call} args must be an object")
                return
            self._validate_call(call, args, path, in_game_logic=in_game_logic)

    def _validate_call(
        self,
        call: str,
        args: dict[str, Any],
        path: str,
        *,
        in_game_logic: bool,
    ) -> None:
        if "." in call[1:] and call not in self.builtin_calls:
            dependency = call[1:].split(".", 1)[0]
            if (
                dependency != "global"
                and dependency not in self.dependencies
                and dependency not in self.self_package_names
            ):
                self.error(path, f"dependency call {call} requires top-level dependencies.{dependency}")

        if call == "@if":
            if in_game_logic:
                if "condition" in args and "cond" not in args:
                    self.error(self._path(path, "args.condition"), "flame_game @if must use cond, not condition")
            elif "cond" in args and "condition" not in args:
                self.error(self._path(path, "args.cond"), "main JSON-APP @if must use condition, not cond")

        if call == "@entity.set":
            self._validate_entity_set(args, path)
        elif call == "@entity.add":
            self._validate_entity_add(args, path)

    def _validate_entity_set(self, args: dict[str, Any], path: str) -> None:
        if "id" not in args:
            self.error(self._path(path, "args.id"), "@entity.set requires id")
        if "path" in args and "field" not in args:
            self.error(self._path(path, "args.path"), "@entity.set new JSON must use field, not path")
        field = args.get("field")
        if field is None:
            self.error(self._path(path, "args.field"), "@entity.set requires field")
            return
        field_text = str(field)
        if field_text in COMPOUND_ENTITY_FIELDS:
            self.warn(
                self._path(path, "args.field"),
                "prefer scalar x/y/w/h/vx/vy over compound position/size/velocity",
            )
        elif not self._field_allowed(field_text, ENTITY_SET_FIELDS):
            self.warn(self._path(path, "args.field"), f"uncommon entity field for @entity.set: {field_text}")
        if "value" not in args:
            self.error(self._path(path, "args.value"), "@entity.set requires value")

    def _validate_entity_add(self, args: dict[str, Any], path: str) -> None:
        if "id" not in args:
            self.error(self._path(path, "args.id"), "@entity.add requires id")
        if "path" in args:
            self.error(self._path(path, "args.path"), "@entity.add new JSON must use field, not path")
        if "value" in args:
            self.error(self._path(path, "args.value"), "@entity.add new JSON must use by, not value")
        field = args.get("field")
        if field is None:
            self.error(self._path(path, "args.field"), "@entity.add requires field")
        elif not self._field_allowed(str(field), ENTITY_ADD_FIELDS):
            self.warn(self._path(path, "args.field"), f"uncommon entity field for @entity.add: {field}")
        if "by" not in args:
            self.error(self._path(path, "args.by"), "@entity.add requires by")

    @staticmethod
    def _field_allowed(field: str, allowed: set[str]) -> bool:
        return field in allowed or any(field.startswith(prefix) for prefix in allowed if prefix.endswith("."))

    @staticmethod
    def _is_allowed_non_ui_key(node: dict[str, Any], key: str) -> bool:
        # Tiled object properties legitimately use "type"; asset manifests can
        # include nested data. The blocked keys here are aimed at UI/widget specs.
        if key != "style":
            return False
        return node.get("format") == "tiled-json-v1"

    @staticmethod
    def _path(base: str, key: Any) -> str:
        if isinstance(key, str) and key.replace("_", "").isalnum():
            return f"{base}.{key}"
        return f"{base}[{key!r}]"

    def _validate_sprite_sheet_usage(self) -> None:
        for path, node in self._iter_dicts(self.root):
            kind = node.get("kind")
            if kind not in {"sprite", "animated_sprite"}:
                continue
            render = node.get("render")
            asset = node.get("asset")
            if not asset and isinstance(render, dict):
                asset = render.get("asset")
            asset_text = str(asset or "")
            if not self._looks_like_sprite_sheet(asset_text):
                continue
            known_frame = self._known_frame_size(asset_text)
            has_src = isinstance(node.get("src"), list) and len(node.get("src") or []) >= 4
            if kind == "sprite" and not has_src:
                self.error(
                    self._path(path, "asset"),
                    "sprite sheet/strip asset cannot be rendered as plain sprite without src crop; use animated_sprite or crop one frame",
                )
                continue
            if kind == "sprite" and known_frame is not None:
                src = node.get("src")
                src_w = self._num_at(src, 2)
                src_h = self._num_at(src, 3)
                frame_w, frame_h = known_frame
                if (
                    src_w is None
                    or src_h is None
                    or abs(src_w - frame_w) > 1
                    or abs(src_h - frame_h) > 1
                ):
                    self.error(
                        self._path(path, "src"),
                        f"sprite sheet crop must match one frame ({frame_w}x{frame_h}); current src crops multiple frames",
                    )
            if kind == "animated_sprite":
                frames = node.get("frames")
                animations = node.get("animations")
                frame_size = node.get("frame_size")
                frame_w = self._num_at(frame_size, 0) or self._num_from_map(node, "frame_w")
                frame_h = self._num_at(frame_size, 1) or self._num_from_map(node, "frame_h")
                if not isinstance(animations, dict) and (
                    (frames is None)
                    or (isinstance(frames, (int, float)) and frames <= 1)
                ):
                    self.error(
                        self._path(path, "asset"),
                        "animated sprite sheet requires frames/frame_size/frames_per_row or animations",
                    )
                if known_frame is not None and frame_w is not None and frame_h is not None:
                    expected_w, expected_h = known_frame
                    if abs(frame_w - expected_w) > 1 or abs(frame_h - expected_h) > 1:
                        self.error(
                            self._path(path, "frame_size"),
                            f"animated sprite sheet frame_size must match one frame ({expected_w}x{expected_h})",
                        )

    def _validate_game_profiles(self) -> None:
        if not self._needs_run_and_gun_profile():
            return
        if not self.flame_games:
            self.error("$", "run-and-gun / side-scrolling action games must use flame_game")
            return
        for path, game in self.flame_games:
            self._validate_run_and_gun_game(path, game)

    def _validate_run_and_gun_game(self, path: str, game: dict[str, Any]) -> None:
        viewport = game.get("viewport")
        viewport_w = self._num_from_map(viewport, "width")
        viewport_h = self._num_from_map(viewport, "height")
        if viewport_w is None or viewport_h is None:
            self.error(
                self._path(path, "viewport"),
                "run-and-gun game requires explicit viewport.width and viewport.height",
            )

        camera = game.get("camera")
        if not isinstance(camera, dict) or not str(camera.get("follow") or "").strip():
            self.error(
                self._path(path, "camera"),
                "run-and-gun game requires camera.follow for horizontal progression",
            )

        entities = self._entities_map(game)
        max_right = self._max_entity_right(entities)
        map_width = self._max_tiled_map_width(entities)
        if viewport_w and map_width is None and max_right <= viewport_w * 2:
            self.error(
                self._path(path, "entities"),
                "run-and-gun game needs a horizontal stage at least 3 viewport widths wide, or a tiled_map with known map_data",
            )
        if viewport_w and map_width is not None and map_width < viewport_w * 3:
            self.error(
                self._path(path, "entities"),
                "run-and-gun tiled map is too short; map width should be at least 3 viewport widths",
            )
        if map_width is None and self._stage_feature_count(entities) < 4:
            self.error(
                self._path(path, "entities"),
                "run-and-gun game needs route design, not only flat ground; add tiled_map or at least 4 platforms/covers/obstacles/hazards along the stage",
            )
        bg_layers = self._background_layer_count(entities)
        if bg_layers < 3:
            self.error(
                self._path(path, "entities"),
                "run-and-gun game needs at least 3 visual scene layers (far/mid/near background, foreground/decor, terrain)",
            )
        if bg_layers > 0 and self._non_cloud_background_count(entities) == 0:
            self.error(
                self._path(path, "entities"),
                "run-and-gun background cannot be only clouds/sky; add city/industrial/nature structures or other semantic scenery",
            )
        if map_width is None and self._scene_decor_count(entities) < 6:
            self.error(
                self._path(path, "entities"),
                "run-and-gun game needs rich scene dressing; add at least 6 visible props/landmarks such as buildings, crates, pipes, signs, ruins, rocks or foreground objects",
            )

        direct_y = self._find_direct_vertical_input_write(path, game)
        if direct_y:
            self.error(
                direct_y,
                "run-and-gun player must not fly by writing joystick/event y directly to entity.y; use jump/gravity/platform physics",
            )

        if (
            not self._contains_call(game, "@platformer.step")
            and not self._has_gravity_or_platform_words(game)
        ):
            self.error(
                self._path(path, "frame"),
                "run-and-gun game needs gravity/platform physics each frame, preferably @platformer.step",
            )

    def _needs_run_and_gun_profile(self) -> bool:
        text = self._flatten_text(self.root).lower()
        keywords = (
            "run-and-gun",
            "run and gun",
            "run-n-gun",
            "rungun",
            "side-scrolling shooter",
            "side scrolling shooter",
            "sidescroller shooter",
            "side-scroller shooter",
            "platform shooter",
            "metal slug",
            "metal-action",
            "vaca-roxa-generic-run-n-gun",
            "合金弹头",
            "横版射击",
            "横版动作",
            "平台射击",
        )
        return any(k in text for k in keywords)

    def _find_direct_vertical_input_write(
        self,
        base_path: str,
        game: dict[str, Any],
    ) -> str | None:
        for path, node in self._iter_dicts(game, base_path):
            call = node.get("call")
            if call not in {"@entity.add", "@entity.set"}:
                continue
            args = node.get("args")
            if not isinstance(args, dict):
                continue
            field = str(args.get("field") or args.get("path") or "")
            entity_id = str(args.get("id") or "")
            if field != "y" or (entity_id and entity_id not in {"player", "hero"}):
                continue
            value = args.get("by") if "by" in args else args.get("value")
            value_text = self._flatten_text(value).lower()
            if any(
                token in value_text
                for token in ("move_y", "joystick_y", "event.y", "axis_y", "input_y")
            ):
                return self._path(path, "args")
        return None

    def _contains_call(self, node: Any, call_name: str) -> bool:
        return any(d.get("call") == call_name for _, d in self._iter_dicts(node))

    def _has_gravity_or_platform_words(self, node: Any) -> bool:
        text = self._flatten_text(node).lower()
        return any(
            token in text
            for token in ("gravity", "platform", "ground_y", "on_ground", "onground")
        )

    def _max_entity_right(self, entities: dict[str, Any]) -> float:
        max_right = 0.0
        for spec in entities.values():
            if not isinstance(spec, dict):
                continue
            pos = spec.get("position")
            size = spec.get("size")
            x = self._num_at(pos, 0) or self._num_from_map(spec, "x") or 0.0
            w = (
                self._num_at(size, 0)
                or self._num_from_map(spec, "w")
                or self._num_from_map(spec, "width")
                or 0.0
            )
            max_right = max(max_right, x + w)
        return max_right

    def _max_tiled_map_width(self, entities: dict[str, Any]) -> float | None:
        widths: list[float] = []
        for spec in entities.values():
            if not isinstance(spec, dict) or spec.get("kind") != "tiled_map":
                continue
            map_data = spec.get("map_data")
            if not isinstance(map_data, dict):
                continue
            width = self._num_from_map(map_data, "width")
            tile_w = self._num_from_map(map_data, "tilewidth")
            scale = self._num_from_map(spec, "scale") or 1.0
            if width and tile_w:
                widths.append(width * tile_w * scale)
        return max(widths) if widths else None

    def _stage_feature_count(self, entities: dict[str, Any]) -> int:
        count = 0
        feature_words = (
            "platform",
            "cover",
            "crate",
            "box",
            "barrel",
            "wall",
            "block",
            "obstacle",
            "hazard",
            "pit",
            "water",
            "spike",
            "bridge",
            "ladder",
            "ramp",
        )
        for entity_id, spec in entities.items():
            if not isinstance(spec, dict):
                continue
            if str(spec.get("kind") or "") in {"parallax", "tiled_map"}:
                continue
            text = f"{entity_id} {spec.get('type', '')} {spec.get('role', '')} {spec.get('state', '')}".lower()
            if any(word in text for word in feature_words):
                count += 1
        return count

    def _background_layer_count(self, entities: dict[str, Any]) -> int:
        count = 0
        for entity_id, spec in entities.items():
            if not isinstance(spec, dict):
                continue
            kind = str(spec.get("kind") or "")
            text = self._entity_text(entity_id, spec)
            if kind == "parallax" or any(
                word in text
                for word in (
                    "background",
                    "backdrop",
                    "sky",
                    "cloud",
                    "nuvens",
                    "far",
                    "mid",
                    "near",
                    "foreground",
                    "front",
                )
            ):
                count += 1
        return count

    def _non_cloud_background_count(self, entities: dict[str, Any]) -> int:
        count = 0
        for entity_id, spec in entities.items():
            if not isinstance(spec, dict):
                continue
            kind = str(spec.get("kind") or "")
            text = self._entity_text(entity_id, spec)
            if kind != "parallax" and not any(
                word in text
                for word in ("background", "backdrop", "far", "mid", "near", "foreground", "front")
            ):
                continue
            if any(word in text for word in ("cloud", "nuvens", "sky")) and not any(
                word in text
                for word in (
                    "city",
                    "building",
                    "industrial",
                    "factory",
                    "subway",
                    "forest",
                    "tree",
                    "mountain",
                    "ruin",
                    "desert",
                    "rock",
                    "pipe",
                    "wall",
                )
            ):
                continue
            count += 1
        return count

    def _scene_decor_count(self, entities: dict[str, Any]) -> int:
        count = 0
        decor_words = (
            "decor",
            "prop",
            "landmark",
            "building",
            "city",
            "industrial",
            "factory",
            "subway",
            "ruin",
            "debris",
            "crate",
            "box",
            "barrel",
            "pipe",
            "sign",
            "lamp",
            "light",
            "fence",
            "rail",
            "tree",
            "bush",
            "rock",
            "mountain",
            "wall",
            "foreground",
            "front",
        )
        excluded_words = ("player", "enemy", "bullet", "projectile", "ground")
        for entity_id, spec in entities.items():
            if not isinstance(spec, dict):
                continue
            text = self._entity_text(entity_id, spec)
            if any(word in text for word in excluded_words):
                continue
            if any(word in text for word in decor_words):
                count += 1
        return count

    def _entity_text(self, entity_id: str, spec: dict[str, Any]) -> str:
        parts = [
            entity_id,
            str(spec.get("kind") or ""),
            str(spec.get("type") or ""),
            str(spec.get("role") or ""),
            str(spec.get("asset") or ""),
        ]
        state = spec.get("state")
        if isinstance(state, dict):
            parts.extend(str(v) for v in state.values())
        return " ".join(parts).lower()

    @staticmethod
    def _entities_map(game: dict[str, Any]) -> dict[str, Any]:
        raw = game.get("entities")
        return raw if isinstance(raw, dict) else {}

    @staticmethod
    def _looks_like_sprite_sheet(asset: str) -> bool:
        lowered = asset.lower()
        return any(
            token in lowered
            for token in (
                "spritesheet",
                "sprite_sheet",
                "sprite-sheet",
                "sheet",
                "strip",
                "sliced",
                "tileset",
            )
        )

    @staticmethod
    def _known_frame_size(asset: str) -> tuple[int, int] | None:
        normalized = asset.split("?", 1)[0]
        for suffix, frame in KNOWN_SPRITE_SHEETS.items():
            if normalized.endswith(suffix):
                return frame
        return None

    @classmethod
    def _flatten_text(cls, node: Any) -> str:
        chunks: list[str] = []

        def visit(value: Any) -> None:
            if isinstance(value, str):
                chunks.append(value)
            elif isinstance(value, dict):
                for key, child in value.items():
                    chunks.append(str(key))
                    visit(child)
            elif isinstance(value, list):
                for child in value:
                    visit(child)

        visit(node)
        return " ".join(chunks)

    @classmethod
    def _iter_dicts(cls, node: Any, path: str = "$"):
        if isinstance(node, dict):
            yield path, node
            for key, value in node.items():
                yield from cls._iter_dicts(value, cls._path(path, key))
        elif isinstance(node, list):
            for index, value in enumerate(node):
                yield from cls._iter_dicts(value, f"{path}[{index}]")

    @staticmethod
    def _num_at(value: Any, index: int) -> float | None:
        if (
            isinstance(value, list)
            and len(value) > index
            and isinstance(value[index], (int, float))
        ):
            return float(value[index])
        return None

    @staticmethod
    def _num_from_map(value: Any, key: str) -> float | None:
        if isinstance(value, dict) and isinstance(value.get(key), (int, float)):
            return float(value[key])
        return None


def validate_json_content(
    data: Any,
    builtin_calls: set[str] | None = None,
) -> list[Finding]:
    validator = Validator(data, builtin_calls or load_builtin_calls())
    validator._validate_root()
    validator._walk(validator.root, "$", in_game_logic=False)
    validator._validate_sprite_sheet_usage()
    validator._validate_game_profiles()
    return validator.findings


def load_builtin_calls() -> set[str]:
    repo = Path(__file__).resolve().parents[1]
    calls: set[str] = set(DEFAULT_BUILTIN_CALLS)
    pattern = re.compile(r"case '(@[^']+)'")
    for relative in ("lib/json_ui/interpreter.dart", "lib/games/game_actions.dart"):
        path = repo / relative
        if not path.exists():
            continue
        for match in pattern.finditer(path.read_text(encoding="utf-8")):
            calls.add(match.group(1))
    return calls


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Validate generated JSON-APP files.")
    parser.add_argument("file", type=Path)
    args = parser.parse_args(argv)

    try:
        with args.file.open("r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception as exc:  # noqa: BLE001 - CLI should print parse/open failures.
        print(f"ERROR {args.file}: {exc}", file=sys.stderr)
        return 1

    return Validator(data, load_builtin_calls()).validate()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
