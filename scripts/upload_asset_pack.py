#!/usr/bin/env python3
"""Upload a local directory as a public JSON app asset pack.

The script is intentionally generic: it uploads every file under a directory to
`json-app-assets/asset-packs/<slug>/<version>/`, writes a manifest.json, and can
optionally merge the pack into the aggregate asset-pack manifest.
"""

from __future__ import annotations

import argparse
import io
import json
import mimetypes
import os
import sys
import urllib.parse
from pathlib import Path
from typing import Any

try:
    from minio import Minio
except Exception as exc:  # pragma: no cover - runtime dependency on server
    raise SystemExit(f"minio package is required: {exc}") from exc


PUBLIC_BASE_DEFAULT = "https://myapp-oss-endpoint.dapangyu.work/json-app-assets/asset-packs"


def _png_size(path: Path) -> tuple[int, int] | None:
    try:
        data = path.read_bytes()[:24]
    except OSError:
        return None
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")


def _load_sprite_metadata(path: Path) -> dict[str, Any]:
    sidecar = path.with_suffix(path.suffix + ".sprite.json")
    if not sidecar.exists():
        return {}
    return json.loads(sidecar.read_text(encoding="utf-8"))


def _file_item(root: Path, path: Path, base_url: str) -> dict[str, Any]:
    rel = path.relative_to(root).as_posix()
    encoded = "/".join(urllib.parse.quote(part) for part in rel.split("/"))
    content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    item: dict[str, Any] = {
        "path": rel,
        "url": f"{base_url}{encoded}",
        "type": content_type,
        "size": path.stat().st_size,
    }
    if content_type == "image/png":
        size = _png_size(path)
        if size:
            item["image"] = {"width": size[0], "height": size[1]}
        sprite = _load_sprite_metadata(path)
        if sprite:
            item["sprite"] = sprite
        elif size:
            item["sprite"] = {
                "kind": "single",
                "frameWidth": size[0],
                "frameHeight": size[1],
                "frames": 1,
                "source": "image",
            }
    return item


def _upload_bytes(client: Minio, bucket: str, key: str, data: bytes, content_type: str) -> None:
    client.put_object(bucket, key, io.BytesIO(data), len(data), content_type=content_type)


def _read_remote_json(client: Minio, bucket: str, key: str) -> dict[str, Any] | None:
    try:
        resp = client.get_object(bucket, key)
        try:
            return json.loads(resp.read().decode("utf-8"))
        finally:
            resp.close()
            resp.release_conn()
    except Exception:
        return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--slug", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--license", default="")
    parser.add_argument("--title", default="")
    parser.add_argument("--description", default="")
    parser.add_argument("--bucket", default="json-app-assets")
    parser.add_argument("--public-base", default=PUBLIC_BASE_DEFAULT)
    parser.add_argument("--update-index", action="store_true")
    args = parser.parse_args()

    root = args.directory.resolve()
    if not root.is_dir():
        raise SystemExit(f"asset directory not found: {root}")

    public_url = os.environ.get("MINIO_PUBLIC_URL", "")
    endpoint = os.environ.get("MINIO_ENDPOINT")
    if not endpoint and public_url:
        endpoint = public_url.split("://")[-1].rstrip("/")
    access_key = os.environ.get("MINIO_ACCESS_KEY")
    secret_key = os.environ.get("MINIO_SECRET_KEY")
    secure_default = "true"
    if public_url:
        secure_default = "true" if public_url.startswith("https://") else "false"
    secure_raw = os.environ.get("MINIO_SECURE", secure_default).lower()
    secure = secure_raw not in {"0", "false", "no"}
    if not endpoint or not access_key or not secret_key:
        raise SystemExit("MINIO_ENDPOINT, MINIO_ACCESS_KEY, MINIO_SECRET_KEY are required")

    client = Minio(endpoint, access_key=access_key, secret_key=secret_key, secure=secure)
    if not client.bucket_exists(args.bucket):
        client.make_bucket(args.bucket)

    prefix = f"asset-packs/{args.slug}/{args.version}/"
    base_url = f"{args.public_base.rstrip('/')}/{args.slug}/{args.version}/"
    files: list[dict[str, Any]] = []
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        if path.name.endswith(".sprite.json"):
            continue
        rel = path.relative_to(root).as_posix()
        key = prefix + rel
        content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        data = path.read_bytes()
        _upload_bytes(client, args.bucket, key, data, content_type)
        files.append(_file_item(root, path, base_url))

    manifest = {
        "slug": args.slug,
        "version": args.version,
        "title": args.title or args.slug,
        "description": args.description,
        "license": args.license,
        "baseUrl": base_url,
        "files": files,
    }
    manifest_bytes = json.dumps(manifest, ensure_ascii=False, indent=2).encode("utf-8")
    _upload_bytes(client, args.bucket, prefix + "manifest.json", manifest_bytes, "application/json")

    if args.update_index:
        index_key = "asset-packs/manifest.json"
        index = _read_remote_json(client, args.bucket, index_key) or {"packs": []}
        packs = [p for p in index.get("packs", []) if not (p.get("slug") == args.slug and p.get("version") == args.version)]
        packs.append(
            {
                "slug": args.slug,
                "version": args.version,
                "title": manifest["title"],
                "description": args.description,
                "license": args.license,
                "manifestUrl": f"{base_url}manifest.json",
                "baseUrl": base_url,
            }
        )
        packs.sort(key=lambda p: (str(p.get("slug")), str(p.get("version"))))
        index["packs"] = packs
        _upload_bytes(
            client,
            args.bucket,
            index_key,
            json.dumps(index, ensure_ascii=False, indent=2).encode("utf-8"),
            "application/json",
        )

    print(f"uploaded {len(files)} files")
    print(f"manifest: {base_url}manifest.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
