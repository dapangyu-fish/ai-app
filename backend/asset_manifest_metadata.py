#!/usr/bin/env python3
"""Asset-pack manifest metadata helpers.

Hosted asset-pack manifests are the source of truth for generated JSON apps.
This module keeps the metadata format small and plain JSON so both prompts and
registry validation can rely on it without knowing a specific game.
"""

from __future__ import annotations

import copy
import json
import struct
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from functools import lru_cache
from typing import Any, Callable


ASSET_PACK_MARKER = "/json-app-assets/asset-packs/"


# Curated grid metadata for packs that do not ship an atlas sidecar. These are
# asset-pack facts, not app-specific exceptions.
CURATED_SPRITES: dict[tuple[str, str, str], dict[str, Any]] = {
    (
        "vaca-roxa-generic-run-n-gun",
        "1.0",
        "Player/SpriteSheet_player_sliced.png",
    ): {
        "kind": "grid",
        "frameWidth": 45,
        "frameHeight": 45,
        "columns": 8,
        "rows": 8,
        "frames": 64,
        "source": "curated",
    },
    (
        "vaca-roxa-generic-run-n-gun",
        "1.0",
        "Enemies/ARMob.png",
    ): {
        "kind": "strip",
        "frameWidth": 48,
        "frameHeight": 38,
        "columns": 16,
        "rows": 1,
        "frames": 16,
        "source": "curated",
    },
    (
        "vaca-roxa-generic-run-n-gun",
        "1.0",
        "Enemies/RPGmob.png",
    ): {
        "kind": "strip",
        "frameWidth": 44,
        "frameHeight": 44,
        "columns": 10,
        "rows": 1,
        "frames": 10,
        "source": "curated",
    },
    (
        "vaca-roxa-generic-run-n-gun",
        "1.0",
        "Enemies/SniperMob.png",
    ): {
        "kind": "strip",
        "frameWidth": 44,
        "frameHeight": 44,
        "columns": 14,
        "rows": 1,
        "frames": 14,
        "source": "curated",
    },
    (
        "vaca-roxa-generic-run-n-gun",
        "1.0",
        "Enemies/Explosion_Particle.png",
    ): {
        "kind": "strip",
        "frameWidth": 32,
        "frameHeight": 32,
        "columns": 9,
        "rows": 1,
        "frames": 9,
        "source": "curated",
    },
}


def read_png_size(data: bytes) -> tuple[int, int] | None:
    """Return PNG width/height from file bytes without external dependencies."""
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return struct.unpack(">II", data[16:24])


def parse_texture_atlas_xml(xml_text: str) -> tuple[str | None, list[dict[str, Any]]]:
    """Parse common Kenney/TexturePacker XML atlas files."""
    root = ET.fromstring(xml_text)
    image_path = root.attrib.get("imagePath")
    entries: list[dict[str, Any]] = []
    for child in root:
        if child.tag != "SubTexture":
            continue
        try:
            entries.append(
                {
                    "name": child.attrib["name"],
                    "x": int(child.attrib["x"]),
                    "y": int(child.attrib["y"]),
                    "width": int(child.attrib["width"]),
                    "height": int(child.attrib["height"]),
                }
            )
        except (KeyError, ValueError):
            continue
    return image_path, entries


def enrich_manifest(
    manifest: dict[str, Any],
    fetch_bytes: Callable[[str], bytes],
) -> dict[str, Any]:
    """Add image dimensions, XML atlas entries and curated sprite grids."""
    enriched = copy.deepcopy(manifest)
    files = enriched.get("files")
    if not isinstance(files, list):
        return enriched

    slug = str(enriched.get("slug") or "")
    version = str(enriched.get("version") or "")
    base_url = str(enriched.get("baseUrl") or "")
    by_path = {
        str(item.get("path") or ""): item
        for item in files
        if isinstance(item, dict)
    }

    atlas_by_image: dict[str, dict[str, Any]] = {}
    for item in files:
        if not isinstance(item, dict):
            continue
        path = str(item.get("path") or "")
        if not path.lower().endswith(".xml"):
            continue
        url = str(item.get("url") or "")
        if not url and base_url:
            url = urllib.parse.urljoin(base_url, path)
        if not url:
            continue
        try:
            image_path, entries = parse_texture_atlas_xml(
                fetch_bytes(url).decode("utf-8", "replace")
            )
        except Exception:
            continue
        if not image_path or not entries:
            continue
        image_key = _resolve_sibling_path(path, image_path)
        atlas_by_image[image_key] = {
            "format": "TextureAtlas",
            "source": path,
            "entryCount": len(entries),
            "entries": entries,
        }

    for item in files:
        if not isinstance(item, dict):
            continue
        path = str(item.get("path") or "")
        url = str(item.get("url") or "")
        lower_path = path.lower()
        if lower_path.endswith(".png"):
            if "image" not in item:
                try:
                    size = read_png_size(fetch_bytes(url))
                except Exception:
                    size = None
                if size:
                    item["image"] = {"width": size[0], "height": size[1]}
            curated = CURATED_SPRITES.get((slug, version, path))
            if curated:
                item["sprite"] = copy.deepcopy(curated)
            elif path in atlas_by_image:
                item["atlas"] = atlas_by_image[path]
                item["sprite"] = {
                    "kind": "atlas",
                    "entryCount": atlas_by_image[path]["entryCount"],
                    "source": atlas_by_image[path]["source"],
                }
            elif _looks_like_sheet_path(path):
                item.setdefault("sprite", {"kind": "unknown_sheet", "source": "filename"})
            else:
                image = item.get("image")
                if isinstance(image, dict):
                    item.setdefault(
                        "sprite",
                        {
                            "kind": "single",
                            "frameWidth": image.get("width"),
                            "frameHeight": image.get("height"),
                            "frames": 1,
                            "source": "image",
                        },
                    )

    enriched["metadataVersion"] = "asset-manifest-metadata-v1"
    return enriched


def metadata_for_asset_url(asset_url: str) -> dict[str, Any] | None:
    parts = parse_asset_pack_url(asset_url)
    if not parts:
        return None
    manifest_url, _, _, asset_path = parts
    manifest = load_manifest(manifest_url)
    if not manifest:
        return None
    slug = str(manifest.get("slug") or "")
    version = str(manifest.get("version") or "")
    base_url = str(manifest.get("baseUrl") or "")
    file_item: dict[str, Any] | None = None
    for item in manifest.get("files") or []:
        if isinstance(item, dict) and item.get("path") == asset_path:
            file_item = copy.deepcopy(item)
            break
    if file_item is None:
        return None

    curated = CURATED_SPRITES.get((slug, version, asset_path))
    if curated:
        file_item["sprite"] = copy.deepcopy(curated)

    if str(asset_path).lower().endswith(".png") and "image" not in file_item:
        size = read_png_size_from_url(asset_url)
        if size:
            file_item["image"] = {"width": size[0], "height": size[1]}

    if "sprite" not in file_item and str(asset_path).lower().endswith(".png"):
        atlas = _find_related_atlas(manifest, asset_path, base_url)
        if atlas:
            file_item["atlas"] = atlas
            file_item["sprite"] = {
                "kind": "atlas",
                "entryCount": atlas["entryCount"],
                "source": atlas["source"],
            }
        elif _looks_like_sheet_path(asset_path):
            file_item["sprite"] = {"kind": "unknown_sheet", "source": "filename"}
        else:
            image = file_item.get("image")
            if isinstance(image, dict):
                file_item["sprite"] = {
                    "kind": "single",
                    "frameWidth": image.get("width"),
                    "frameHeight": image.get("height"),
                    "frames": 1,
                    "source": "image",
                }
    return file_item


def sprite_frame_size(file_meta: dict[str, Any] | None) -> tuple[int, int] | None:
    if not isinstance(file_meta, dict):
        return None
    sprite = file_meta.get("sprite")
    if isinstance(sprite, dict):
        width = _int_value(sprite.get("frameWidth"))
        height = _int_value(sprite.get("frameHeight"))
        if width and height:
            return width, height
    image = file_meta.get("image")
    if isinstance(image, dict):
        width = _int_value(image.get("width"))
        height = _int_value(image.get("height"))
        if width and height and (not isinstance(sprite, dict) or sprite.get("kind") == "single"):
            return width, height
    return None


def parse_asset_pack_url(url: str) -> tuple[str, str, str, str] | None:
    """Return (manifest_url, slug, version, asset_path) for hosted asset URLs."""
    parsed = urllib.parse.urlsplit(url.split("?", 1)[0])
    marker_index = parsed.path.find(ASSET_PACK_MARKER)
    if marker_index < 0:
        return None
    prefix = parsed.path[: marker_index + len(ASSET_PACK_MARKER)]
    rest = parsed.path[marker_index + len(ASSET_PACK_MARKER) :].lstrip("/")
    parts = rest.split("/", 2)
    if len(parts) != 3:
        return None
    slug, version, asset_path = parts
    manifest_path = f"{prefix}{slug}/{version}/manifest.json"
    manifest_url = urllib.parse.urlunsplit(
        (parsed.scheme, parsed.netloc, manifest_path, "", "")
    )
    return manifest_url, urllib.parse.unquote(slug), urllib.parse.unquote(version), urllib.parse.unquote(asset_path)


@lru_cache(maxsize=32)
def load_manifest(manifest_url: str) -> dict[str, Any] | None:
    try:
        return json.loads(_fetch_url(manifest_url).decode("utf-8"))
    except Exception:
        return None


@lru_cache(maxsize=512)
def read_png_size_from_url(url: str) -> tuple[int, int] | None:
    try:
        return read_png_size(_fetch_url(url))
    except Exception:
        return None


def _fetch_url(url: str) -> bytes:
    headers = {"User-Agent": "ai-app-asset-metadata/1"}
    if url.split("?", 1)[0].lower().endswith(".png"):
        headers["Range"] = "bytes=0-31"
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=8) as response:
        return response.read()


def _find_related_atlas(
    manifest: dict[str, Any],
    asset_path: str,
    base_url: str,
) -> dict[str, Any] | None:
    if not asset_path.lower().endswith(".png"):
        return None
    asset_dir = asset_path.rsplit("/", 1)[0] if "/" in asset_path else ""
    basename = asset_path.rsplit("/", 1)[-1].rsplit(".", 1)[0].lower()
    candidates: list[dict[str, Any]] = []
    for item in manifest.get("files") or []:
        if not isinstance(item, dict):
            continue
        path = str(item.get("path") or "")
        if not path.lower().endswith(".xml"):
            continue
        xml_dir = path.rsplit("/", 1)[0] if "/" in path else ""
        xml_base = path.rsplit("/", 1)[-1].rsplit(".", 1)[0].lower()
        if xml_dir == asset_dir or xml_base == basename:
            candidates.append(item)
    for item in candidates:
        path = str(item.get("path") or "")
        url = str(item.get("url") or "")
        if not url and base_url:
            url = urllib.parse.urljoin(base_url, path)
        if not url:
            continue
        try:
            image_path, entries = parse_texture_atlas_xml(
                _fetch_url(url).decode("utf-8", "replace")
            )
        except Exception:
            continue
        if not image_path or not entries:
            continue
        if _resolve_sibling_path(path, image_path) != asset_path:
            continue
        return {
            "format": "TextureAtlas",
            "source": path,
            "entryCount": len(entries),
            "entries": entries,
        }
    return None


def _resolve_sibling_path(source_path: str, image_path: str) -> str:
    if "/" not in source_path:
        return image_path
    return f"{source_path.rsplit('/', 1)[0]}/{image_path}"


def _looks_like_sheet_path(path: str) -> bool:
    lowered = path.lower()
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


def _int_value(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return None
