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

    def error(self, path: str, message: str) -> None:
        self.findings.append(Finding("ERROR", path, message))

    def warn(self, path: str, message: str) -> None:
        self.findings.append(Finding("WARN", path, message))

    def validate(self) -> int:
        self._validate_root()
        self._walk(self.root, "$", in_game_logic=False)
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
            if dependency != "global" and dependency not in self.dependencies:
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


def load_builtin_calls() -> set[str]:
    repo = Path(__file__).resolve().parents[1]
    calls: set[str] = set()
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
