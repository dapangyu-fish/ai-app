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
import zlib
from functools import lru_cache
from typing import Any, Callable


ASSET_PACK_MARKER = "/json-app-assets/asset-packs/"


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
    """Add image dimensions and XML atlas entries.

    Per-asset sprite frame sizes must come from manifest sidecars or generated
    metadata, not from backend code. Unknown sheets stay unknown until a
    manifest enrichment pass can prove their grid.
    """
    enriched = copy.deepcopy(manifest)
    files = enriched.get("files")
    if not isinstance(files, list):
        return enriched

    base_url = str(enriched.get("baseUrl") or "")

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
            if path in atlas_by_image:
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


def animation_frame_boundary_diagnostics(
    asset_url: str,
    *,
    frame_width: int,
    frame_height: int,
    frames_per_row: int,
    frames: int,
    start_frame: int = 0,
) -> dict[str, Any] | None:
    """Return generic diagnostics for an animation grid declared by JSON.

    This does not know any asset-pack-specific dimensions. It compares declared
    frame boundaries against transparent pixels in the PNG. When many internal
    boundaries cut through opaque pixels, the frame width is probably guessed
    wrong and adjacent animation frames may be stitched together visually.
    """
    if (
        frame_width <= 0
        or frame_height <= 0
        or frames_per_row <= 1
        or frames <= 1
        or start_frame < 0
        or not asset_url.lower().split("?", 1)[0].endswith(".png")
    ):
        return None
    try:
        alpha = _png_alpha_grid(_fetch_full_url(asset_url))
    except Exception:
        return None
    if alpha is None:
        return None
    width, height, rows = alpha
    if frame_width > width or frame_height > height:
        return None

    current = _boundary_stats(
        rows,
        image_width=width,
        image_height=height,
        frame_width=frame_width,
        frame_height=frame_height,
        frames_per_row=frames_per_row,
        frames=frames,
        start_frame=start_frame,
    )
    if not current or current["checked"] < 3:
        return None

    return {
        "imageWidth": width,
        "imageHeight": height,
        "current": current,
    }


@lru_cache(maxsize=64)
def _fetch_full_url(url: str) -> bytes:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "ai-app-asset-metadata/1"},
    )
    with urllib.request.urlopen(request, timeout=12) as response:
        return response.read()


def _fetch_url(url: str) -> bytes:
    headers = {"User-Agent": "ai-app-asset-metadata/1"}
    if url.split("?", 1)[0].lower().endswith(".png"):
        headers["Range"] = "bytes=0-31"
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=8) as response:
        return response.read()


def _png_alpha_grid(data: bytes) -> tuple[int, int, list[bytearray]] | None:
    if len(data) < 33 or data[:8] != b"\x89PNG\r\n\x1a\n":
        return None

    width = height = bit_depth = color_type = interlace = None
    transparency: bytes = b""
    idat = bytearray()

    pos = 8
    while pos + 8 <= len(data):
        length = struct.unpack(">I", data[pos : pos + 4])[0]
        chunk_type = data[pos + 4 : pos + 8]
        chunk_data = data[pos + 8 : pos + 8 + length]
        pos += 12 + length
        if chunk_type == b"IHDR" and len(chunk_data) >= 13:
            width, height = struct.unpack(">II", chunk_data[:8])
            bit_depth = chunk_data[8]
            color_type = chunk_data[9]
            interlace = chunk_data[12]
        elif chunk_type == b"tRNS":
            transparency = chunk_data
        elif chunk_type == b"IDAT":
            idat.extend(chunk_data)
        elif chunk_type == b"IEND":
            break

    if (
        width is None
        or height is None
        or bit_depth != 8
        or interlace != 0
        or width <= 0
        or height <= 0
        or width * height > 2_000_000
    ):
        return None

    channels_by_type = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}
    channels = channels_by_type.get(color_type)
    if channels is None:
        return None
    has_alpha = color_type in {4, 6} or bool(transparency)
    if not has_alpha:
        return None

    try:
        raw = zlib.decompress(bytes(idat))
    except Exception:
        return None

    stride = width * channels
    if len(raw) < (stride + 1) * height:
        return None

    decoded_rows: list[bytearray] = []
    prev = bytearray(stride)
    offset = 0
    for _ in range(height):
        filter_type = raw[offset]
        offset += 1
        row = bytearray(raw[offset : offset + stride])
        offset += stride
        if filter_type == 1:
            for i in range(stride):
                row[i] = (row[i] + (row[i - channels] if i >= channels else 0)) & 0xFF
        elif filter_type == 2:
            for i in range(stride):
                row[i] = (row[i] + prev[i]) & 0xFF
        elif filter_type == 3:
            for i in range(stride):
                left = row[i - channels] if i >= channels else 0
                row[i] = (row[i] + ((left + prev[i]) // 2)) & 0xFF
        elif filter_type == 4:
            for i in range(stride):
                left = row[i - channels] if i >= channels else 0
                up = prev[i]
                up_left = prev[i - channels] if i >= channels else 0
                row[i] = (row[i] + _paeth(left, up, up_left)) & 0xFF
        elif filter_type != 0:
            return None
        decoded_rows.append(row)
        prev = row

    alpha_rows: list[bytearray] = []
    transparent_rgb: tuple[int, int, int] | None = None
    transparent_gray: int | None = None
    if color_type == 2 and len(transparency) >= 6:
        transparent_rgb = (
            struct.unpack(">H", transparency[0:2])[0] & 0xFF,
            struct.unpack(">H", transparency[2:4])[0] & 0xFF,
            struct.unpack(">H", transparency[4:6])[0] & 0xFF,
        )
    elif color_type == 0 and len(transparency) >= 2:
        transparent_gray = struct.unpack(">H", transparency[:2])[0] & 0xFF

    for row in decoded_rows:
        mask = bytearray(width)
        if color_type == 6:
            for x in range(width):
                mask[x] = 1 if row[x * 4 + 3] > 0 else 0
        elif color_type == 4:
            for x in range(width):
                mask[x] = 1 if row[x * 2 + 1] > 0 else 0
        elif color_type == 3:
            for x in range(width):
                index = row[x]
                alpha = transparency[index] if index < len(transparency) else 255
                mask[x] = 1 if alpha > 0 else 0
        elif color_type == 2 and transparent_rgb is not None:
            for x in range(width):
                i = x * 3
                rgb = (row[i], row[i + 1], row[i + 2])
                mask[x] = 0 if rgb == transparent_rgb else 1
        elif color_type == 0 and transparent_gray is not None:
            for x in range(width):
                mask[x] = 0 if row[x] == transparent_gray else 1
        else:
            return None
        alpha_rows.append(mask)
    return width, height, alpha_rows


def _boundary_stats(
    rows: list[bytearray],
    *,
    image_width: int,
    image_height: int,
    frame_width: int,
    frame_height: int,
    frames_per_row: int,
    frames: int,
    start_frame: int = 0,
) -> dict[str, Any] | None:
    checked = cut = touched = 0
    samples: list[int] = []
    last_frame = start_frame + frames - 1
    for frame in range(start_frame, last_frame):
        col = frame % frames_per_row
        if col >= frames_per_row - 1:
            continue
        row_index = frame // frames_per_row
        x = int(round((col + 1) * frame_width))
        y0 = int(round(row_index * frame_height))
        y1 = int(round((row_index + 1) * frame_height))
        if x <= 0 or x >= image_width or y0 >= image_height:
            continue
        y0 = max(0, y0)
        y1 = min(image_height, max(y0 + 1, y1))
        checked += 1
        left_count = _column_alpha_count(rows, x - 1, y0, y1)
        right_count = _column_alpha_count(rows, x, y0, y1)
        overlap = _column_overlap_count(rows, x - 1, x, y0, y1)
        left = left_count > 0
        right = right_count > 0
        if left or right:
            touched += 1
        if left and right and overlap >= 4 and overlap / max(1, y1 - y0) >= 0.15:
            cut += 1
            if len(samples) < 6:
                samples.append(x)
    if checked == 0:
        return None
    return {
        "checked": checked,
        "cut": cut,
        "touched": touched,
        "cutRatio": cut / checked,
        "touchRatio": touched / checked,
        "frameWidth": frame_width,
        "frameHeight": frame_height,
        "framesPerRow": frames_per_row,
        "samples": samples,
    }


def _column_alpha_count(rows: list[bytearray], x: int, y0: int, y1: int) -> int:
    return sum(1 for y in range(y0, y1) if rows[y][x])


def _column_overlap_count(rows: list[bytearray], x1: int, x2: int, y0: int, y1: int) -> int:
    return sum(1 for y in range(y0, y1) if rows[y][x1] and rows[y][x2])


def _paeth(left: int, up: int, up_left: int) -> int:
    p = left + up - up_left
    pa = abs(p - left)
    pb = abs(p - up)
    pc = abs(p - up_left)
    if pa <= pb and pa <= pc:
        return left
    if pb <= pc:
        return up
    return up_left


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
