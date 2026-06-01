#!/usr/bin/env python3
"""Mechanical repairs for common generated JSON-APP mistakes.

The validator remains the source of truth. This script only applies safe,
syntax-preserving cleanup for patterns that are already invalid or noisy.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


FORBIDDEN_UI_KEYS = {
    "marginBottom",
    "marginLeft",
    "marginRight",
    "marginTop",
    "shadow",
    "transform",
    "transition",
}

EDGE_KEYS = {"margin", "padding"}
UNSUPPORTED_STYLE_KEYS = {"margin", "padding"}


def _path_text(path: tuple[Any, ...]) -> str:
    out = "$"
    for part in path:
        if isinstance(part, int):
            out += f"[{part}]"
        else:
            out += f".{part}"
    return out


def _is_screen_or_tab_path(path: tuple[Any, ...]) -> bool:
    if len(path) >= 3 and path[-2] == "screens" and isinstance(path[-1], int):
        return True
    if len(path) >= 5 and path[-2] == "tabs" and isinstance(path[-1], int):
        return True
    return False


def _is_ui_path(path: tuple[Any, ...]) -> bool:
    return bool(path) and path[0] == "ui"


def _as_children(value: Any) -> list[Any]:
    if isinstance(value, list):
        return value
    if value is None:
        return []
    return [value]


def _edge_to_scalar(value: Any) -> int | float:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return value
    if isinstance(value, dict):
        nums = [
            v
            for v in value.values()
            if isinstance(v, (int, float)) and not isinstance(v, bool)
        ]
        return max(nums) if nums else 0
    return 0


def _is_op_args_expression(value: Any) -> bool:
    return (
        isinstance(value, dict)
        and set(value.keys()) == {"op", "args"}
        and isinstance(value.get("op"), str)
    )


def _convert_op_args_expression(value: dict[str, Any]) -> dict[str, Any]:
    return {value["op"]: value.get("args")}


def _repair(
    node: Any,
    path: tuple[Any, ...],
    changes: list[str],
    *,
    in_game_logic: bool = False,
) -> None:
    if isinstance(node, list):
        for i, item in enumerate(node):
            if _is_op_args_expression(item):
                node[i] = _convert_op_args_expression(item)
                changes.append(f"{_path_text((*path, i))}: converted op/args expression to jsonlogic")
                item = node[i]
            _repair(item, (*path, i), changes, in_game_logic=in_game_logic)
        return

    if not isinstance(node, dict):
        return

    is_ui = _is_ui_path(path)
    child_in_game_logic = in_game_logic or (is_ui and node.get("type") == "flame_game")

    if "body" in node and _is_screen_or_tab_path(path):
        body = node.pop("body")
        if "children" not in node:
            node["children"] = _as_children(body)
            changes.append(f"{_path_text(path)}: moved body to children")
        else:
            changes.append(f"{_path_text(path)}: removed redundant body")

    if is_ui:
        for key in list(node.keys()):
            if key in FORBIDDEN_UI_KEYS:
                node.pop(key)
                changes.append(f"{_path_text((*path, key))}: removed unsupported field")

        for key in EDGE_KEYS:
            if key in node and not isinstance(node[key], (int, float)):
                old_type = type(node[key]).__name__
                node[key] = _edge_to_scalar(node[key])
                changes.append(f"{_path_text((*path, key))}: converted {old_type} edge spacing to scalar")

    if is_ui and node.get("type") == "container" and isinstance(node.get("style"), dict):
        style = node.pop("style")
        for key, value in style.items():
            mapped_key = "color" if key == "backgroundColor" else key
            if mapped_key in FORBIDDEN_UI_KEYS:
                changes.append(f"{_path_text((*path, 'style', key))}: dropped unsupported style field")
                continue
            if mapped_key not in node:
                node[mapped_key] = _edge_to_scalar(value) if mapped_key in EDGE_KEYS else value
        changes.append(f"{_path_text((*path, 'style'))}: flattened container style")

    style = node.get("style")
    if is_ui and isinstance(style, dict):
        for key in list(style.keys()):
            if key in UNSUPPORTED_STYLE_KEYS:
                style.pop(key)
                changes.append(f"{_path_text((*path, 'style', key))}: removed unsupported style key")

    for action_key in ("action", "onTap", "onLongPress", "onDoubleTap"):
        action = node.get(action_key)
        if isinstance(action, dict) and action.get("type") == "call" and "call" in action:
            action.pop("type", None)
            changes.append(f"{_path_text((*path, action_key, 'type'))}: removed redundant call type")

    if child_in_game_logic and node.get("call") == "@if":
        args = node.get("args")
        if isinstance(args, dict) and "condition" in args and "cond" not in args:
            args["cond"] = args.pop("condition")
            changes.append(f"{_path_text((*path, 'args', 'condition'))}: renamed flame_game @if condition to cond")

    source = node.get("source")
    if is_ui and node.get("type") == "list" and isinstance(source, dict) and set(source.keys()) == {"var"}:
        node["source"] = "{{ " + str(source["var"]) + " }}"
        changes.append(f"{_path_text((*path, 'source'))}: converted var expression to interpolation")

    for key, value in list(node.items()):
        if _is_op_args_expression(value):
            node[key] = _convert_op_args_expression(value)
            changes.append(f"{_path_text((*path, key))}: converted op/args expression to jsonlogic")
            value = node[key]
        _repair(value, (*path, key), changes, in_game_logic=child_in_game_logic)


def repair_file(path: Path) -> list[str]:
    app = json.loads(path.read_text(encoding="utf-8"))
    changes: list[str] = []
    _repair(app, (), changes)
    if changes:
        path.write_text(
            json.dumps(app, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    return changes


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("json_file", type=Path)
    args = parser.parse_args()

    changes = repair_file(args.json_file)
    if changes:
        print(f"repaired {len(changes)} issue(s):")
        for change in changes[:80]:
            print(f"- {change}")
        if len(changes) > 80:
            print(f"- ... {len(changes) - 80} more")
    else:
        print("no mechanical repairs needed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
