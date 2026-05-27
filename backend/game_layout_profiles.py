#!/usr/bin/env python3
"""Neutral game layout profiles for generated JSON apps.

The profiles in this module are not copied maps. They are design archetypes:
segment lengths, encounter density, landmark cadence and validation targets
derived from common level-design practice. Generated apps should use these as
scaffolding, then fill them with assets from the selected asset manifest.
"""

from __future__ import annotations

from copy import deepcopy
from typing import Any


RUN_AND_GUN_LAYOUT_PROFILE: dict[str, Any] = {
    "id": "run_and_gun_v1",
    "genre": "side_scrolling_run_and_gun",
    "license": "layout-archetype-only",
    "copyPolicy": (
        "Do not copy third-party maps. Use this as a neutral structure for "
        "segment rhythm, encounter density and scene cadence."
    ),
    "referenceNotes": [
        {
            "name": "SuperTux / Open Surge / Tiled sample maps",
            "use": "Study readable route rhythm and object-layer structure only.",
            "doNotUse": "Do not copy level files, coordinates, names or art.",
        },
        {
            "name": "Classic run-and-gun stage rhythm",
            "use": "Safe intro, first enemies, cover firefight, vertical variation, finale.",
            "doNotUse": "Do not use protected characters, maps or brand-specific set pieces.",
        },
    ],
    "minimums": {
        "viewportWidth": 420,
        "viewportHeight": 500,
        "mapWidthViewports": 6,
        "segments": 6,
        "visibleBackgroundLayers": 3,
        "enemyObjects": 10,
        "enemyObjectsInFirstTwoViewports": 2,
        "coverObjects": 8,
        "landmarks": 6,
        "projectileReleasePaths": 2,
        "mustSupportAimY": True,
        "mustHandleOutOfBounds": True,
    },
    "segments": [
        {
            "id": "intro_safe",
            "widthViewports": 0.85,
            "purpose": "Teach movement and shooting before pressure.",
            "enemyCount": 0,
            "coverCount": 1,
            "landmark": "spawn signage / base entrance",
            "terrain": "flat ground with one small visual step; no pit",
        },
        {
            "id": "first_contact",
            "widthViewports": 1.05,
            "purpose": "Introduce one weak patrol and one target at eye level.",
            "enemyCount": 2,
            "coverCount": 2,
            "landmark": "first barricade / crate stack",
            "terrain": "flat ground plus low cover",
        },
        {
            "id": "cover_firefight",
            "widthViewports": 1.10,
            "purpose": "Alternate cover and open firing lanes.",
            "enemyCount": 3,
            "coverCount": 3,
            "landmark": "industrial wall / vehicle / pipe cluster",
            "terrain": "low cover, short jumpable platform, no dead-end",
        },
        {
            "id": "hazard_gap",
            "widthViewports": 0.95,
            "purpose": "Add pits or hazards while preserving fair jumps.",
            "enemyCount": 2,
            "coverCount": 1,
            "landmark": "warning sign / broken bridge / hazard pool",
            "terrain": "one or two short gaps with safe landing pads",
        },
        {
            "id": "vertical_pressure",
            "widthViewports": 1.15,
            "purpose": "Use raised platforms and enemies that require upward aim.",
            "enemyCount": 3,
            "coverCount": 2,
            "landmark": "raised tower / balcony / overhead pipe",
            "terrain": "two-level platforming with a clear main route",
        },
        {
            "id": "final_push",
            "widthViewports": 0.90,
            "purpose": "Short dense push into goal or mini-boss zone.",
            "enemyCount": 2,
            "coverCount": 1,
            "landmark": "exit gate / extraction point / boss marker",
            "terrain": "clear finish lane, no blind pit at the end",
        },
    ],
}


def run_and_gun_stage_plan(
    *,
    viewport_width: int = 420,
    viewport_height: int = 500,
    tile: int = 16,
    ground_y: int | None = None,
) -> dict[str, Any]:
    """Return a neutral stage plan with absolute x ranges and object points."""
    if viewport_width <= 0:
        raise ValueError("viewport_width must be positive")
    if viewport_height <= 0:
        raise ValueError("viewport_height must be positive")
    if tile <= 0:
        raise ValueError("tile must be positive")

    ground_y = ground_y if ground_y is not None else int(viewport_height * 0.80)
    cursor = 0
    segments: list[dict[str, Any]] = []
    object_id = 1
    enemy_points: list[dict[str, Any]] = []
    cover_points: list[dict[str, Any]] = []
    landmark_points: list[dict[str, Any]] = []

    for raw in RUN_AND_GUN_LAYOUT_PROFILE["segments"]:
        width = int(round(float(raw["widthViewports"]) * viewport_width / tile)) * tile
        start = cursor
        end = cursor + max(tile * 8, width)
        segment = deepcopy(raw)
        segment.update({"startX": start, "endX": end, "width": end - start})
        segments.append(segment)

        for i, x in enumerate(_spread_points(start, end, int(raw["enemyCount"]))):
            high = raw["id"] == "vertical_pressure" and i % 2 == 0
            enemy_points.append(
                {
                    "id": object_id,
                    "name": f"enemy_{raw['id']}_{i + 1}",
                    "type": "enemy_patrol",
                    "x": x,
                    "y": ground_y - (112 if high else 48),
                    "width": 48,
                    "height": 44,
                    "segment": raw["id"],
                    "requiresAimY": high,
                }
            )
            object_id += 1

        for i, x in enumerate(_spread_points(start, end, int(raw["coverCount"]))):
            cover_points.append(
                {
                    "id": object_id,
                    "name": f"cover_{raw['id']}_{i + 1}",
                    "type": "cover",
                    "x": x,
                    "y": ground_y - 34,
                    "width": 48,
                    "height": 34,
                    "segment": raw["id"],
                }
            )
            object_id += 1

        landmark_points.append(
            {
                "id": object_id,
                "name": f"landmark_{raw['id']}",
                "type": "landmark",
                "x": start + max(tile * 4, (end - start) // 2),
                "y": ground_y - 120,
                "width": 96,
                "height": 96,
                "segment": raw["id"],
                "note": raw["landmark"],
            }
        )
        object_id += 1
        cursor = end

    return {
        "profile": RUN_AND_GUN_LAYOUT_PROFILE["id"],
        "viewport": {"width": viewport_width, "height": viewport_height},
        "tile": tile,
        "groundY": ground_y,
        "mapWidth": cursor,
        "segments": segments,
        "enemyPoints": enemy_points,
        "coverPoints": cover_points,
        "landmarkPoints": landmark_points,
    }


def run_and_gun_profile_summary() -> str:
    minimums = RUN_AND_GUN_LAYOUT_PROFILE["minimums"]
    return (
        "run_and_gun_v1: 6-segment horizontal stage, "
        f">={minimums['enemyObjects']} enemies, "
        f">={minimums['enemyObjectsInFirstTwoViewports']} enemies in first two viewports, "
        "3+ background/decor layers, projectile release on hit and offscreen, "
        "aim_y support, camera clamp and out-of-bounds death/respawn."
    )


def _spread_points(start: int, end: int, count: int) -> list[int]:
    if count <= 0:
        return []
    width = max(1, end - start)
    return [start + int(width * (i + 1) / (count + 1)) for i in range(count)]


__all__ = [
    "RUN_AND_GUN_LAYOUT_PROFILE",
    "run_and_gun_profile_summary",
    "run_and_gun_stage_plan",
]
