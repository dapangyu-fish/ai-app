#!/usr/bin/env python3
"""Small helper library for AI-generated JSON-APP builders.

This module is intentionally dependency-free and conservative. It is meant for
temporary generator scripts such as /tmp/generate_app.py, not for runtime
execution in the Flutter client.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any, Iterable

from asset_manifest_metadata import metadata_for_asset_url, sprite_frame_size
from game_layout_profiles import (
    RUN_AND_GUN_LAYOUT_PROFILE,
    run_and_gun_profile_summary,
    run_and_gun_stage_plan,
)


ASSET_URL_RE = re.compile(r"https?://[^\s\"']+/json-app-assets/asset-packs/[^\s\"']+")


class BuilderError(ValueError):
    """Raised when a generated app violates a structural builder invariant."""


def new_app(
    *,
    name: str,
    version: str = "1.0.0",
    display_name: str | dict[str, str] | None = None,
    description: str = "",
    author: str = "fish",
    appid: str | None = None,
    dependencies: dict[str, Any] | None = None,
    variables: dict[str, Any] | None = None,
    functions: dict[str, Any] | None = None,
    screens: list[dict[str, Any]] | None = None,
    assets: dict[str, Any] | None = None,
    steps: list[Any] | None = None,
    app_type: str = "app",
) -> dict[str, Any]:
    meta: dict[str, Any] = {
        "name": name,
        "version": version,
        "type": app_type,
        "description": description,
        "author": author,
    }
    if display_name is not None:
        meta["displayName"] = display_name

    app: dict[str, Any] = {
        "dsl": "3.3",
        "meta": meta,
        "dependencies": dependencies or {},
        "global": {
            "variables": variables or {},
            "functions": functions or {},
        },
        "steps": steps or [],
        "ui": {"screens": screens or []},
    }
    if appid:
        app["appid"] = appid
    if assets:
        app["assets"] = assets
    return app


def screen(
    screen_id: str,
    *,
    title: str | dict[str, str],
    children: list[dict[str, Any]],
    layout: str = "column",
    **props: Any,
) -> dict[str, Any]:
    out = {"id": screen_id, "title": title, "layout": layout, "children": children}
    out.update(props)
    return out


def call(name: str, **args: Any) -> dict[str, Any]:
    if not name.startswith("@"):
        name = f"@{name}"
    return {"call": name, "args": args}


def text(value: Any, **props: Any) -> dict[str, Any]:
    out = {"type": "text", "value": value}
    out.update(props)
    return out


def icon(name: str, *, size: int = 20, color: str = "#6B7280", **props: Any) -> dict[str, Any]:
    out = {"type": "icon", "name": name, "size": size, "color": color}
    out.update(props)
    return out


def spacer(*, height: int | None = None, width: int | None = None) -> dict[str, Any]:
    out: dict[str, Any] = {"type": "spacer"}
    if height is not None:
        out["height"] = height
    if width is not None:
        out["width"] = width
    return out


def container(children: list[dict[str, Any]], layout: str = "column", **props: Any) -> dict[str, Any]:
    out = {"type": "container", "layout": layout, "children": children}
    out.update(props)
    return out


def card(children: list[dict[str, Any]], layout: str = "column", **props: Any) -> dict[str, Any]:
    out = {
        "type": "card",
        "layout": layout,
        "color": "#FFFFFF",
        "padding": 16,
        "margin": 8,
        "elevation": 0,
        "borderRadius": 14,
        "children": children,
    }
    out.update(props)
    return out


def button(
    label: str,
    *,
    action: dict[str, Any],
    variant: str = "filled",
    icon_name: str | None = None,
    style: dict[str, Any] | None = None,
    **props: Any,
) -> dict[str, Any]:
    out: dict[str, Any] = {
        "type": "button",
        "label": label,
        "variant": variant,
        "action": action,
    }
    if icon_name:
        out["icon"] = icon_name
    if style:
        out["style"] = style
    out.update(props)
    return out


def native_app_bar(
    title: str,
    *,
    actions: list[dict[str, Any]] | None = None,
    background: str = "#FFFFFF",
    color: str = "#111827",
    center_title: bool = True,
) -> dict[str, Any]:
    out: dict[str, Any] = {
        "title": title,
        "centerTitle": center_title,
        "backgroundColor": background,
        "color": color,
        "elevation": 0,
    }
    if actions:
        out["actions"] = actions
    return out


def native_search_bar(
    *,
    bind: str,
    placeholder: str = "搜索",
    action: dict[str, Any] | None = None,
    trailing_label: str = "搜索",
) -> dict[str, Any]:
    children = [
        icon("search", size=18, color="#8E8E93"),
        spacer(width=8),
        {
            "type": "input",
            "placeholder": placeholder,
            "bind": bind,
            "position": {"type": "flex", "flex": 1},
            "style": {"fontSize": 15, "borderRadius": 10},
        },
    ]
    if action is not None:
        children.append(
            button(
                trailing_label,
                variant="text",
                action=action,
                style={"textColor": "#2563EB", "fontSize": 14},
            )
        )
    return container(
        children,
        layout="row",
        padding=10,
        margin=12,
        color="#F7F8FA",
        borderRadius=14,
        crossAxisAlignment="center",
    )


def native_action_icon(
    icon_name: str,
    *,
    action: dict[str, Any],
    color: str = "#2563EB",
    tooltip: str | None = None,
) -> dict[str, Any]:
    out = button(
        "",
        variant="text",
        action=action,
        icon_name=icon_name,
        style={"textColor": color, "fontSize": 18, "paddingH": 10, "paddingV": 8},
    )
    if tooltip:
        out["tooltip"] = tooltip
    return out


def native_metric_card(
    label: str,
    value: str,
    *,
    icon_name: str = "insights",
    accent: str = "#2563EB",
) -> dict[str, Any]:
    return card(
        [
            container(
                [
                    icon(icon_name, size=18, color=accent),
                    spacer(width=8),
                    text(label, style={"fontSize": 13, "color": "#6B7280"}),
                ],
                layout="row",
                crossAxisAlignment="center",
            ),
            spacer(height=8),
            text(value, style={"fontSize": 21, "fontWeight": "bold", "color": "#111827", "maxLines": 1}),
        ],
        margin=6,
        padding=14,
    )


def native_metric_row(metrics: list[dict[str, str]], *, accent: str = "#2563EB") -> dict[str, Any]:
    """Build a compact native summary row.

    Each metric accepts: label, value, icon, accent. The helper intentionally
    uses only scalar spacing because JSON widgets do not support edge objects.
    On phone widths more than two cards in one row becomes cramped, so the
    helper wraps metrics into two-card rows.
    """
    def build_row(row_metrics: list[dict[str, str]]) -> dict[str, Any]:
        children: list[dict[str, Any]] = []
        for i, metric in enumerate(row_metrics):
            if i:
                children.append(spacer(width=8))
            children.append(
                {
                    "type": "expanded",
                    "child": native_metric_card(
                        metric.get("label", ""),
                        metric.get("value", "0"),
                        icon_name=metric.get("icon", "insights"),
                        accent=metric.get("accent", accent),
                    ),
                }
            )
        return container(children, layout="row")

    if len(metrics) <= 2:
        return container(build_row(metrics)["children"], layout="row", margin=8)

    rows: list[dict[str, Any]] = []
    for i in range(0, len(metrics), 2):
        if i:
            rows.append(spacer(height=8))
        rows.append(build_row(metrics[i : i + 2]))
    return container(rows, layout="column", margin=8)


def native_filter_chips(
    options: list[tuple[str, str]] | list[dict[str, str]],
    *,
    bind: str,
    action: dict[str, Any] | None = None,
    accent: str = "#2563EB",
) -> dict[str, Any]:
    children: list[dict[str, Any]] = []
    for option in options:
        if isinstance(option, dict):
            label = option.get("label", "")
            value = option.get("value", label)
        else:
            label, value = option
        chip: dict[str, Any] = {
            "type": "chip",
            "label": label,
            "variant": "choice",
            "bind": bind,
            "value": value,
            "color": accent,
        }
        if action is not None:
            chip["action"] = action
        children.append(chip)
    return {
        "type": "wrap",
        "spacing": 8,
        "runSpacing": 8,
        "children": children,
    }


def native_empty_state(
    *,
    title: str,
    subtitle: str,
    icon_name: str = "inbox",
    action: dict[str, Any] | None = None,
    action_label: str = "新建",
) -> dict[str, Any]:
    children = [
        icon(icon_name, size=34, color="#A1A1AA"),
        spacer(height=10),
        text(title, style={"fontSize": 15, "fontWeight": "600", "color": "#52525B"}),
        spacer(height=4),
        text(subtitle, style={"fontSize": 13, "color": "#8E8E93"}),
    ]
    if action is not None:
        children.extend(
            [
                spacer(height=12),
                button(
                    action_label,
                    action=action,
                    icon_name="add",
                    style={
                        "backgroundColor": "#2563EB",
                        "textColor": "#FFFFFF",
                        "borderRadius": 18,
                        "fontSize": 14,
                        "paddingH": 16,
                        "paddingV": 9,
                    },
                ),
            ]
        )
    return container(
        children,
        layout="column",
        padding=20,
        margin=12,
        color="#FFFFFF",
        borderRadius=14,
        mainAxisAlignment="center",
        crossAxisAlignment="center",
    )


def native_crud_app_shell(
    *,
    screen_id: str,
    title: str,
    list_source: str,
    item_template: dict[str, Any],
    metrics: list[dict[str, str]] | None = None,
    search_bind: str | None = None,
    search_placeholder: str = "搜索",
    search_action: dict[str, Any] | None = None,
    filters: list[tuple[str, str]] | list[dict[str, str]] | None = None,
    filter_bind: str | None = None,
    filter_action: dict[str, Any] | None = None,
    primary_action: dict[str, Any] | None = None,
    primary_icon: str = "add",
    primary_label: str = "新增",
    empty_text: str = "暂无数据",
    accent: str = "#2563EB",
    background: str = "#F4F6F8",
) -> dict[str, Any]:
    """Native CRUD/list screen scaffold for generated apps.

    This helper deliberately encodes a good first viewport: summary, search,
    filters and list are all present before empty-state content.
    """
    children: list[dict[str, Any]] = []
    if metrics:
        children.append(native_metric_row(metrics, accent=accent))
    if search_bind:
        children.append(
            native_search_bar(
                bind=search_bind,
                placeholder=search_placeholder,
                action=search_action,
                trailing_label="搜索" if search_action is not None else "",
            )
        )
    if filters and filter_bind:
        children.append(
            container(
                [native_filter_chips(filters, bind=filter_bind, action=filter_action, accent=accent)],
                layout="column",
                padding=12,
                margin=8,
                color="#FFFFFF",
                borderRadius=14,
            )
        )
    children.append(
        {
            "type": "list",
            "source": list_source,
            "emptyText": empty_text,
            "item_template": item_template,
        }
    )
    if primary_action is not None:
        children.append(
            container(
                [
                    button(
                        primary_label,
                        action=primary_action,
                        icon_name=primary_icon,
                        style={
                            "backgroundColor": accent,
                            "textColor": "#FFFFFF",
                            "borderRadius": 16,
                            "fontSize": 15,
                            "paddingV": 12,
                        },
                    )
                ],
                padding=12,
                color=background,
            )
        )
    return screen(
        screen_id,
        title=title,
        backgroundColor=background,
        appBar=native_app_bar(
            title,
            actions=[native_action_icon(primary_icon, action=primary_action, color=accent)]
            if primary_action is not None
            else None,
        ),
        children=children,
    )


def expanded(child: dict[str, Any], flex: int = 1) -> dict[str, Any]:
    return {"type": "expanded", "flex": flex, "child": child}


def flame_game(**props: Any) -> dict[str, Any]:
    out = {"type": "flame_game"}
    out.update(props)
    return out


def pixel_entity(
    *,
    position: list[Any] | tuple[Any, Any],
    size: list[Any] | tuple[Any, Any],
    velocity: list[Any] | tuple[Any, Any] = (0, 0),
    render: dict[str, Any] | None = None,
    priority: int = 0,
    auto_update: bool = True,
    state: dict[str, Any] | None = None,
) -> dict[str, Any]:
    out = _pixel_base(
        "pixel",
        position=position,
        size=size,
        velocity=velocity,
        render=render,
        priority=priority,
        auto_update=auto_update,
        state=state,
    )
    return out


def sprite_entity(
    *,
    asset: str,
    position: list[Any] | tuple[Any, Any],
    size: list[Any] | tuple[Any, Any],
    src: list[Any] | tuple[Any, Any, Any, Any] | None = None,
    velocity: list[Any] | tuple[Any, Any] = (0, 0),
    render: dict[str, Any] | None = None,
    priority: int = 0,
    auto_update: bool = True,
    state: dict[str, Any] | None = None,
    flip_x: bool = False,
) -> dict[str, Any]:
    out = _pixel_base(
        "sprite",
        position=position,
        size=size,
        velocity=velocity,
        render=render,
        priority=priority,
        auto_update=auto_update,
        state=state,
    )
    out["asset"] = asset
    if src is not None:
        out["src"] = list(src)
    if flip_x:
        out["flip_x"] = True
    return out


def animated_sprite_entity(
    *,
    asset: str,
    position: list[Any] | tuple[Any, Any],
    size: list[Any] | tuple[Any, Any],
    frame_size: list[int] | tuple[int, int],
    frames: int,
    frames_per_row: int | None = None,
    src_origin: list[Any] | tuple[Any, Any] | None = None,
    frame_step: list[Any] | tuple[Any, Any] | None = None,
    step_time: float = 0.12,
    animation: str | None = None,
    animations: dict[str, Any] | None = None,
    velocity: list[Any] | tuple[Any, Any] = (0, 0),
    render: dict[str, Any] | None = None,
    priority: int = 0,
    auto_update: bool = True,
    state: dict[str, Any] | None = None,
    loop: bool = True,
    flip_x: bool = False,
) -> dict[str, Any]:
    out = _pixel_base(
        "animated_sprite",
        position=position,
        size=size,
        velocity=velocity,
        render=render,
        priority=priority,
        auto_update=auto_update,
        state=state,
    )
    out.update(
        {
            "asset": asset,
            "frame_size": list(frame_size),
            "frames": frames,
            "step_time": step_time,
            "loop": loop,
        }
    )
    if frames_per_row is not None:
        out["frames_per_row"] = frames_per_row
    if src_origin is not None:
        out["src_origin"] = list(src_origin)
    if frame_step is not None:
        out["frame_step"] = list(frame_step)
    if animation is not None:
        out["animation"] = animation
    if animations is not None:
        out["animations"] = animations
    if flip_x:
        out["flip_x"] = True
    return out


def parallax_entity(
    *,
    asset: str,
    speed_x: float,
    y: float = 0,
    height: float | None = None,
    render: dict[str, Any] | None = None,
    priority: int = 0,
) -> dict[str, Any]:
    out: dict[str, Any] = {
        "kind": "parallax",
        "asset": asset,
        "speed_x": speed_x,
        "y": y,
        "priority": priority,
    }
    if height is not None:
        out["height"] = height
    if render is not None:
        out["render"] = render
    return out


def tiled_map_entity(
    *,
    source: str | None = None,
    map_data: dict[str, Any] | None = None,
    base_url: str | None = None,
    scale: float = 1,
    include_layers: list[str] | None = None,
    exclude_layers: list[str] | None = None,
    solid_layers: list[str] | None = None,
    hazard_layers: list[str] | None = None,
    collidable: bool = True,
    priority: int = 0,
) -> dict[str, Any]:
    if not source and map_data is None:
        raise BuilderError("tiled_map_entity requires source or map_data")
    out: dict[str, Any] = {"kind": "tiled_map", "scale": scale, "priority": priority}
    if source:
        out["source"] = source
    if map_data is not None:
        out["map_data"] = map_data
    if base_url:
        out["base_url"] = base_url
    if include_layers is not None:
        out["include_layers"] = include_layers
    if exclude_layers is not None:
        out["exclude_layers"] = exclude_layers
    if solid_layers is not None:
        out["solid_layers"] = solid_layers
    if hazard_layers is not None:
        out["hazard_layers"] = hazard_layers
    if not collidable:
        out["collidable"] = False
    return out


def asset_bundle(
    *,
    base_url: str,
    manifest: str = "manifest.json",
    license: str | None = None,
    startup_download: bool = True,
) -> dict[str, Any]:
    out: dict[str, Any] = {
        "baseUrl": base_url,
        "manifest": manifest,
        "startupDownload": startup_download,
    }
    if license:
        out["license"] = license
    return out


class AssetPack:
    """Convenience wrapper around a hosted asset-pack manifest."""

    def __init__(self, manifest: dict[str, Any]) -> None:
        self.manifest = manifest
        self.slug = str(manifest.get("slug") or "")
        self.version = str(manifest.get("version") or "")
        self.base_url = str(manifest.get("baseUrl") or "")
        self.files = [
            item for item in manifest.get("files", []) if isinstance(item, dict)
        ]
        self._by_path = {str(item.get("path") or ""): item for item in self.files}

    @classmethod
    def from_url(cls, manifest_url: str) -> "AssetPack":
        from asset_manifest_metadata import load_manifest

        manifest = load_manifest(manifest_url)
        if not manifest:
            raise BuilderError(f"failed to load asset manifest: {manifest_url}")
        return cls(manifest)

    @classmethod
    def from_file(cls, path: str | Path) -> "AssetPack":
        return cls(json.loads(Path(path).read_text(encoding="utf-8")))

    def file(self, path: str) -> dict[str, Any]:
        item = self._by_path.get(path)
        if not item:
            raise BuilderError(f"asset path not found in manifest: {path}")
        return item

    def url(self, path: str) -> str:
        url = str(self.file(path).get("url") or "")
        if not url:
            raise BuilderError(f"asset path has no url in manifest: {path}")
        return url

    def sprite(self, path: str) -> dict[str, Any]:
        meta = metadata_for_asset_url(self.url(path))
        if not meta:
            raise BuilderError(f"missing asset metadata: {path}")
        sprite = meta.get("sprite")
        if not isinstance(sprite, dict):
            raise BuilderError(f"asset has no sprite metadata: {path}")
        return sprite

    def frame_size(self, path: str) -> tuple[int, int]:
        frame = sprite_frame_size(metadata_for_asset_url(self.url(path)))
        if not frame:
            raise BuilderError(f"asset frame size unknown: {path}")
        return frame

    def animation(
        self,
        path: str,
        *,
        frames: int,
        start_frame: int = 0,
        step_time: float = 0.12,
        loop: bool = True,
        frames_per_row: int | None = None,
    ) -> dict[str, Any]:
        sprite = self.sprite(path)
        frame_w, frame_h = self.frame_size(path)
        if sprite.get("kind") == "single" and frames > 1:
            raise BuilderError(
                f"asset metadata says single-frame image, not animation sheet: {path}"
            )
        if frames <= 0:
            raise BuilderError(f"animation frames must be positive: {path}")
        available_frames = int(sprite.get("frames") or frames)
        if frames > available_frames:
            raise BuilderError(
                f"animation requests {frames} frames but manifest has {available_frames}: {path}"
            )
        columns = int(sprite.get("columns") or frames_per_row or frames)
        frames_per_row = frames_per_row or columns
        if frames_per_row <= 0:
            raise BuilderError(f"frames_per_row must be positive: {path}")
        return {
            "asset": self.url(path),
            "frame_size": [frame_w, frame_h],
            "frames": frames,
            "frames_per_row": frames_per_row,
            "step_time": step_time,
            "start_frame": start_frame,
            "loop": loop,
        }

    def image_paths(self, *, tags: Iterable[str] | None = None) -> list[str]:
        wanted = set(tags or [])
        paths: list[str] = []
        for item in self.files:
            if not str(item.get("type") or "").startswith("image/"):
                continue
            item_tags = set(item.get("tags") or [])
            if wanted and not wanted.issubset(item_tags):
                continue
            paths.append(str(item.get("path") or ""))
        return paths


def tile_layer(
    name: str,
    width: int,
    height: int,
    *,
    fill: int = 0,
    opacity: float = 1.0,
    visible: bool = True,
) -> dict[str, Any]:
    return {
        "type": "tilelayer",
        "name": name,
        "width": width,
        "height": height,
        "opacity": opacity,
        "visible": visible,
        "data": [fill] * (width * height),
    }


def fill_rect(layer: dict[str, Any], x: int, y: int, width: int, height: int, gid: int) -> None:
    layer_width = int(layer["width"])
    layer_height = int(layer["height"])
    data = layer["data"]
    for row in range(max(0, y), min(layer_height, y + height)):
        for col in range(max(0, x), min(layer_width, x + width)):
            data[row * layer_width + col] = gid


def set_tile(layer: dict[str, Any], x: int, y: int, gid: int) -> None:
    layer_width = int(layer["width"])
    layer_height = int(layer["height"])
    if x < 0 or y < 0 or x >= layer_width or y >= layer_height:
        raise BuilderError(f"tile coordinate out of bounds: {x},{y}")
    layer["data"][y * layer_width + x] = gid


def object_layer(name: str, objects: list[dict[str, Any]] | None = None) -> dict[str, Any]:
    return {"type": "objectgroup", "name": name, "objects": objects or []}


def tiled_object(
    *,
    object_id: int,
    name: str,
    x: float,
    y: float,
    width: float,
    height: float,
    object_type: str | None = None,
    properties: dict[str, Any] | None = None,
) -> dict[str, Any]:
    out: dict[str, Any] = {
        "id": object_id,
        "name": name,
        "x": x,
        "y": y,
        "width": width,
        "height": height,
        "visible": True,
    }
    if object_type:
        out["type"] = object_type
    if properties:
        out["properties"] = [
            {"name": key, "type": _tiled_property_type(value), "value": value}
            for key, value in properties.items()
        ]
    return out


def tiled_objects_from_run_and_gun_plan(
    plan: dict[str, Any],
    *,
    layer: str = "objects",
    enemy_type: str = "enemy_patrol",
    cover_type: str = "cover",
    landmark_type: str = "landmark",
) -> dict[str, Any]:
    """Convert a neutral run-and-gun stage plan to a Tiled object layer."""
    objects: list[dict[str, Any]] = []
    for point in plan.get("enemyPoints") or []:
        if not isinstance(point, dict):
            continue
        objects.append(
            tiled_object(
                object_id=int(point["id"]),
                name=str(point["name"]),
                x=float(point["x"]),
                y=float(point["y"]),
                width=float(point["width"]),
                height=float(point["height"]),
                object_type=str(point.get("type") or enemy_type),
                properties={
                    "segment": str(point.get("segment") or ""),
                    "requiresAimY": bool(point.get("requiresAimY")),
                    "patrol_min": max(0, int(float(point["x"]) - 120)),
                    "patrol_max": int(float(point["x"]) + 120),
                    "speed": 60,
                },
            )
        )
    for point in plan.get("coverPoints") or []:
        if not isinstance(point, dict):
            continue
        objects.append(
            tiled_object(
                object_id=int(point["id"]),
                name=str(point["name"]),
                x=float(point["x"]),
                y=float(point["y"]),
                width=float(point["width"]),
                height=float(point["height"]),
                object_type=str(point.get("type") or cover_type),
                properties={"segment": str(point.get("segment") or "")},
            )
        )
    for point in plan.get("landmarkPoints") or []:
        if not isinstance(point, dict):
            continue
        objects.append(
            tiled_object(
                object_id=int(point["id"]),
                name=str(point["name"]),
                x=float(point["x"]),
                y=float(point["y"]),
                width=float(point["width"]),
                height=float(point["height"]),
                object_type=str(point.get("type") or landmark_type),
                properties={
                    "segment": str(point.get("segment") or ""),
                    "note": str(point.get("note") or ""),
                },
            )
        )
    return object_layer(layer, objects)


def tileset(
    *,
    firstgid: int,
    name: str,
    image: str,
    imagewidth: int,
    imageheight: int,
    tilewidth: int,
    tileheight: int,
    columns: int | None = None,
    tilecount: int | None = None,
) -> dict[str, Any]:
    columns = columns or max(1, imagewidth // tilewidth)
    tilecount = tilecount or columns * max(1, imageheight // tileheight)
    return {
        "firstgid": firstgid,
        "name": name,
        "tilewidth": tilewidth,
        "tileheight": tileheight,
        "image": image,
        "imagewidth": imagewidth,
        "imageheight": imageheight,
        "columns": columns,
        "tilecount": tilecount,
    }


def tiled_map(
    *,
    width: int,
    height: int,
    tilewidth: int,
    tileheight: int,
    layers: list[dict[str, Any]],
    tilesets: list[dict[str, Any]],
    source: str | None = None,
) -> dict[str, Any]:
    out: dict[str, Any] = {
        "format": "tiled-json-v1",
        "orientation": "orthogonal",
        "renderorder": "right-down",
        "width": width,
        "height": height,
        "tilewidth": tilewidth,
        "tileheight": tileheight,
        "infinite": False,
        "layers": layers,
        "tilesets": tilesets,
    }
    if source:
        out["source"] = source
    return out


def collect_asset_urls(node: Any) -> set[str]:
    urls: set[str] = set()

    def visit(value: Any) -> None:
        if isinstance(value, str):
            for raw_url in ASSET_URL_RE.findall(value):
                url = raw_url.split("?", 1)[0]
                # Bundle roots and manifests are valid asset-pack references, but
                # they are not file assets listed in files[].url.
                if url.endswith("/") or url.endswith("/manifest.json"):
                    continue
                urls.add(url)
        elif isinstance(value, dict):
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(node)
    return urls


# DSL 版本窗口的单一真相源在 dsl_contract（见 §11.3 收敛多处硬编码）；此处 re-export 保持兼容。
from dsl_contract import SUPPORTED_DSL_VERSIONS  # noqa: E402,F401


def assert_required_fields(app: dict[str, Any]) -> None:
    dsl = app.get("dsl")
    if dsl not in SUPPORTED_DSL_VERSIONS:
        raise BuilderError(
            f"dsl {dsl!r} 不在支持窗口 {sorted(SUPPORTED_DSL_VERSIONS)} 内"
        )
    meta = app.get("meta")
    if not isinstance(meta, dict):
        raise BuilderError("meta must be an object")
    for key in ("name", "version", "type"):
        if not meta.get(key):
            raise BuilderError(f"meta.{key} is required")
    if meta.get("type") != "library":
        screens = ((app.get("ui") or {}).get("screens") or [])
        if not screens:
            raise BuilderError("app JSON must define ui.screens")


def assert_asset_urls_from_manifests(app: dict[str, Any], packs: Iterable[AssetPack]) -> None:
    allowed = {
        str(item.get("url") or "").split("?", 1)[0]
        for pack in packs
        for item in pack.files
        if item.get("url")
    }
    unknown = sorted(url for url in collect_asset_urls(app) if url not in allowed)
    if unknown:
        raise BuilderError("asset URL not present in selected manifests: " + ", ".join(unknown[:5]))


def assert_unique_spawn_ids(app: dict[str, Any]) -> None:
    static_ids: set[str] = set()
    spawn_ids: set[str] = set()
    for game in _iter_flame_games(app):
        entities = game.get("entities")
        if isinstance(entities, dict):
            static_ids.update(str(key) for key in entities.keys())
        for node in _iter_dicts(game):
            if node.get("call") != "@spawn":
                continue
            args = node.get("args")
            if not isinstance(args, dict):
                continue
            entity_id = args.get("id")
            if not isinstance(entity_id, str) or "{{" in entity_id:
                continue
            if entity_id in static_ids or entity_id in spawn_ids:
                raise BuilderError(f"duplicate literal spawn entity id: {entity_id}")
            spawn_ids.add(entity_id)


def assert_sprite_frame_size(asset_url: str, frame_size: list[int] | tuple[int, int]) -> None:
    expected = sprite_frame_size(metadata_for_asset_url(asset_url))
    if not expected:
        raise BuilderError(f"sprite metadata unavailable for asset: {asset_url}")
    if len(frame_size) < 2:
        raise BuilderError("frame_size must contain width and height")
    got = (int(frame_size[0]), int(frame_size[1]))
    if got != expected:
        raise BuilderError(f"frame_size {got[0]}x{got[1]} must be {expected[0]}x{expected[1]} for {asset_url}")


def validate_app(app: dict[str, Any], *, packs: Iterable[AssetPack] | None = None) -> None:
    assert_required_fields(app)
    assert_unique_spawn_ids(app)
    if packs is not None:
        assert_asset_urls_from_manifests(app, packs)


def save_json(
    app: dict[str, Any],
    path: str | Path,
    *,
    packs: Iterable[AssetPack] | None = None,
    validate: bool = True,
) -> None:
    if validate:
        validate_app(app, packs=packs)
    Path(path).write_text(
        json.dumps(app, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def _iter_flame_games(node: Any):
    for item in _iter_dicts(node):
        if item.get("type") == "flame_game":
            yield item


def _iter_dicts(node: Any):
    if isinstance(node, dict):
        yield node
        for value in node.values():
            yield from _iter_dicts(value)
    elif isinstance(node, list):
        for value in node:
            yield from _iter_dicts(value)


def _tiled_property_type(value: Any) -> str:
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, int):
        return "int"
    if isinstance(value, float):
        return "float"
    return "string"


def _pixel_base(
    kind: str,
    *,
    position: list[Any] | tuple[Any, Any],
    size: list[Any] | tuple[Any, Any],
    velocity: list[Any] | tuple[Any, Any],
    render: dict[str, Any] | None,
    priority: int,
    auto_update: bool,
    state: dict[str, Any] | None,
) -> dict[str, Any]:
    out: dict[str, Any] = {
        "kind": kind,
        "position": list(position),
        "size": list(size),
        "velocity": list(velocity),
        "priority": priority,
    }
    if render is not None:
        out["render"] = render
    if not auto_update:
        out["auto_update"] = False
    if state is not None:
        out["state"] = state
    return out
