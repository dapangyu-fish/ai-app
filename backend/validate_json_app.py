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

from asset_manifest_metadata import (
    animation_frame_boundary_diagnostics,
    metadata_for_asset_url,
    read_png_size_from_url,
    sprite_frame_size,
)


FORBIDDEN_UI_KEYS = {
    "marginBottom",
    "marginLeft",
    "marginRight",
    "marginTop",
    "shadow",
    "transform",
    "transition",
}

NUMERIC_SCALAR_KEYS = {
    "borderRadius",
    "elevation",
    "flex",
    "fontSize",
    "height",
    "letterSpacing",
    "lineHeight",
    "margin",
    "maxLines",
    "minLines",
    "padding",
    "paddingBottom",
    "paddingH",
    "paddingLeft",
    "paddingRight",
    "paddingTop",
    "paddingV",
    "runSpacing",
    "spacing",
    "strokeWidth",
    "width",
}

UNSUPPORTED_STYLE_KEYS = {
    "margin",
    "padding",
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
    "priority",
    "render.",
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

PRESENTATION_TEXT_KEYS = {
    "caption",
    "description",
    "emptyText",
    "errorText",
    "helperText",
    "hint",
    "label",
    "message",
    "placeholder",
    "subtitle",
    "successText",
    "text",
    "title",
    "tooltip",
}

DEFAULT_BUILTIN_CALLS = {
    # Dotted built-ins are needed by backend-only registry validation. In the
    # Docker image the Dart sources may not be present, so load_builtin_calls()
    # cannot always discover them dynamically.
    "@animated_sprite.effect",
    "@animated_sprite.set_animation",
    "@audio.pause",
    "@audio.play",
    "@audio.resume",
    "@audio.set_volume",
    "@audio.stop",
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
    "@matrix.can_place",
    "@matrix.clear",
    "@matrix.clear_full_rows",
    "@matrix.place",
    "@matrix.random_item",
    "@pixel.add_velocity",
    "@pixel.set_position",
    "@pixel.set_velocity",
    "@platformer.backend",
    "@polyomino.rotate",
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
    "@tiled.remove_object",
    "@tiled.spawn_objects",
    "@tiled.spawn_objects_near",
    "@value_grid.can_move",
    "@value_grid.slide_merge",
    "@value_grid.spawn",
}

DEFAULT_ICON_NAMES = {
    "account",
    "ac_unit",
    "add",
    "air",
    "analytics",
    "attachment",
    "audio",
    "back",
    "bathroom",
    "bathtub",
    "bed",
    "blinds",
    "block",
    "bluetooth",
    "bolt",
    "bookmark",
    "bookmark_outline",
    "calendar",
    "camera",
    "chair",
    "chevron_right",
    "chat",
    "check",
    "check_circle",
    "cleaning_services",
    "clock",
    "close",
    "code",
    "collapse",
    "cooking",
    "copy",
    "curtains",
    "dashboard",
    "dark_mode",
    "delete",
    "devices",
    "door_front",
    "download",
    "edit",
    "electric_bolt",
    "email",
    "emoji",
    "error",
    "expand",
    "favorite",
    "favorite_outline",
    "file",
    "filter",
    "fingerprint",
    "folder",
    "forward",
    "fullscreen",
    "garage",
    "globe",
    "grid",
    "health_and_safety",
    "help",
    "history",
    "home",
    "image",
    "info",
    "insights",
    "inventory_2",
    "key",
    "king_bed",
    "kitchen",
    "leaderboard",
    "left",
    "light_mode",
    "lightbulb",
    "link",
    "list",
    "local_laundry_service",
    "local_pharmacy",
    "location",
    "lock",
    "login",
    "logout",
    "map",
    "medication",
    "menu_book",
    "menu",
    "message",
    "monitor_heart",
    "more",
    "more_horiz",
    "notes",
    "notification",
    "palette",
    "paste",
    "pause",
    "payment",
    "payments",
    "people",
    "person",
    "phone",
    "photo",
    "play",
    "power",
    "power_settings_new",
    "print",
    "qr_code",
    "receipt",
    "redo",
    "refresh",
    "remove",
    "replay",
    "restart",
    "restaurant",
    "right",
    "room_preferences",
    "router",
    "save",
    "schedule",
    "search",
    "security",
    "send",
    "sensors",
    "settings",
    "share",
    "shopping_cart",
    "single_bed",
    "sort",
    "spa",
    "star",
    "star_outline",
    "stop",
    "sync",
    "tag",
    "thermostat",
    "thermostat_auto",
    "theaters",
    "timeline",
    "today",
    "trophy",
    "tune",
    "tv",
    "undo",
    "unlock",
    "up",
    "upload",
    "video",
    "visibility",
    "visibility_off",
    "warning",
    "warning_amber",
    "water_drop",
    "wb_sunny",
    "weekend",
    "wifi",
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
        self.allowed_icon_names = load_allowed_icon_names()
        self.findings: list[Finding] = []
        self.dependencies: set[str] = set()
        self.self_package_names: set[str] = set()
        self.flame_games: list[tuple[str, dict[str, Any]]] = []
        self.rendered_flame_games: list[tuple[str, dict[str, Any]]] = []
        self.sprite_boundary_error_keys: set[tuple[str, int, int, int]] = set()

    def error(self, path: str, message: str) -> None:
        self.findings.append(Finding("ERROR", path, message))

    def warn(self, path: str, message: str) -> None:
        self.findings.append(Finding("WARN", path, message))

    def validate(self) -> int:
        self._validate_root()
        self._walk(self.root, "$", in_game_logic=False)
        self._validate_flame_game_mounts()
        self._validate_presentation_text_slots()
        self._validate_sprite_sheet_usage()
        self._validate_game_profiles()
        self._validate_game_input()
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
                if self._is_rendered_widget_path(path):
                    self.rendered_flame_games.append((path, node))
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

        if "body" in node and self._is_screen_or_tab_path(path):
            self.error(
                self._path(path, "body"),
                "screen/tab content must use children:[...], not body; older clients render body-only screens blank",
            )

        if node_type == "container" and "style" in node:
            self.error(self._path(path, "style"), "container has no style field; flatten style properties")

        if node_type == "ref":
            self._validate_ref_widget(node, path)

        if self._is_ui_path(path):
            self._validate_icon_fields(node, path)

            for key in node.keys():
                if key in FORBIDDEN_UI_KEYS and not self._is_allowed_non_ui_key(node, key):
                    self.error(self._path(path, key), f"unsupported web/CSS-like field: {key}")

            for key in NUMERIC_SCALAR_KEYS:
                if key in node and not self._is_number(node[key]):
                    self.error(self._path(path, key), f"{key} must be a number, not {type(node[key]).__name__}")

            style = node.get("style")
            if isinstance(style, dict):
                for key in UNSUPPORTED_STYLE_KEYS:
                    if key in style:
                        self.error(self._path(self._path(path, "style"), key), f"style.{key} is unsupported; use widget-level spacing or spacer")
                for key in NUMERIC_SCALAR_KEYS:
                    if key in style and not self._is_number(style[key]):
                        self.error(self._path(self._path(path, "style"), key), f"style.{key} must be a number, not {type(style[key]).__name__}")

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

    def _validate_ref_widget(self, node: dict[str, Any], path: str) -> None:
        if node.get("from") != "game-controls" or node.get("widget") != "psJoystickGamepad":
            return
        props = node.get("props")
        if props is None:
            return
        if not isinstance(props, dict):
            self.error(self._path(path, "props"), "game-controls.psJoystickGamepad props must be an object")
            return
        allowed = {
            "moveInput",
            "moveEndInput",
            "jumpInput",
            "jumpEndInput",
            "attackInput",
            "height",
            "backgroundColor",
        }
        for key in props.keys():
            if key in allowed:
                continue
            self.error(
                self._path(self._path(path, "props"), key),
                "unsupported psJoystickGamepad prop; this component only emits input and does not render game/content children",
            )
        if isinstance(props.get("game"), dict) and props["game"].get("type") == "flame_game":
            self.error(
                self._path(self._path(path, "props"), "game"),
                "flame_game nested inside psJoystickGamepad props is ignored at runtime; render flame_game as a real UI node and place psJoystickGamepad as a sibling/overlay input control",
            )

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

        if call == "@set" and self._contains_op_args_expression(args.get("value")):
            self.error(
                self._path(path, "args.value"),
                "@set value uses unsupported {op,args} expression shape; use standard jsonlogic such as {'if': [...]}",
            )

        if call == "@entity.set":
            self._validate_entity_set(args, path)
        elif call == "@entity.add":
            self._validate_entity_add(args, path)

    def _validate_icon_fields(self, node: dict[str, Any], path: str) -> None:
        node_type = node.get("type")
        if node_type == "icon" and "name" in node:
            self._validate_icon_name(node.get("name"), self._path(path, "name"))

        if node_type in {"button", "chip"} and "icon" in node:
            self._validate_icon_name(node.get("icon"), self._path(path, "icon"))

        if node_type in {"input", "dropdown", "date_picker", "time_picker"}:
            for key in ("prefixIcon", "suffixIcon"):
                if key in node:
                    self._validate_icon_name(node.get(key), self._path(path, key))

        if node_type == "app_bar" or self._is_app_bar_path(path):
            leading = node.get("leading")
            if isinstance(leading, dict) and "icon" in leading:
                self._validate_icon_name(
                    leading.get("icon"),
                    self._path(self._path(path, "leading"), "icon"),
                )
            actions = node.get("actions")
            if isinstance(actions, list):
                for index, action in enumerate(actions):
                    if isinstance(action, dict) and "icon" in action:
                        self._validate_icon_name(
                            action.get("icon"),
                            self._path(f"{self._path(path, 'actions')}[{index}]", "icon"),
                        )

        if self._is_tab_path(path) and "icon" in node:
            self._validate_icon_name(node.get("icon"), self._path(path, "icon"))

    def _validate_icon_name(self, value: Any, path: str) -> None:
        if not isinstance(value, str):
            return
        name = value.strip()
        if not name or not self._is_static_icon_name(name):
            return
        if name not in self.allowed_icon_names:
            self.error(path, f"unknown icon name: {name}; register it in IconRegistry or use an allowed icon")

    def _validate_flame_game_mounts(self) -> None:
        if not self.flame_games:
            return
        hidden_paths: list[str] = []
        for path, _game in self.flame_games:
            if ".props." in path or ".props[" in path:
                hidden_paths.append(path)
                self.error(
                    path,
                    "flame_game is inside a props payload, so the widget tree will not mount it; put flame_game directly under a renderable ui.screens child/body/stack node",
                )
        if hidden_paths and not self.rendered_flame_games:
            self.error(
                "$.ui.screens",
                "game JSON defines flame_game only in non-rendered props; the app will open blank because no game widget is mounted",
            )

    @staticmethod
    def _is_rendered_widget_path(path: str) -> bool:
        if not path.startswith("$.ui.screens["):
            return False
        # `props` is data passed into another component template. It is not a
        # generic child slot, so widgets stored there are ignored unless the
        # template explicitly renders them.
        return ".props." not in path and ".props[" not in path

    @staticmethod
    def _is_screen_or_tab_path(path: str) -> bool:
        return re.fullmatch(r"\$\.ui\.screens\[\d+\](?:\.tabs\[\d+\])?", path) is not None

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
    def _is_ui_path(path: str) -> bool:
        return path == "$.ui" or path.startswith("$.ui.")

    @staticmethod
    def _is_app_bar_path(path: str) -> bool:
        return path.endswith(".appBar") or path.endswith(".app_bar") or path.endswith(".appBar]")

    @staticmethod
    def _is_tab_path(path: str) -> bool:
        return bool(re.search(r"\.tabs\[\d+\]$", path))

    @staticmethod
    def _is_static_icon_name(value: str) -> bool:
        return re.fullmatch(r"[a-z][a-z0-9_]*", value) is not None

    @classmethod
    def _contains_op_args_expression(cls, value: Any) -> bool:
        if isinstance(value, dict):
            if set(value.keys()) == {"op", "args"} and isinstance(value.get("op"), str):
                return True
            return any(cls._contains_op_args_expression(child) for child in value.values())
        if isinstance(value, list):
            return any(cls._contains_op_args_expression(child) for child in value)
        return False

    @staticmethod
    def _is_number(value: Any) -> bool:
        return isinstance(value, (int, float)) and not isinstance(value, bool)

    @staticmethod
    def _path(base: str, key: Any) -> str:
        if isinstance(key, str) and key.replace("_", "").isalnum():
            return f"{base}.{key}"
        return f"{base}[{key!r}]"

    def _validate_sprite_sheet_usage(self) -> None:
        render_box_offenders: list[dict[str, str]] = []
        for path, node in self._iter_dicts(self.root):
            kind = node.get("kind")
            if kind is not None and not isinstance(kind, str):
                continue
            if kind not in {"sprite", "animated_sprite"}:
                continue
            render = node.get("render")
            # 图元(sprite/animated_sprite)上挂带可见 shape 的 render 块 = 兜底色块。
            # 引擎只在贴图未加载成功时画它(game_entity.dart SpriteEntity.render:
            # `if (img == null) drawShape(renderConfig)`)。一旦显示出来就是"幽灵方块"
            # ——多半是 debug/占位残留,正式角色不该带它。render 仅含 asset/flip_x 不算。
            # 收集起来在循环结束后汇总:玩家单独报 ERROR,其余合并成一条 WARN(避免刷屏)。
            if isinstance(render, dict) and isinstance(render.get("shape"), str) and render.get(
                "shape"
            ) in {"rect", "circle", "rounded_rect", "round_rect", "oval", "square"}:
                entity_id = path.rsplit(".", 1)[-1]
                render_box_offenders.append(
                    {
                        "path": self._path(path, "render"),
                        "kind": str(kind),
                        "shape": str(render.get("shape")),
                        "id": entity_id,
                        "is_player": "1" if entity_id == "player" else "",
                    }
                )
            asset = node.get("asset")
            if not asset and isinstance(render, dict):
                asset = render.get("asset")
            asset_text = str(asset or "")
            asset_meta = self._asset_metadata(asset_text)
            is_sheet = self._looks_like_sprite_sheet(asset_text) or self._is_sheet_metadata(asset_meta)
            if not asset_text or (not is_sheet and kind != "animated_sprite"):
                continue
            known_frame = self._known_frame_size(asset_text, asset_meta)
            has_src = isinstance(node.get("src"), list) and len(node.get("src") or []) >= 4
            if kind == "sprite" and is_sheet and not has_src:
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
                if is_sheet and not isinstance(animations, dict) and (
                    (frames is None)
                    or (isinstance(frames, (int, float)) and frames <= 1)
                ):
                    self.error(
                        self._path(path, "asset"),
                        "animated sprite sheet requires frames/frame_size/frames_per_row or animations",
                    )
                self._validate_animation_frame_spec(
                    path,
                    asset_text,
                    frame_size,
                    frames,
                    node.get("frames_per_row"),
                    node.get("start_frame"),
                    asset_meta=asset_meta,
                    is_sheet=is_sheet,
                )
                if isinstance(animations, dict):
                    animations_path = self._path(path, "animations")
                    for name, spec in animations.items():
                        if not isinstance(spec, dict):
                            continue
                        anim_asset = str(spec.get("asset") or asset_text)
                        anim_meta = self._asset_metadata(anim_asset)
                        anim_is_sheet = self._looks_like_sprite_sheet(anim_asset) or self._is_sheet_metadata(anim_meta)
                        self._validate_animation_frame_spec(
                            self._path(animations_path, name),
                            anim_asset,
                            spec.get("frame_size"),
                            spec.get("frames"),
                            spec.get("frames_per_row"),
                            spec.get("start_frame"),
                            asset_meta=anim_meta,
                            is_sheet=anim_is_sheet,
                        )

        # ── 汇总 render 兜底框(check C):玩家单独 ERROR,其余合并成一条 WARN ──
        players = [o for o in render_box_offenders if o["is_player"]]
        others = [o for o in render_box_offenders if not o["is_player"]]
        for o in players:
            self.error(
                o["path"],
                f"player {o['kind']} carries a render fallback box (shape:{o['shape']}). When the art "
                "fails to load the hero renders as a ghost rectangle (the #1 'player is just a box' "
                "bug). Remove 'render' from the player entity.",
            )
        if others:
            ids = ", ".join(o["id"] for o in others)
            self.warn(
                others[0]["path"],
                f"{len(others)} image-backed entities carry a render fallback box (only drawn when the "
                f"art fails to load, then look like ghost rectangles): {ids}. Remove 'render' from "
                "sprite/animated_sprite entities; use kind:'pixel' only for intentional solid boxes.",
            )

    def _validate_animation_frame_spec(
        self,
        path: str,
        asset_text: str,
        frame_size: Any,
        frames_value: Any,
        frames_per_row_value: Any,
        start_frame_value: Any,
        *,
        asset_meta: dict[str, Any] | None,
        is_sheet: bool,
    ) -> None:
        frame_w = self._num_at(frame_size, 0)
        frame_h = self._num_at(frame_size, 1)
        expected_frame = self._known_frame_size(asset_text, asset_meta)
        image_w, image_h = self._image_size(asset_meta)
        if (image_w is None or image_h is None) and asset_text:
            remote_size = read_png_size_from_url(asset_text)
            if remote_size:
                image_w, image_h = remote_size
        sprite = asset_meta.get("sprite") if isinstance(asset_meta, dict) else None
        sprite_kind = str(sprite.get("kind") or "") if isinstance(sprite, dict) else ""

        if expected_frame is not None and sprite_kind != "single":
            expected_w, expected_h = expected_frame
            if frame_w is None or frame_h is None:
                if is_sheet:
                    self.error(
                        self._path(path, "frame_size"),
                        f"sprite sheet animation must declare frame_size [{expected_w}, {expected_h}] from asset manifest metadata",
                    )
            elif abs(frame_w - expected_w) > 1 or abs(frame_h - expected_h) > 1:
                self.error(
                    self._path(path, "frame_size"),
                    f"animated sprite frame_size must match manifest frame ({expected_w}x{expected_h}); do not guess sprite sheet slicing",
                )

        if frame_w is None or frame_h is None:
            return
        if frame_w <= 0 or frame_h <= 0:
            self.error(self._path(path, "frame_size"), "frame_size values must be positive")
            return

        frames = self._positive_int(frames_value) or 1
        start_frame = self._non_negative_int(start_frame_value) or 0
        frames_per_row = self._positive_int(frames_per_row_value)

        if image_w and image_h:
            if frame_w > image_w + 1 or frame_h > image_h + 1:
                self.error(
                    self._path(path, "frame_size"),
                    f"frame_size {frame_w:g}x{frame_h:g} exceeds image size {image_w}x{image_h}",
                )
                return

            if not is_sheet and sprite_kind == "single" and frames <= 1:
                if abs(frame_w - image_w) > 1 or abs(frame_h - image_h) > 1:
                    mismatch = max(abs(frame_w - image_w) / image_w, abs(frame_h - image_h) / image_h)
                    target = self.error if mismatch >= 0.25 else self.warn
                    target(
                        self._path(path, "frame_size"),
                        f"single-frame image is {image_w}x{image_h}; frame_size should normally match the image unless the app intentionally crops transparent padding",
                    )
                return

            if frames_per_row is None and frame_w:
                frames_per_row = int(image_w // frame_w)
            if not frames_per_row:
                return
            if frames_per_row * frame_w > image_w + 1:
                self.error(
                    self._path(path, "frames_per_row"),
                    f"frames_per_row * frame_width exceeds image width ({frames_per_row} * {frame_w:g} > {image_w})",
                )
                return
            last_frame = start_frame + frames - 1
            required_rows = (last_frame // frames_per_row) + 1
            if required_rows * frame_h > image_h + 1:
                self.error(
                    self._path(path, "frames"),
                    f"animation reads outside image: start_frame={start_frame}, frames={frames}, frames_per_row={frames_per_row}, frame_height={frame_h:g}, image_height={image_h}",
                )
                return
            if (
                asset_text
                and frames > 1
                and frame_w.is_integer()
                and frame_h.is_integer()
                and frames_per_row
            ):
                diagnostics = animation_frame_boundary_diagnostics(
                    asset_text,
                    frame_width=int(frame_w),
                    frame_height=int(frame_h),
                    frames_per_row=frames_per_row,
                    frames=frames,
                    start_frame=start_frame,
                )
                self._validate_frame_boundary_diagnostics(
                    path,
                    asset_text,
                    int(frame_w),
                    int(frame_h),
                    frames_per_row,
                    diagnostics,
                )

    def _validate_frame_boundary_diagnostics(
        self,
        path: str,
        asset_text: str,
        frame_w: int,
        frame_h: int,
        frames_per_row: int,
        diagnostics: dict[str, Any] | None,
    ) -> None:
        if not diagnostics:
            return
        current = diagnostics.get("current")
        if not isinstance(current, dict):
            return
        cut_ratio = self._num_from_map(current, "cutRatio") or 0.0
        cut = int(current.get("cut") or 0)
        checked = int(current.get("checked") or 0)
        if cut < 2 or checked < 3 or cut_ratio < 0.25:
            return
        key = (asset_text.split("?", 1)[0], frame_w, frame_h, frames_per_row)
        if key in self.sprite_boundary_error_keys:
            return
        self.sprite_boundary_error_keys.add(key)
        self.error(
            self._path(path, "frame_size"),
            f"declared sprite grid cuts through opaque pixels at {cut}/{checked} internal frame boundaries; do not guess sprite sheet slicing",
        )

    def _validate_presentation_text_slots(self) -> None:
        for path, node in self._iter_dicts(self.root):
            for key, value in node.items():
                if not self._is_presentation_slot(node, key):
                    continue
                if self._is_raw_jsonlogic(value):
                    self.error(
                        self._path(path, key),
                        "presentation text must be a string or string interpolation, not raw jsonlogic; use e.g. \"Score: {{ params.score }}\"",
                    )
                elif isinstance(value, (dict, list)):
                    self.error(
                        self._path(path, key),
                        "presentation text must be a string or string interpolation, not a structured value; compute state first and display \"{{ global.someLabel }}\"",
                    )

    @staticmethod
    def _asset_metadata(asset: str) -> dict[str, Any] | None:
        if not asset:
            return None
        return metadata_for_asset_url(asset)

    @staticmethod
    def _is_sheet_metadata(asset_meta: dict[str, Any] | None) -> bool:
        sprite = asset_meta.get("sprite") if isinstance(asset_meta, dict) else None
        if not isinstance(sprite, dict):
            return False
        return str(sprite.get("kind") or "") in {"grid", "strip", "atlas", "unknown_sheet"}

    @staticmethod
    def _image_size(asset_meta: dict[str, Any] | None) -> tuple[int | None, int | None]:
        image = asset_meta.get("image") if isinstance(asset_meta, dict) else None
        if not isinstance(image, dict):
            return None, None
        width = image.get("width")
        height = image.get("height")
        return (
            int(width) if isinstance(width, int) and width > 0 else None,
            int(height) if isinstance(height, int) and height > 0 else None,
        )

    @staticmethod
    def _positive_int(value: Any) -> int | None:
        if isinstance(value, bool):
            return None
        if isinstance(value, int) and value > 0:
            return value
        if isinstance(value, float) and value.is_integer() and value > 0:
            return int(value)
        return None

    @staticmethod
    def _non_negative_int(value: Any) -> int | None:
        if isinstance(value, bool):
            return None
        if isinstance(value, int) and value >= 0:
            return value
        if isinstance(value, float) and value.is_integer() and value >= 0:
            return int(value)
        return None

    # ── 摇杆松手停不下来(moveEndInput 接错 handler) ─────────────────────
    # game-controls 的 psJoystickGamepad 用 props.moveInput / moveEndInput 把
    # 拖动 / 松手分别路由到 flame_game.input 里的命名 handler。
    #   moveInput   handler 通常写 move_dir = event.x(模拟量)
    #   松手时控件用 event.x=0 再触发 moveEndInput
    # 只有当 moveEndInput 指向的 handler 会把 move 变量归零,角色才会停:
    #   ✅ moveEndInput == moveInput      → 松手 event.x=0 → move_dir=0(demo 的做法)
    #   ✅ moveEndInput handler 顶层无条件 move_dir=0
    #   ❌ moveEndInput 指向别的 handler(如 move_up,只在 ==±1 时归零)→ 松手不停
    # 注:此前误把 move_up 的 ±1 内容当 bug——它在 demo 里是摆设,真凶是 moveEndInput 接错。
    def _validate_game_input(self) -> None:
        if not self.flame_games:
            return
        handlers: dict[str, Any] = {}
        for _, game in self.flame_games:
            inp = game.get("input")
            if isinstance(inp, dict):
                for key, value in inp.items():
                    if isinstance(value, list):
                        handlers.setdefault(key, value)
        if not handlers:
            return
        for path, node in self._iter_dicts(self.root):
            move_input = node.get("moveInput")
            move_end = node.get("moveEndInput")
            if not isinstance(move_input, str) or not isinstance(move_end, str):
                continue
            if move_end == move_input:
                continue  # 松手复用 move handler,event.x=0 会归零,正确
            move_steps = handlers.get(move_input)
            if not isinstance(move_steps, list):
                continue
            analog_vars = self._vars_assigned_from_event_x(move_steps)
            if not analog_vars:
                continue
            end_steps = handlers.get(move_end)
            for var in sorted(analog_vars):
                if isinstance(end_steps, list) and self._has_top_level_zero_set(end_steps, var):
                    continue
                self.error(
                    self._path(path, "moveEndInput"),
                    f"joystick moveEndInput='{move_end}' will not stop the player: moveInput "
                    f"('{move_input}') drives '{var}' from analog event.x, but release routes to "
                    f"'{move_end}', which never sets '{var}'=0 unconditionally. The character keeps "
                    f"moving after the stick is released. Set moveEndInput='{move_input}' (release "
                    f"then sends event.x=0 → '{var}'=0), or make '{move_end}' set '{var}'=0 unconditionally.",
                )

    @classmethod
    def _iter_call_nodes(cls, steps: Any):
        """遍历 steps 树里所有 {call, args, ...} 节点。"""
        stack = [steps]
        while stack:
            cur = stack.pop()
            if isinstance(cur, dict):
                if "call" in cur:
                    yield cur
                stack.extend(cur.values())
            elif isinstance(cur, list):
                stack.extend(cur)

    @classmethod
    def _refs_event_x(cls, value: Any) -> bool:
        if isinstance(value, dict):
            if value.get("var") == "event.x":
                return True
            return any(cls._refs_event_x(v) for v in value.values())
        if isinstance(value, list):
            return any(cls._refs_event_x(v) for v in value)
        return False

    @classmethod
    def _vars_assigned_from_event_x(cls, steps: Any) -> set[str]:
        out: set[str] = set()
        for node in cls._iter_call_nodes(steps):
            if node.get("call") != "@set":
                continue
            args = node.get("args")
            if isinstance(args, dict) and isinstance(args.get("var"), str) and cls._refs_event_x(args.get("value")):
                out.add(args["var"])
        return out

    @staticmethod
    def _is_zero_value(value: Any) -> bool:
        return value in (0, 0.0, "0")

    @classmethod
    def _has_top_level_zero_set(cls, steps: Any, var: str) -> bool:
        """steps 顶层(不在 @if 的 then/else 里)是否无条件把 var 设为 0。"""
        if not isinstance(steps, list):
            return False
        for node in steps:
            if not isinstance(node, dict) or node.get("call") != "@set":
                continue
            args = node.get("args")
            if isinstance(args, dict) and args.get("var") == var and cls._is_zero_value(args.get("value")):
                return True
        return False

    def _validate_game_profiles(self) -> None:
        if not self._needs_run_and_gun_profile():
            return
        if not self.rendered_flame_games:
            self.error("$", "run-and-gun / side-scrolling action games must render flame_game in ui.screens")
            return
        for path, game in self.rendered_flame_games:
            self._validate_run_and_gun_game(path, game)

    def _validate_run_and_gun_game(self, path: str, game: dict[str, Any]) -> None:
        # leap_platformer 会让角色自动爬上台阶/斜坡(走到落差处自动抬腿上去)。
        # 这对横版**射击**(魂斗罗类,期望硬碰撞:踩不上去就是踩不上去)是错的体感。
        # run-and-gun 应使用 aabb_platformer。
        physics = game.get("physics")
        if isinstance(physics, dict) and str(physics.get("engine") or "").strip() == "leap_platformer":
            self.error(
                self._path(path, "physics.engine"),
                "run-and-gun game should not use leap_platformer (it auto-climbs steps/slopes, "
                "which feels wrong for hard-collision shooters); use engine:'aabb_platformer'.",
            )

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
        player = self._player_entity(entities)
        player_h = self._entity_height(player)
        if viewport_h and player_h and player_h < viewport_h * 0.12:
            self.error(
                self._path(path, "entities.player.size"),
                "run-and-gun player is visually too small for the viewport; target player height should be at least 12% of viewport height",
            )

        max_right = self._max_entity_right(entities)
        map_width = self._max_tiled_map_width(entities)
        min_stage_viewports = 5
        if viewport_w and map_width is None and max_right <= viewport_w * min_stage_viewports:
            self.error(
                self._path(path, "entities"),
                f"run-and-gun game needs a horizontal stage at least {min_stage_viewports} viewport widths wide, or a tiled_map with known map_data",
            )
        if viewport_w and map_width is not None and map_width < viewport_w * min_stage_viewports:
            self.error(
                self._path(path, "entities"),
                f"run-and-gun tiled map is too short; map width should be at least {min_stage_viewports} viewport widths",
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
        if self._asset_scene_decor_count(entities) < 3:
            self.error(
                self._path(path, "entities"),
                "run-and-gun scene dressing must use real asset/tile visuals, not only pixel rectangles; add at least 3 visible props/landmarks from the selected asset manifest",
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
        for_each_count = self._call_count(game, "@for_each_entity")
        if for_each_count > 6:
            self.error(
                self._path(path, "frame"),
                f"run-and-gun frame logic has too many entity scans ({for_each_count}); use fewer loops, proximity spawning, or object pools to avoid late-game stutter",
            )

        static_enemy_count = self._static_enemy_entity_count(entities)
        enemy_object_count = self._tiled_enemy_object_count(entities)
        if static_enemy_count + enemy_object_count < 8:
            self.error(
                self._path(path, "entities"),
                "run-and-gun game needs a real encounter plan: add at least 8 enemy spawn points/entities across the stage",
            )
        if viewport_w:
            early_enemy_count = self._static_enemy_entity_count(
                entities,
                max_x=viewport_w * 2,
            ) + self._tiled_enemy_object_count(entities, max_x=viewport_w * 2)
        else:
            early_enemy_count = 0
        if viewport_w and early_enemy_count < 2:
            self.error(
                self._path(path, "entities"),
                "run-and-gun game needs at least 2 enemy spawn points in the first two viewports; do not hide all action near the end",
            )

        if self._uses_tiled_enemy_spawning(game) and not self._tiled_enemy_spawning_has_templates(game):
            self.error(
                self._path(path, "frame"),
                "run-and-gun tiled enemy spawning must provide templates with kind/asset/frame_size/state; object points alone do not define visible enemies",
            )
        if not self._has_enemy_lifecycle(game):
            self.error(
                self._path(path, "frame"),
                "run-and-gun enemies need movement and hit/death lifecycle: update enemy behavior, collide projectiles with enemy_, despawn or score on hit",
            )

        if self._uses_projectiles(game) and not self._has_projectile_lifecycle(game):
            self.error(
                self._path(path, "frame"),
                "run-and-gun projectiles need a complete lifecycle: spawn, move, collide with enemies, despawn on hit, and despawn offscreen",
            )
        if self._uses_projectile_counter(game) and self._projectile_counter_release_paths(game) < 2:
            self.error(
                self._path(path, "frame"),
                "projectile counters must be released on both hit and offscreen/timeout paths; otherwise shooting eventually locks up",
            )
        if self._uses_projectiles(game) and not self._has_vertical_aim(game):
            self.error(
                self._path(path, "input"),
                "run-and-gun shooting must support aim_y/upward fire (or an aim vector), not only facing-left/right bullets",
            )
        if self._contains_call(game, "@platformer.step") and not self._handles_platformer_hazard(game):
            self.error(
                self._path(path, "frame"),
                "run-and-gun platformer.step sets hazard/outOfBounds; frame logic must consume it and trigger death, respawn or game_over",
            )

    def _needs_run_and_gun_profile(self) -> bool:
        # Profile detection should be driven by semantic app text, not by hosted
        # asset URLs. Otherwise merely using a run-n-gun asset pack preview in a
        # non-game app would force game-specific validation.
        text = re.sub(r"https?://\S+", " ", self._flatten_text(self.root)).lower()
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
            "横版射击",
            "横版动作",
            "平台射击",
        )
        return any(k in text for k in keywords)

    def _static_enemy_entity_count(
        self,
        entities: dict[str, Any],
        *,
        max_x: float | None = None,
    ) -> int:
        count = 0
        for entity_id, spec in entities.items():
            if not isinstance(spec, dict):
                continue
            text = self._entity_text(entity_id, spec)
            if "enemy" not in text or str(spec.get("kind") or "") in {"tiled_map"}:
                continue
            if max_x is not None:
                x = self._num_at(spec.get("position"), 0)
                if x is None:
                    x = self._num_from_map(spec, "x")
                if x is None or x > max_x:
                    continue
            count += 1
        return count

    def _tiled_enemy_object_count(
        self,
        entities: dict[str, Any],
        *,
        max_x: float | None = None,
    ) -> int:
        count = 0
        for spec in entities.values():
            if not isinstance(spec, dict) or spec.get("kind") != "tiled_map":
                continue
            map_data = spec.get("map_data")
            if not isinstance(map_data, dict):
                continue
            scale = self._num_from_map(spec, "scale") or 1.0
            for layer in map_data.get("layers") or []:
                if not isinstance(layer, dict) or layer.get("type") != "objectgroup":
                    continue
                layer_name = str(layer.get("name") or "").lower()
                for obj in layer.get("objects") or []:
                    if not isinstance(obj, dict):
                        continue
                    obj_text = f"{layer_name} {obj.get('name', '')} {obj.get('type', '')}".lower()
                    if "enemy" not in obj_text:
                        continue
                    x = self._num_from_map(obj, "x")
                    if max_x is not None and x is not None and x * scale > max_x:
                        continue
                    count += 1
        return count

    def _uses_tiled_enemy_spawning(self, game: dict[str, Any]) -> bool:
        for _, node in self._iter_dicts(game):
            if node.get("call") not in {"@tiled.spawn_objects", "@tiled.spawn_objects_near"}:
                continue
            args = node.get("args")
            if not isinstance(args, dict):
                continue
            text = self._flatten_text(args).lower()
            if "enemy" in text:
                return True
        return False

    def _tiled_enemy_spawning_has_templates(self, game: dict[str, Any]) -> bool:
        checked = False
        for _, node in self._iter_dicts(game):
            if node.get("call") not in {"@tiled.spawn_objects", "@tiled.spawn_objects_near"}:
                continue
            args = node.get("args")
            if not isinstance(args, dict):
                continue
            text = self._flatten_text(args).lower()
            if "enemy" not in text:
                continue
            checked = True
            templates = args.get("templates")
            if not isinstance(templates, dict) or not templates:
                return False
            if not self._spawn_templates_have_render_specs(templates):
                return False
        return checked

    def _spawn_templates_have_render_specs(self, templates: dict[str, Any]) -> bool:
        for raw in templates.values():
            if not isinstance(raw, dict):
                continue
            kind = str(raw.get("kind") or "")
            asset = raw.get("asset")
            if kind in {"sprite", "animated_sprite"} and isinstance(asset, str) and asset:
                if kind == "animated_sprite":
                    frame_size = raw.get("frame_size")
                    if not (isinstance(frame_size, list) and len(frame_size) >= 2):
                        continue
                return True
        return False

    def _has_enemy_lifecycle(self, game: dict[str, Any]) -> bool:
        text = self._flatten_text(game).lower()
        has_enemy_loop = "where_prefix enemy_" in text or "where_prefix enemy" in text
        has_enemy_collision = "enemy_" in text and "@collision.first" in text
        has_enemy_death = "enemy_" in text and "@despawn" in text
        has_enemy_motion = "enemy_" in text and any(
            token in text
            for token in (
                "state.dir",
                "patrol_min",
                "patrol_max",
                "enemy_speed",
                "_edir",
                '"field" "x"',
                "field x",
            )
        )
        return has_enemy_collision and has_enemy_death and (has_enemy_loop or has_enemy_motion)

    def _uses_projectiles(self, game: dict[str, Any]) -> bool:
        text = self._flatten_text(game).lower()
        return any(token in text for token in ("bullet", "projectile", "shot_", "laser"))

    def _has_projectile_lifecycle(self, game: dict[str, Any]) -> bool:
        text = self._flatten_text(game).lower()
        if not self._uses_projectiles(game):
            return True
        has_spawn = "@spawn" in text and any(token in text for token in ("bullet", "projectile", "shot_"))
        has_move = "@entity.add" in text and any(token in text for token in ("loop.entity.state.vx", "bullet_speed", "projectile_speed", "shot_speed"))
        has_hit = "@collision.first" in text and "enemy_" in text
        has_despawn = "@despawn" in text and any(token in text for token in ("bullet", "_bid", "projectile", "shot_"))
        has_offscreen = any(token in text for token in ("offscreen", "despawn_distance", "player.x", "world.width", "camerax", "camera_x"))
        return has_spawn and has_move and has_hit and has_despawn and has_offscreen

    def _uses_projectile_counter(self, game: dict[str, Any]) -> bool:
        text = self._flatten_text(game).lower()
        return any(
            token in text
            for token in ("bullet_count", "projectile_count", "shot_count", "active_bullets", "active_projectiles")
        )

    def _projectile_counter_release_paths(self, game: dict[str, Any]) -> int:
        count = 0
        counter_names = (
            "bullet_count",
            "projectile_count",
            "shot_count",
            "active_bullets",
            "active_projectiles",
        )
        for _, node in self._iter_dicts(game):
            if node.get("call") != "@set":
                continue
            args = node.get("args")
            if not isinstance(args, dict):
                continue
            var_name = str(args.get("var") or "").lower()
            if not any(name in var_name for name in counter_names):
                continue
            value_text = self._flatten_text(args.get("value")).lower()
            if "-" in value_text and any(name in value_text for name in counter_names):
                count += 1
        return count

    def _has_vertical_aim(self, game: dict[str, Any]) -> bool:
        text = self._flatten_text(game).lower()
        return any(
            token in text
            for token in (
                "aim_y",
                "aimy",
                "aim_vector",
                "aimvector",
                "shoot_y",
                "shot_y",
                "bullet_vy",
                "projectile_vy",
                "vertical_aim",
                "up_fire",
                "fire_up",
                "8way",
                "eight_way",
                "event.y",
            )
        )

    def _handles_platformer_hazard(self, game: dict[str, Any]) -> bool:
        text = self._flatten_text(game).lower()
        has_signal = "hazard" in text or "outofbounds" in text or "out_of_bounds" in text
        has_response = any(token in text for token in ("@game_over", "@platformer.respawn", "respawn", "lives"))
        return has_signal and has_response

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

    def _asset_scene_decor_count(self, entities: dict[str, Any]) -> int:
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
        excluded_words = ("player", "enemy", "bullet", "projectile", "ground", "background")
        for entity_id, spec in entities.items():
            if not isinstance(spec, dict):
                continue
            asset = str(spec.get("asset") or "")
            if not asset:
                render = spec.get("render")
                if isinstance(render, dict):
                    asset = str(render.get("asset") or "")
            if not asset:
                continue
            text = self._entity_text(entity_id, spec)
            if any(word in text for word in excluded_words):
                continue
            if any(word in text for word in decor_words):
                count += 1
        return count

    @staticmethod
    def _player_entity(entities: dict[str, Any]) -> dict[str, Any] | None:
        for key in ("player", "hero"):
            spec = entities.get(key)
            if isinstance(spec, dict):
                return spec
        return None

    def _entity_height(self, spec: dict[str, Any] | None) -> float | None:
        if not isinstance(spec, dict):
            return None
        size = spec.get("size")
        return (
            self._num_at(size, 1)
            or self._num_from_map(spec, "h")
            or self._num_from_map(spec, "height")
        )

    def _call_count(self, node: Any, call_name: str) -> int:
        return sum(1 for _, d in self._iter_dicts(node) if d.get("call") == call_name)

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
    def _known_frame_size(
        asset: str,
        asset_meta: dict[str, Any] | None = None,
    ) -> tuple[int, int] | None:
        return sprite_frame_size(asset_meta)

    @staticmethod
    def _is_presentation_slot(node: dict[str, Any], key: str) -> bool:
        if key in PRESENTATION_TEXT_KEYS:
            return True
        if key == "value" and node.get("type") in {"text", "markdown", "badge", "chip"}:
            return True
        return False

    @staticmethod
    def _is_raw_jsonlogic(value: Any) -> bool:
        return (
            isinstance(value, dict)
            and len(value) == 1
            and next(iter(value.keys())) in JSONLOGIC_SINGLE_KEYS
        )

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
    validator._validate_flame_game_mounts()
    validator._validate_presentation_text_slots()
    validator._validate_sprite_sheet_usage()
    validator._validate_game_profiles()
    validator._validate_game_input()
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


def load_allowed_icon_names() -> set[str]:
    repo = Path(__file__).resolve().parents[1]
    names: set[str] = set(DEFAULT_ICON_NAMES)
    path = repo / "lib/json_ui/widgets/icon_registry.dart"
    if not path.exists():
        return names
    pattern = re.compile(r"'([a-z][a-z0-9_]*)'\s*:\s*Icons\.")
    for match in pattern.finditer(path.read_text(encoding="utf-8")):
        names.add(match.group(1))
    return names


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
